// Smoke test for the browser module: builds a `.zl` file in JavaScript, hands it
// to `zill.wasm`, and checks that an area query and a search come back with the
// routes the graph implies. Running it also proves the on-disk layout is what
// `find/src/graph/shared.zig` documents, because this file writes those bytes
// from scratch.
//
//   node find/test/wasm_smoke.mjs [--wasm path]

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const HEADER_SIZE = 24;
const NODE_SIZE = 18;
const EDGE_SIZE = 16;
const VERSION = [0, 0, 2, 0];

const ZI_OK = 0;
const ZI_ERR_SIZE = -4;

function align8(x) {
  return (x + 7) & ~7;
}

/** Sections are laid out in the order shared.zig declares, each aligned. */
function buildGraph(nodes, edges) {
  const n = nodes.length;
  const m = edges.length;
  const ids = align8(HEADER_SIZE);
  const lats = ids + n * 8;
  const lons = lats + n * 4;
  const elevs = lons + n * 4;
  const edgesU = align8(elevs + n * 2);
  const edgesV = edgesU + m * 4;
  const edgesGain = edgesV + m * 4;
  const edgesLoss = edgesGain + m * 2;
  const edgesDist = align8(edgesLoss + m * 2);
  const total = align8(edgesDist + m * 4);

  const buffer = new ArrayBuffer(total);
  const view = new DataView(buffer);
  view.setBigUint64(0, BigInt(n), true);
  view.setBigUint64(8, BigInt(m), true);
  new Uint8Array(buffer, 16, 4).set([0x5a, 0x49, 0x4c, 0x4c]); // "ZILL"
  new Uint8Array(buffer, 20, 4).set(VERSION);

  nodes.forEach((node, i) => {
    view.setBigInt64(ids + i * 8, BigInt(node.id), true);
    view.setFloat32(lats + i * 4, node.lat, true);
    view.setFloat32(lons + i * 4, node.lon, true);
    view.setUint16(elevs + i * 2, node.elev ?? 0xffff, true);
  });
  edges.forEach((edge, i) => {
    view.setUint32(edgesU + i * 4, edge.u, true);
    view.setUint32(edgesV + i * 4, edge.v, true);
    view.setUint16(edgesGain + i * 2, edge.gain, true);
    view.setUint16(edgesLoss + i * 2, edge.loss, true);
    view.setUint32(edgesDist + i * 4, edge.distance, true);
  });

  return new Uint8Array(buffer);
}

