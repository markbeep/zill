/** Keeps one point per cell of a degree grid, up to `limit` points, in insertion order. */
export class GridSampler {
  private readonly cell: number;
  private readonly limit: number;
  private readonly cells = new Set<number>();
  private readonly cols: number;
  private readonly buf: Float32Array;
  private count = 0;

  constructor(cellDegrees: number, limit: number) {
    this.cell = cellDegrees;
    this.limit = limit;
    this.cols = Math.ceil(360 / cellDegrees) + 1;
    this.buf = new Float32Array(limit * 2);
  }

  /** Returns false once the limit is reached or the cell already holds a point. */
  add(lat: number, lng: number): boolean {
    if (this.count >= this.limit) return false;
    const key = Math.floor(lat / this.cell) * this.cols + Math.floor(lng / this.cell);
    if (this.cells.has(key)) return false;
    this.cells.add(key);
    this.buf[this.count * 2] = lat;
    this.buf[this.count * 2 + 1] = lng;
    this.count++;
    return true;
  }

  /** Interleaved lat, lng pairs kept so far, as a fresh array. */
  toArray(): Float32Array {
    return this.buf.slice(0, this.count * 2);
  }

  get size(): number {
    return this.count;
  }
}

/** Keeps one point per screen cell of `cellPx`, so a dense field thins out by zoom. */
export function clusterByScreen(
  points: Float32Array,
  project: (lngLat: [number, number]) => { x: number; y: number },
  cellPx: number,
  limit: number,
): Float32Array {
  const out = new Float32Array(limit * 2);
  const cells = new Set<number>();
  let count = 0;
  for (let i = 0; i < points.length && count < limit; i += 2) {
    const { x, y } = project([points[i + 1], points[i]]);
    const key = Math.floor(y / cellPx) * 1e7 + Math.floor(x / cellPx);
    if (cells.has(key)) continue;
    cells.add(key);
    out[count * 2] = points[i];
    out[count * 2 + 1] = points[i + 1];
    count++;
  }
  return out.slice(0, count * 2);
}
