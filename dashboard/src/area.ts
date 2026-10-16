// Search-area geometry. Vertices are kept in geographic coordinates; hit tests
// run on projected screen points, because a pointer cares about pixels, not
// degrees.

export type LngLat = { lng: number; lat: number };
export type ScreenPoint = { x: number; y: number };

export const MIN_VERTICES = 3;
export const INITIAL_EDGE_M = 5000;
export const VERTEX_HIT_PX = 14;
export const EDGE_HIT_PX = 10;

const M_PER_DEG_LAT = 110574;
const M_PER_DEG_LNG_EQ = 111320;

function metersPerDegLng(lat: number): number {
  return M_PER_DEG_LNG_EQ * Math.cos((lat * Math.PI) / 180);
}

/** The first area: an equilateral triangle with ~5 km sides. */
export function initialTriangle(center: LngLat): LngLat[] {
  const circumradius = INITIAL_EDGE_M / Math.sqrt(3);
  const metersPerLng = metersPerDegLng(center.lat);
  return [90, 210, 330].map((degrees) => {
    const radians = (degrees * Math.PI) / 180;
    return {
      lat: center.lat + (circumradius * Math.sin(radians)) / M_PER_DEG_LAT,
      lng: center.lng + (circumradius * Math.cos(radians)) / metersPerLng,
    };
  });
}

export function moveVertex(area: LngLat[], index: number, to: LngLat): LngLat[] {
  return area.map((point, i) => (i === index ? to : point));
}

export function insertVertex(area: LngLat[], edge: number, at: LngLat): LngLat[] {
  const next = [...area];
  next.splice(edge + 1, 0, at);
  return next;
}

export function removeVertex(area: LngLat[], index: number): LngLat[] {
  if (area.length <= MIN_VERTICES) return area;
  return area.filter((_, i) => i !== index);
}

export function edgeMidpoints(area: LngLat[]): LngLat[] {
  return area.map((point, i) => {
    const next = area[(i + 1) % area.length];
    return { lng: (point.lng + next.lng) / 2, lat: (point.lat + next.lat) / 2 };
  });
}

/** Great-circle distance, matching the metric the search itself uses. */
export function haversineMeters(a: LngLat, b: LngLat): number {
  const r = 6371000;
  const dLat = ((b.lat - a.lat) * Math.PI) / 180;
  const dLng = ((b.lng - a.lng) * Math.PI) / 180;
  const sinLat = Math.sin(dLat / 2);
  const sinLng = Math.sin(dLng / 2);
  const h =
    sinLat * sinLat +
    Math.cos((a.lat * Math.PI) / 180) * Math.cos((b.lat * Math.PI) / 180) * sinLng * sinLng;
  return 2 * r * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

export function perimeterM(area: LngLat[]): number {
  return area.reduce((total, point, i) => total + haversineMeters(point, area[(i + 1) % area.length]), 0);
}

/** Shoelace area in square metres, on a local equirectangular frame. */
export function areaM2(area: LngLat[]): number {
  const lat0 = area.reduce((sum, point) => sum + point.lat, 0) / area.length;
  const metersPerLng = metersPerDegLng(lat0);
  let sum = 0;
  for (let i = 0; i < area.length; i++) {
    const a = area[i];
    const b = area[(i + 1) % area.length];
    sum += a.lng * b.lat - b.lng * a.lat;
  }
  return Math.abs(sum / 2) * metersPerLng * M_PER_DEG_LAT;
}

export function nearestVertex(screen: ScreenPoint[], at: ScreenPoint): number | null {
  let best: number | null = null;
  let bestDistance = VERTEX_HIT_PX;
  screen.forEach((point, i) => {
    const distance = Math.hypot(point.x - at.x, point.y - at.y);
    if (distance <= bestDistance) {
      bestDistance = distance;
      best = i;
    }
  });
  return best;
}

function distanceToSegment(p: ScreenPoint, a: ScreenPoint, b: ScreenPoint): number {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const lengthSq = dx * dx + dy * dy;
  const t = lengthSq === 0 ? 0 : Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq));
  return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}

/** Even-odd test on projected points, for pointer feedback. */
export function insidePolygon(screen: ScreenPoint[], at: ScreenPoint): boolean {
  let inside = false;
  for (let i = 0, j = screen.length - 1; i < screen.length; j = i++) {
    const a = screen[i];
    const b = screen[j];
    if (a.y > at.y !== b.y > at.y && at.x < ((b.x - a.x) * (at.y - a.y)) / (b.y - a.y) + a.x) inside = !inside;
  }
  return inside;
}

/** Index of the edge (from its first vertex) nearest the pointer. */
export function nearestEdge(screen: ScreenPoint[], at: ScreenPoint): number | null {
  let best: number | null = null;
  let bestDistance = EDGE_HIT_PX;
  screen.forEach((point, i) => {
    const next = screen[(i + 1) % screen.length];
    const distance = distanceToSegment(at, point, next);
    if (distance <= bestDistance) {
      bestDistance = distance;
      best = i;
    }
  });
  return best;
}

/**
 * Degrees per metre at the area's latitude, for keyboard nudges: the same
 * equirectangular approximation `areaM2` uses, so a nudge and a readout agree.
 */
export function degreesPerMeter(area: LngLat[], meters: number): LngLat {
  const lat0 = area.reduce((sum, point) => sum + point.lat, 0) / area.length;
  return { lat: meters / M_PER_DEG_LAT, lng: meters / metersPerDegLng(lat0) };
}
