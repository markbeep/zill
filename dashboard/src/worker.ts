// Owns the WebAssembly module, the decompressed graph and the search. The main
// thread only ever sees progress figures and route geometry, so the map keeps
// painting while a 145 MB graph is indexed and searched.

import { GridSampler } from './cluster';
import {
  GRAPH_ASSET,
  NODE_PAGE,
  NODE_PAGES_INTERACTIVE,
  PINPRICK_LIMIT,
  WASM_ASSET,
} from './wasm';
import type {
  FromWorker,
  LoadState,
  Route,
  SearchRequest,
  SearchStats,
  ToWorker,
} from './wasm';
import type { LngLat } from './area';

type Wasm = {
  memory: WebAssembly.Memory;
  zi_reserve(len: number): number;
  zi_load_graph(): number;
  zi_index_step(budget: number): number;
  zi_graph_info(out: number): void;
  zi_scratch(): number;
  zi_scratch_len(): number;
  zi_area_count(points: number, count: number): number;
  zi_area_begin(points: number, count: number): number;
  zi_area_page(offset: number, out: number, cap: number): number;
  zi_search_start(
    points: number,
    count: number,
    maxDistance: number,
    maxElevation: number,
    maxResults: number,
    dedupPermille: number,
  ): number;
  zi_search_step(budget: number): number;
  zi_search_stats(out: number): void;
  zi_route_count(): number;
  zi_route_meta(index: number, out: number): number;
  zi_route_points(index: number, out: number, cap: number): number;
  zi_reset(): void;
};

/** Region map of the wasm scratch buffer; the offsets match `wasm.zig`. */
const SCRATCH_MIN = 1024 * 1024;
const POLY_OFF = 0; // f64 (lat, lng) pairs, up to 8192 vertices
const COORDS_OFF = 128 * 1024; // f32 (lat, lng) pairs read back from the module
const STATS_OFF = SCRATCH_MIN - 256; // u32 stats and route metadata

/** Stage weights: the download dominates, indexing is a short tail. */
const WEIGHT_DOWNLOAD = 0.55;
const WEIGHT_DECOMPRESS = 0.3;
const WEIGHT_INDEX = 0.15;

const scope = globalThis as unknown as {
  postMessage(message: FromWorker, transfer?: Transferable[]): void;
  onmessage: ((event: MessageEvent<ToWorker>) => void) | null;
};

let wasm: Wasm | null = null;
let scratch = 0;
let searchTimer: number | undefined;
let routes: Route[] = [];
let lastRevision = -1;
let emptyStats: SearchStats = {
  scanned: 0,
  total: 0,
  considered: 0,
  accepted: 0,
  suppressed: 0,
  bestElevation: 0,
  finished: false,
  revision: 0,
};

let load: LoadState = {
  phase: 'idle',
  received: 0,
  total: 0,
  inflated: 0,
  graphBytes: 0,
  progress: 0,
  nodes: 0,
  edges: 0,
};

function emitLoad(patch: Partial<LoadState>): void {
  load = { ...load, ...patch };
  scope.postMessage({ type: 'load', state: load });
}

/** Views must be rebuilt after any call that can grow wasm memory. */
function u32View(offset: number, length: number): Uint32Array {
  return new Uint32Array(wasm!.memory.buffer, scratch + offset, length);
}

function f32View(offset: number, length: number): Float32Array {
  return new Float32Array(wasm!.memory.buffer, scratch + offset, length);
}

function writePolygon(area: LngLat[]): void {
  const pairs = new Float64Array(
    wasm!.memory.buffer,
    scratch + POLY_OFF,
    area.length * 2,
  );
  area.forEach((point, i) => {
    pairs[i * 2] = point.lat;
    pairs[i * 2 + 1] = point.lng;
  });
}

function loadErrorCode(status: number): string {
  switch (status) {
    case -2:
      return 'the graph file is not a zill graph';
    case -3:
      return 'the graph file was built by another version of zill';
    case -4:
      return 'the graph file is truncated or has the wrong length for its header';
    case -5:
      return 'the graph file did not arrive intact';
    case -6:
      return 'the browser ran out of memory for the graph';
    default:
      return `the graph could not be loaded (${status})`;
  }
}