const failures = [];
function check(label, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}${ok ? '' : ` — expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`}`);
  if (!ok) failures.push(label);
}

const wasmPath = process.argv.includes('--wasm')
  ? process.argv[process.argv.indexOf('--wasm') + 1]
  : fileURLToPath(new URL('../zig-out/bin/zill.wasm', import.meta.url));

const module = await WebAssembly.compile(await readFile(wasmPath));
const { exports: wasm } = await WebAssembly.instantiate(module, {});

check('module exports memory', typeof wasm.memory, 'object');
for (const name of ['zi_reserve', 'zi_load_graph', 'zi_index_step', 'zi_graph_info', 'zi_scratch', 'zi_area_count', 'zi_area_begin', 'zi_area_page', 'zi_search_start', 'zi_search_step', 'zi_search_stats', 'zi_route_count', 'zi_route_meta', 'zi_route_points']) {
  check(`module exports ${name}`, typeof wasm[name], 'function');
}

// Two climbs 10 km apart; each has a twin start 11 m away that joins the same
// climb, which is what the deduplication has to collapse.
const nodes = [
  { id: 1, lat: 46.0, lon: 7.0, elev: 1000 },
  { id: 2, lat: 46.0001, lon: 7.0, elev: 1000 },
  { id: 3, lat: 46.0005, lon: 7.0, elev: 1010 },
  { id: 4, lat: 46.0176, lon: 7.0, elev: 1500 },
  { id: 5, lat: 46.1, lon: 7.1, elev: 800 },
  { id: 6, lat: 46.1001, lon: 7.1, elev: 800 },
  { id: 7, lat: 46.1005, lon: 7.1, elev: 810 },
  { id: 8, lat: 46.1176, lon: 7.1, elev: 1300 },
];
const edges = [
  { u: 0, v: 2, gain: 10, loss: 0, distance: 50 },
  { u: 1, v: 2, gain: 5, loss: 0, distance: 50 },
  { u: 2, v: 3, gain: 490, loss: 0, distance: 1900 },
  { u: 4, v: 6, gain: 10, loss: 0, distance: 50 },
  { u: 5, v: 6, gain: 5, loss: 0, distance: 50 },
  { u: 6, v: 7, gain: 490, loss: 0, distance: 1900 },
];
const file = buildGraph(nodes, edges);

// A short file must be refused rather than read as a graph.
{
  const ptr = wasm.zi_reserve(file.length - 1);
  new Uint8Array(wasm.memory.buffer, ptr, file.length - 1).set(file.subarray(0, file.length - 1));
  check('a file whose length disagrees with its header is refused', wasm.zi_load_graph(), ZI_ERR_SIZE);
}

const ptr = wasm.zi_reserve(file.length);
if (ptr === 0) throw new Error('zi_reserve returned 0');
new Uint8Array(wasm.memory.buffer, ptr, file.length).set(file);
check('zi_load_graph', wasm.zi_load_graph(), ZI_OK);

let steps = 0;
let more = 1;
while (more === 1) {
  more = wasm.zi_index_step(1 << 16);
  if (++steps > 1000) throw new Error('index never finished');
}
check('zi_index_step finishes', more, 0);

const scratch = wasm.zi_scratch();
check('scratch is 8-aligned', scratch % 8, 0);
check('scratch has room', wasm.zi_scratch_len() >= 4096, true);

// Views must be recreated after any call that can grow memory.
const u32 = () => new Uint32Array(wasm.memory.buffer, scratch, 8);
const f64 = () => new Float64Array(wasm.memory.buffer, scratch, 64);

wasm.zi_graph_info(scratch);
check('graph has 8 nodes and 6 edges', Array.from(u32().slice(0, 2)), [8, 6]);
check('graph reports itself indexed', u32()[2], 1);

/** Writes (lat, lon) pairs into the scratch and returns the pair count. */
function writePolygon(points) {
  const view = f64();
  points.forEach((point, i) => {
    view[i * 2] = point[0];
    view[i * 2 + 1] = point[1];
  });
  return points.length;
}

const widePoints = [
  [45.9, 6.9],
  [45.9, 7.3],
  [46.2, 7.3],
  [46.2, 6.9],
];
const wide = writePolygon(widePoints);
check('area query counts every node', wasm.zi_area_count(scratch, wide), 8);

const tightPoints = [
  [45.99, 6.99],
  [45.99, 7.01],
  [46.03, 7.01],
  [46.03, 6.99],
];
const tight = writePolygon(tightPoints);
check('area query counts only the first climb', wasm.zi_area_count(scratch, tight), 4);

// A concave polygon: the same box with a bite taken out of its right edge,
// wide enough to swallow the twin start node but nothing else.
const box = [
  [45.998, 6.998],
  [45.998, 7.002],
  [46.02, 7.002],
  [46.02, 6.998],
];
const withBite = [
  [45.998, 6.998],
  [45.998, 7.002],
  [46.00005, 7.002],
  [46.00005, 6.9995],
  [46.00015, 6.9995],
  [46.00015, 7.002],
  [46.02, 7.002],
  [46.02, 6.998],
];
const boxCount = wasm.zi_area_count(scratch, writePolygon(box));
const biteCount = wasm.zi_area_count(scratch, writePolygon(withBite));
check('concave area excludes exactly the bitten node', [boxCount, biteCount], [4, 3]);

// The paged area API: one grid query, then (lat, lon) pairs drawn page by page.
check('zi_area_begin indexes the wide area once', wasm.zi_area_begin(scratch, writePolygon(widePoints)), 8);

const page = (offset, cap) => {
  const written = wasm.zi_area_page(offset, scratch + 64 * 1024, cap);
  return Array.from(new Float32Array(wasm.memory.buffer, scratch + 64 * 1024, written * 2));
};
const pages = [page(0, 3), page(3, 3), page(6, 3)];
check('pages come back 3 then 3 then 2', pages.map((p) => p.length / 2), [3, 3, 2]);
check('paged pairs lie inside the wide box', pages.flat().every((v, i) => (i % 2 === 1 ? v > 6.9 && v < 7.3 : v > 45.9 && v < 46.2)), true);
check('area count still holds for the same polygon', wasm.zi_area_count(scratch, writePolygon(widePoints)), 8);
check('a page past the end is empty', wasm.zi_area_page(8, scratch + 64 * 1024, 3), 0);

const areaNodeCount = writePolygon([
  [45.9, 6.9],
  [45.9, 7.3],
  [46.2, 7.3],
  [46.2, 6.9],
]);
check('eight start nodes for the wide area', wasm.zi_area_count(scratch, areaNodeCount), 8);

check('zi_search_start', wasm.zi_search_start(scratch, areaNodeCount, 2000, 0, 3, 500), ZI_OK);

let searchSteps = 0;
while (wasm.zi_search_step(2) === 1) {
  if (++searchSteps > 1000) throw new Error('search never finished');
}

wasm.zi_search_stats(scratch);
const stats = Array.from(u32());
const [scanned, total, considered, accepted, suppressed, bestElevation, finished] = stats;
check('every start node was scanned', [scanned, total], [8, 8]);
check('search finished', finished, 1);
check('two distinct climbs kept', accepted, 2);
// Four twins are suppressed; the two summit starts are below the minimum gain
// for a climb and are skipped rather than counted as duplicates.
check('twins suppressed', suppressed, 4);
check('best gain reported', bestElevation, 500);
check('candidates were evaluated', considered > 0, true);

const routes = [];
for (let i = 0; i < wasm.zi_route_count(); i++) {
  wasm.zi_route_meta(i, scratch);
  const meta = Array.from(u32().slice(0, 4));
  const [startIdx, elevation, distance, pointCount] = meta;
  const required = wasm.zi_route_points(i, scratch, wasm.zi_scratch_len() / 4);
  const points = new Float32Array(wasm.memory.buffer, scratch, required);
  routes.push({
    startIdx,
    elevation,
    distance,
    pointCount,
    points: Array.from(points).filter((_, idx) => idx % 3 < 2),
  });
}

check('both routes gain 500 m over 1950 m', routes.map((r) => [r.elevation, r.distance]), [[500, 1950], [500, 1950]]);
check('each route has three points', routes.map((r) => r.pointCount), [3, 3]);
check('routes start on different climbs', [routes[0].startIdx < 2, routes[1].startIdx >= 4], [true, true]);
// Coordinates are stored as f32 in the file, so compare within a centimetre.
const expectedPath = [46.0, 7.0, 46.0005, 7.0, 46.0176, 7.0];
const close = routes[0].points.every((value, i) => Math.abs(value - expectedPath[i]) < 1e-4);
check('route geometry is a closed climb', close, true);

wasm.zi_reset();
check('reset clears the graph', (wasm.zi_graph_info(scratch), Array.from(u32().slice(0, 2))), [0, 0]);

if (failures.length > 0) {
  console.error(`\n${failures.length} check(s) failed: ${failures.join(', ')}`);
  process.exit(1);
}
console.log(`\nall checks passed (${steps} index steps, ${searchSteps} search steps)`);
