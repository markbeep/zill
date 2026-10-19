// The contract between the main thread and the WebAssembly worker. The graph
// lives only inside the worker; the main thread receives route geometry, node
// pinpricks and progress figures.

import type { LngLat } from './area';

export type LoadPhase =
  'idle' | 'download' | 'decompress' | 'index' | 'ready' | 'error';

export type LoadState = {
  phase: LoadPhase;
  /** Bytes of the compressed asset already received, and its total. */
  received: number;
  total: number;
  /** Bytes decompressed into the module, and the graph file's own size. */
  inflated: number;
  graphBytes: number;
  /** 0..1 across the whole load, for a single honest bar. */
  progress: number;
  nodes: number;
  edges: number;
  detail?: string;
};

export type SearchStats = {
  scanned: number;
  total: number;
  considered: number;
  accepted: number;
  suppressed: number;
  bestElevation: number;
  finished: boolean;
  revision: number;
};

export type Route = {
  rank: number;
  startIndex: number;
  elevation: number;
  distance: number;
  /** Interleaved lat, lng, elevation triples. */
  points: Float32Array;
};

export type SearchRequest = {
  area: LngLat[];
  maxDistanceM: number;
  maxElevationM: number;
  maxResults: number;
  dedupPermille: number;
};

export type ToWorker =
  | { type: 'load' }
  | { type: 'area'; area: LngLat[] }
  | { type: 'nodes'; area: LngLat[]; interactive: boolean }
  | { type: 'search'; request: SearchRequest }
  | { type: 'stop' };

export type FromWorker =
  | { type: 'load'; state: LoadState }
  | { type: 'area'; count: number }
  | { type: 'nodes'; points: Float32Array; total: number }
  | {
      type: 'search';
      stats: SearchStats;
      routes: Route[];
      routesChanged: boolean;
    };

export const GRAPH_ASSET = '/graph.tar.gz';
/** Built by `just wasm` and served from the site root. */
export const WASM_ASSET = '/zill.wasm';
export const DEDUP_PERMILLE = 500;
/** Climbs kept per search: enough to colour a whole area with routes. */
export const MAX_RESULT_ROUTES = 60;
/** Start nodes are always drawn; this caps only what crosses from the worker,
 *  after the worker has already merged nodes that share a cell. */
export const PINPRICK_LIMIT = 120_000;
export const PINPRICK_CELL_PX = 4;
/** Pairs per page, and how many spread pages a drag may read. */
export const NODE_PAGE = 8192;
export const NODE_PAGES_INTERACTIVE = 24;

export class ZillWorker {
  private worker: Worker;
  onLoad: (state: LoadState) => void = () => {};
  /** A worker that dies quietly leaves a dead map: say what happened. */
  onError: (message: string) => void = () => {};
  onArea: (count: number) => void = () => {};
  onNodes: (points: Float32Array, total: number) => void = () => {};
  onSearch: (
    stats: SearchStats,
    routes: Route[],
    routesChanged: boolean,
  ) => void = () => {};

  constructor() {
    this.worker = new Worker(new URL('./worker.ts', import.meta.url), {
      type: 'module',
    });
    this.worker.onerror = (event: ErrorEvent) => {
      this.onError(event.message || 'the graph worker stopped');
    };
    this.worker.onmessageerror = () =>
      this.onError('the graph worker sent a message that could not be read');
    this.worker.onmessage = (event: MessageEvent<FromWorker>) => {
      const message = event.data;
      if (message.type === 'load') this.onLoad(message.state);
      else if (message.type === 'area') this.onArea(message.count);
      else if (message.type === 'nodes')
        this.onNodes(message.points, message.total);
      else this.onSearch(message.stats, message.routes, message.routesChanged);
    };
  }

  post(message: ToWorker): void {
    this.worker.postMessage(message);
  }

  terminate(): void {
    this.worker.terminate();
  }
}