/** Size of the single member of a ustar archive, read from its header. */
function tarMemberSize(header: Uint8Array): number {
  const field = new TextDecoder().decode(header.subarray(124, 136)).trim();
  const size = parseInt(field, 8);
  if (!Number.isFinite(size) || size <= 0)
    throw new Error('graph archive is empty or malformed');
  return size;
}

async function fetchGraph(): Promise<void> {
  emitLoad({
    phase: 'download',
    received: 0,
    inflated: 0,
    progress: 0,
    detail: 'requesting the walkable Switzerland graph',
  });
  const response = await fetch(GRAPH_ASSET);
  if (!response.ok || !response.body) {
    throw new Error(
      `the graph file is missing next to the app (status ${response.status}). ` +
        'mount data/switzerland_walkable_100m.zl.tar.gz at /app/graph.tar.gz.',
    );
  }
  const total = Number(response.headers.get('content-length') ?? 0);
  emitLoad({ total });

  // Static servers advertise a `.gz` file as already-encoded, and the browser
  // then hands over the tar payload with the gzip layer already removed. Sniff
  // the first bytes instead of trusting either behaviour.
  const raw = response.body.getReader();
  const first = await raw.read();
  const head = first.value ?? new Uint8Array(0);
  const gzipped = head.length >= 2 && head[0] === 0x1f && head[1] === 0x8b;
  const rest = new ReadableStream<Uint8Array>({
    start(controller) {
      if (head.length > 0) controller.enqueue(head);
      if (first.done) controller.close();
    },
    async pull(controller) {
      const next = await raw.read();
      if (next.done) controller.close();
      else controller.enqueue(next.value);
    },
  });
  // `DecompressionStream` is typed over `BufferSource`, which does not line up
  // with the chunked stream the browser hands back; the cast is the lib's, not ours.
  const decompressed: ReadableStream<Uint8Array> = gzipped
    ? rest.pipeThrough(
        new DecompressionStream('gzip') as unknown as ReadableWritablePair<
          Uint8Array,
          Uint8Array
        >,
      )
    : rest;
  const reader = decompressed.getReader();
  const headerBuffer = new Uint8Array(512);
  let headerFilled = 0;
  let target = 0;
  let graphBytes = 0;
  let written = 0;
  let received = 0;
  let lastEmit = 0;

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    let chunk = value;
    received += chunk.length;

    if (headerFilled < headerBuffer.length) {
      const take = Math.min(headerBuffer.length - headerFilled, chunk.length);
      headerBuffer.set(chunk.subarray(0, take), headerFilled);
      headerFilled += take;
      chunk = chunk.subarray(take);
      if (headerFilled < headerBuffer.length) continue;
      graphBytes = tarMemberSize(headerBuffer);
      target = wasm!.zi_reserve(graphBytes);
      if (target === 0)
        throw new Error('the browser could not reserve memory for the graph');
      emitLoad({ phase: 'decompress', total, graphBytes });
    }

    if (chunk.length > 0) {
      // The tar stream carries padding and two EOF blocks after the payload;
      // the header's size is the truth, so stop there.
      const take = Math.min(graphBytes - written, chunk.length);
      if (take > 0) {
        new Uint8Array(wasm!.memory.buffer, target, graphBytes).set(
          chunk.subarray(0, take),
          written,
        );
        written += take;
      }
    }

    const now = performance.now();
    if (now - lastEmit > 100 || written === graphBytes) {
      lastEmit = now;
      emitLoad({
        received: total > 0 ? Math.min(received, total) : received,
        inflated: written,
        progress:
          (total > 0 ? Math.min(received / total, 1) : 0) * WEIGHT_DOWNLOAD +
          (written / graphBytes) * WEIGHT_DECOMPRESS,
      });
    }

    if (written === graphBytes) {
      await reader.cancel();
      break;
    }
  }

  if (written !== graphBytes)
    throw new Error('graph archive ended before the file was complete');

  const status = wasm!.zi_load_graph();
  if (status !== 0) throw new Error(loadErrorCode(status));
  scratch = wasm!.zi_scratch();
  if (scratch === 0 || wasm!.zi_scratch_len() < SCRATCH_MIN)
    throw new Error('the module exposes no scratch buffer');

  wasm!.zi_graph_info(scratch + STATS_OFF);
  const [nodes, edges] = u32View(STATS_OFF, 6);
  emitLoad({ phase: 'index', nodes, edges });
}

/** Lets the event loop run a turn, so a queued area query is answered mid-build. */
function yieldToEventLoop(): Promise<void> {
  const { promise, resolve } = Promise.withResolvers<void>();
  setTimeout(resolve, 0);
  return promise;
}

async function buildIndex(): Promise<void> {
  for (;;) {
    const more = wasm!.zi_index_step(1 << 22);
    if (more < 0) throw new Error('the graph index could not be built');
    wasm!.zi_graph_info(scratch + STATS_OFF);
    const progress = u32View(STATS_OFF, 6)[3] / 1000;
    emitLoad({
      progress: WEIGHT_DOWNLOAD + WEIGHT_DECOMPRESS + progress * WEIGHT_INDEX,
    });
    if (more === 0) break;
    await yieldToEventLoop();
  }
  wasm!.zi_graph_info(scratch + STATS_OFF);
  const [nodes, edges] = u32View(STATS_OFF, 6);
  emitLoad({ phase: 'ready', progress: 1, nodes, edges, detail: undefined });
}

async function ensureGraph(): Promise<void> {
  try {
    if (wasm === null) {
      const source = await fetch(WASM_ASSET);
      if (!source.ok)
        throw new Error(`wasm module missing (status ${source.status})`);
      const module = await WebAssembly.compile(await source.arrayBuffer());
      wasm = (await WebAssembly.instantiate(module, {}))
        .exports as unknown as Wasm;
    }
    // `fetchGraph` leaves the load state in `index` once the bytes are in place.
    if (load.phase === 'idle' || load.phase === 'error') await fetchGraph();
    if (load.phase === 'index') await buildIndex();
  } catch (error) {
    load = {
      ...load,
      phase: 'error',
      detail: error instanceof Error ? error.message : String(error),
    };
    scope.postMessage({ type: 'load', state: load });
  }
}

function queryArea(area: LngLat[]): void {
  if (wasm === null || load.phase !== 'ready' || area.length < 3) {
    scope.postMessage({ type: 'area', count: 0 });
    return;
  }
  writePolygon(area);
  scope.postMessage({
    type: 'area',
    count: wasm.zi_area_count(scratch + POLY_OFF, area.length),
  });
}

/** One cell of the area's own bounding box, sized so the limit holds. */
function samplerCell(area: LngLat[]): number {
  const lats = area.map((point) => point.lat);
  const lngs = area.map((point) => point.lng);
  const latSpan = Math.max(...lats) - Math.min(...lats);
  const lngSpan = Math.max(...lngs) - Math.min(...lngs);
  const cell = Math.sqrt((latSpan * lngSpan) / PINPRICK_LIMIT);
  return Math.max(cell, 0.00015);
}

/**
 * Every start node inside the area, however large it is: the module holds the
 * list, we read it in pages, and nodes sharing a cell of the area's own grid
 * collapse into one so the count that reaches the map stays drawable.
 */
function queryNodes(area: LngLat[], interactive: boolean): void {
  if (wasm === null || load.phase !== 'ready' || area.length < 3) {
    scope.postMessage({ type: 'nodes', points: new Float32Array(0), total: 0 });
    return;
  }
  writePolygon(area);
  const total = wasm.zi_area_begin(scratch + POLY_OFF, area.length);
  if (total === 0) {
    scope.postMessage({ type: 'nodes', points: new Float32Array(0), total: 0 });
    return;
  }
  const sampler = new GridSampler(samplerCell(area), PINPRICK_LIMIT);
  // While the figure is dragged, sample pages spread across the whole list —
  // reading only its head would show one corner of the area and call it the
  // field. The settle then reads every page.
  const pages = interactive
    ? NODE_PAGES_INTERACTIVE
    : Math.ceil(total / NODE_PAGE);
  const step = interactive
    ? Math.max(NODE_PAGE, Math.floor(total / pages))
    : NODE_PAGE;
  let read = 0;
  for (let offset = 0; offset < total && read < pages; offset += step, read++) {
    const written = wasm.zi_area_page(offset, scratch + COORDS_OFF, NODE_PAGE);
    if (written === 0) break;
    const pairs = f32View(COORDS_OFF, written * 2);
    // `add` also returns false for a node that shares an occupied cell; only the
    // sampler being full ends the read.
    for (let i = 0; i < written; i++)
      sampler.add(pairs[i * 2], pairs[i * 2 + 1]);
    if (sampler.size >= PINPRICK_LIMIT) break;
  }
  const points = sampler.toArray();
  scope.postMessage({ type: 'nodes', points, total }, [points.buffer]);
}

function readRoutes(count: number): Route[] {
  const found: Route[] = [];
  for (let index = 0; index < count; index++) {
    if (wasm!.zi_route_meta(index, scratch + STATS_OFF) !== 0) break;
    const [startIndex, elevation, distance, pointCount] = u32View(STATS_OFF, 4);
    const required = wasm!.zi_route_points(
      index,
      scratch + COORDS_OFF,
      (SCRATCH_MIN - COORDS_OFF - 256) / 4,
    );
    const points = new Float32Array(required);
    points.set(f32View(COORDS_OFF, required));
    found.push({ rank: index + 1, startIndex, elevation, distance, points });
    if (pointCount === 0) break;
  }
  return found;
}

function reportSearch(force = false): void {
  if (wasm === null || load.phase !== 'ready') return;
  wasm.zi_search_stats(scratch + STATS_OFF);
  const [
    scanned,
    total,
    considered,
    accepted,
    suppressed,
    bestElevation,
    finished,
    revision,
  ] = u32View(STATS_OFF, 8);
  const stats: SearchStats = {
    scanned,
    total,
    considered,
    accepted,
    suppressed,
    bestElevation,
    finished: finished === 1,
    revision,
  };
  const changed = force || revision !== lastRevision;
  if (changed) {
    lastRevision = revision;
    routes = wasm.zi_route_count() > 0 ? readRoutes(wasm.zi_route_count()) : [];
  }
  scope.postMessage(
    {
      type: 'search',
      stats,
      routes: changed ? routes : [],
      routesChanged: changed,
    },
    [],
  );
}

/** Runs the search in short turns so area queries stay answerable. */
function pump(): void {
  searchTimer = undefined;
  if (wasm === null) return;
  const started = performance.now();
  let more = 1;
  while (more === 1 && performance.now() - started < 24) {
    more = wasm.zi_search_step(256);
    if (more < 0) {
      emitLoad({
        phase: 'error',
        detail: 'the search failed inside the graph module',
      });
      return;
    }
  }
  reportSearch();
  if (more === 1) searchTimer = setTimeout(pump, 0);
  else reportSearch(true);
}

function stopSearch(): void {
  clearTimeout(searchTimer);
  searchTimer = undefined;
}

function startSearch(request: SearchRequest): void {
  if (wasm === null || load.phase !== 'ready' || request.area.length < 3)
    return;
  stopSearch();
  writePolygon(request.area);
  lastRevision = -1;
  const status = wasm.zi_search_start(
    scratch + POLY_OFF,
    request.area.length,
    request.maxDistanceM,
    request.maxElevationM,
    request.maxResults,
    request.dedupPermille,
  );
  if (status !== 0) {
    // No start node fell inside the area: report a finished run of nothing
    // rather than leaving the host waiting for progress.
    routes = [];
    const empty: SearchStats = { ...emptyStats, finished: true, revision: 1 };
    scope.postMessage({
      type: 'search',
      stats: empty,
      routes: [],
      routesChanged: true,
    });
    return;
  }
  reportSearch(true);
  searchTimer = setTimeout(pump, 0);
}

scope.onmessage = (event) => {
  const message = event.data;
  if (message.type === 'load') {
    void ensureGraph();
  } else if (message.type === 'area') {
    queryArea(message.area);
  } else if (message.type === 'nodes') {
    queryNodes(message.area, message.interactive);
  } else if (message.type === 'search') {
    startSearch(message.request);
  } else if (message.type === 'stop') {
    stopSearch();
    reportSearch(true);
  }
};
