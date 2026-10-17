// MapLibre layer over the swisstopo sheets. Terrain keeps its own colours; the
// only thing this module adds is the course: one overprint purple for the area
// and the ranked badges, and a light-to-dark purple for the route lines, whose
// darkness follows the grade of each stretch.
//
// Three grounds, each of them swisstopo's own product over its relief shading:
// the shading on its own, the greyscale sheet, and the aerial image. The sheet
// prints its own names, so the other two borrow swisstopo's names layer, which
// is written names only from z12 up: below that the same layer is a field of
// point symbols, and a field of symbols is not a map.

import maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import type { DataDrivenPropertyValueSpecification } from 'maplibre-gl';
import type { Feature, FeatureCollection } from 'geojson';
import { haversineMeters } from './area';
import type { LngLat, ScreenPoint } from './area';
import type { Route } from './wasm';
import { ROUTE_START_MARK } from './icons';

export const OVERPRINT = '#8e5cc0';
const PAPER = '#fbfaf7';
const WMTS = 'https://wmts.geo.admin.ch/1.0.0';

const SWITZERLAND: [number, number] = [8.23, 46.82];

/** The walkable graph's own extent: outside it there is nothing to search. */
const DATA_BOUNDS = { west: 5.9509, east: 10.5084, south: 45.8133, north: 47.811 };

/** How far the camera may leave that extent, so the country can be seen with
 *  ground around it rather than pinned to its own border. The swisstopo sheets
 *  carry real map for well over a hundred kilometres past the country, so this
 *  is headroom, not a walk to the edge of the tiles: the frame is always over
 *  them. */
const CAMERA_MARGIN_KM = 40;

function cameraBounds(marginKm: number): maplibregl.LngLatBounds {
  const midLat = ((DATA_BOUNDS.north + DATA_BOUNDS.south) / 2) * (Math.PI / 180);
  const dLng = marginKm / (111.32 * Math.cos(midLat));
  const dLat = marginKm / 110.57;
  return new maplibregl.LngLatBounds(
    [DATA_BOUNDS.west - dLng, DATA_BOUNDS.south - dLat],
    [DATA_BOUNDS.east + dLng, DATA_BOUNDS.north + dLat],
  );
}

/** Rank badges are worn by the strongest climbs only; the rest are lines. */
const BADGE_LIMIT = 10;
/** Steepness is the world's second carrier of order, after rank. The line keeps
 *  one weight; lightness carries the local grade, so a route shows where the
 *  climb actually bites. The paper casing is what keeps the darkest stretches
 *  legible on relief shading. */
const ROUTE_WIDTH = 4.2;
const ROUTE_CASING = 6.8;
export const GRADE_DEPTH: [number, string][] = [
  [0, '#cbaee0'],
  [12, '#b18bd6'],
  [24, '#8e5cc0'],
  [36, '#5c2a8a'],
  [48, '#14161a'],
];
/** Colours by the grade of each drawn stretch, not by the route's average. */
const GRADE_COLOR = ['interpolate', ['linear'], ['get', 'grade'], ...GRADE_DEPTH.flat()] as DataDrivenPropertyValueSpecification<string>;

export type Basemap = 'shade' | 'topo' | 'satellite';

export class CourseMap {
  readonly map: maplibregl.Map;
  /** Fired when the pointer enters or leaves a route line on the map. */
  onRouteHover: (rank: number | null) => void = () => {};
  /** Fired when a route line is clicked (null for a click on empty sheet). */
  onRouteClick: (rank: number | null) => void = () => {};
  private badges: { marker: maplibregl.Marker; badge: HTMLElement; route: Route }[] = [];
  private startMarker: maplibregl.Marker | null = null;
  /** Sources only exist after the style loads; until then, updates are held. */
  private styled = false;
  /** The first floor calculation also opens the map on the whole country. */
  private framedCountry = false;
  private pending = {
    area: null as LngLat[] | null,
    selected: null as number | null,
    starts: null as Float32Array | null,
    routes: [] as Route[],
    selectedRank: null as number | null,
    basemap: 'topo' as Basemap,
  };

  constructor(container: HTMLElement) {
    this.map = new maplibregl.Map({
      container,
      style: {
        version: 8,
        sources: {
          relief: {
            type: 'raster',
            tiles: [`${WMTS}/ch.swisstopo.swissalti3d-reliefschattierung/default/current/3857/{z}/{x}/{y}.png`],
            tileSize: 256,
            minzoom: 6,
            maxzoom: 17,
            attribution: '© <a href="https://www.swisstopo.admin.ch/">swisstopo</a> · relief',
          },
          sheet: {
            type: 'raster',
            tiles: [`${WMTS}/ch.swisstopo.pixelkarte-grau/default/current/3857/{z}/{x}/{y}.jpeg`],
            tileSize: 256,
            minzoom: 6,
            maxzoom: 17,
            attribution: '© <a href="https://www.swisstopo.admin.ch/">swisstopo</a> · pixelkarte grau',
          },
          satellite: {
            type: 'raster',
            tiles: [`${WMTS}/ch.swisstopo.swissimage/default/current/3857/{z}/{x}/{y}.jpeg`],
            tileSize: 256,
            minzoom: 6,
            maxzoom: 17,
            attribution: '© <a href="https://www.swisstopo.admin.ch/">swisstopo</a> · SWISSIMAGE',
          },
          names: {
            type: 'raster',
            tiles: [`${WMTS}/ch.swisstopo.vec200-names-namedlocation/default/current/3857/{z}/{x}/{y}.png`],
            tileSize: 256,
            minzoom: 12,
            maxzoom: 17,
            attribution: '© <a href="https://www.swisstopo.admin.ch/">swisstopo</a> · names',
          },
          area: { type: 'geojson', data: emptyCollection() },
          user: { type: 'geojson', data: emptyCollection() },
          vertices: { type: 'geojson', data: emptyCollection() },
          starts: { type: 'geojson', data: emptyCollection() },
          routes: { type: 'geojson', data: emptyCollection() },
        },
        layers: [
          // The ground stays quieter than the course on it: a cluttered sheet
          // costs legibility, and the routes are what the surface is for.
          { id: 'relief', type: 'raster', source: 'relief', paint: { 'raster-opacity': 0.38 } },
          { id: 'sheet', type: 'raster', source: 'sheet', paint: { 'raster-opacity': 0.74 } },
          { id: 'satellite', type: 'raster', source: 'satellite', layout: { visibility: 'none' }, paint: { 'raster-opacity': 0.85 } },
          // Labels the sheet already carries, for the grounds that carry none:
          // white-haloed, so they hold over pale shading and dark imagery alike.
          // Below their own zoom there is no transparent names source at all, so
          // the grounds simply carry no names there.
          { id: 'names', type: 'raster', source: 'names', minzoom: 12, layout: { visibility: 'none' } },
          {
            id: 'area-veil',
            type: 'fill',
            source: 'area',
            paint: { 'fill-color': PAPER, 'fill-opacity': 0.46 },
          },
          {
            id: 'area-fill',
            type: 'fill',
            source: 'area',
            paint: { 'fill-color': OVERPRINT, 'fill-opacity': 0.06 },
          },
          // Casing plus a solid 2 px edge: the drawn figure has to read instantly
          // over contour-dense sheets, and a dashed hairline did not.
          {
            id: 'area-casing',
            type: 'line',
            source: 'area',
            paint: { 'line-color': PAPER, 'line-width': 5, 'line-opacity': 0.7 },
          },
          {
            id: 'area-line',
            type: 'line',
            source: 'area',
            paint: { 'line-color': OVERPRINT, 'line-width': 2 },
          },
          {
            id: 'starts',
            type: 'circle',
            source: 'starts',
            paint: {
              // Small on purpose: the field reads as texture, never as blobs.
              'circle-radius': ['interpolate', ['linear'], ['zoom'], 8, 1, 14, 2.1],
              'circle-color': OVERPRINT,
              'circle-opacity': 0.4,
            },
          },
          {
            id: 'user-accuracy',
            type: 'circle',
            source: 'user',
            paint: {
              'circle-radius': ['interpolate', ['linear'], ['zoom'], 8, 6, 16, 60],
              'circle-color': OVERPRINT,
              'circle-opacity': 0.12,
            },
          },
          {
            id: 'user-dot',
            type: 'circle',
            source: 'user',
            paint: {
              'circle-radius': ['interpolate', ['linear'], ['zoom'], 8, 4, 16, 7],
              'circle-color': PAPER,
              'circle-stroke-color': OVERPRINT,
              'circle-stroke-width': 2.5,
            },
          },
          // A paper casing under the course: map-making's own way of keeping a
          // line readable over dense contours, and it costs no second colour.
          {
            id: 'routes-casing',
            type: 'line',
            source: 'routes',
            layout: { 'line-cap': 'round', 'line-join': 'round' },
            paint: {
              'line-color': PAPER,
              'line-width': ROUTE_CASING,
              'line-opacity': 0.78,
            },
          },
          {
            id: 'routes',
            type: 'line',
            source: 'routes',
            layout: { 'line-cap': 'round', 'line-join': 'round' },
            paint: {
              'line-color': GRADE_COLOR,
              'line-width': ROUTE_WIDTH,
              'line-opacity': 1,
            },
          },
          {
            id: 'routes-active',
            type: 'line',
            source: 'routes',
            filter: ['==', ['get', 'selected'], true],
            layout: { 'line-cap': 'round', 'line-join': 'round' },
            paint: { 'line-color': OVERPRINT, 'line-width': 9, 'line-opacity': 1 },
          },
          {
            id: 'vertices',
            type: 'circle',
            source: 'vertices',
            paint: {
              'circle-radius': ['case', ['get', 'selected'], 8, 6.5],
              'circle-color': PAPER,
              'circle-stroke-color': OVERPRINT,
              'circle-stroke-width': ['case', ['get', 'selected'], 3, 2.25],
            },
          },
        ],
      },
      center: SWITZERLAND,
      zoom: 7.4,
      minZoom: 6,
      maxBounds: cameraBounds(CAMERA_MARGIN_KM),
      maxZoom: 16.5,
      attributionControl: false,
      dragRotate: false,
      pitchWithRotate: false,
      touchPitch: false,
    });

    this.map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
    this.map.addControl(new maplibregl.ScaleControl({ maxWidth: 110, unit: 'metric' }), 'bottom-left');
    this.map.addControl(
      new maplibregl.AttributionControl({
        compact: true,
        customAttribution:
          '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap contributors</a> · ' +
          '<a href="https://maplibre.org/">MapLibre</a>',
      }),
      'bottom-right',
    );
    this.map.touchZoomRotate.disableRotation();
    this.map.on('resize', () => this.applyCameraFloor());
    this.map.on('mousemove', 'routes', (event) => {
      const rank = event.features?.[0]?.properties?.rank;
      this.setHoverCursor('pointer');
      this.onRouteHover(typeof rank === 'number' ? rank : null);
    });
    this.map.on('mouseleave', 'routes', () => {
      this.setHoverCursor('');
      this.onRouteHover(null);
    });
    this.map.on('click', 'routes', (event) => {
      const rank = event.features?.[0]?.properties?.rank;
      if (typeof rank === 'number') this.onRouteClick(rank);
    });
    this.map.on('click', (event) => {
      // Layer handlers run first; a click that hit no route clears the pin.
      if (this.map.queryRenderedFeatures(event.point, { layers: ['routes'] }).length === 0) {
        this.onRouteClick(null);
      }
    });
  }

  /** Zooming out stops where the country and its margin still fit, so the sheet
   *  never ends mid-viewport: no seam between the tiles and the paper around them. */
  private applyCameraFloor(): void {
    const box = cameraBounds(CAMERA_MARGIN_KM);
    const fitted = this.map.cameraForBounds(box, { padding: 24 });
    if (!fitted || typeof fitted.zoom !== 'number') return;
    this.map.setMinZoom(fitted.zoom);
    if (!this.framedCountry) {
      this.framedCountry = true;
      // The clamp owns the framing: at the floor the country fills the frame,
      // which is the widest view the tiles cover.
      this.map.fitBounds(box, { padding: 24, duration: 0 });
      return;
    }
    if (this.map.getZoom() < fitted.zoom) this.map.setZoom(fitted.zoom);
  }

  setBasemap(kind: Basemap): void {
    this.pending.basemap = kind;
    if (!this.styled) return;
    // The shading is the ground under all three. Only the shade ground shows it
    // on its own, so only there does it carry the full weight.
    this.map.setPaintProperty('relief', 'raster-opacity', kind === 'shade' ? 0.88 : 0.38);
    this.map.setLayoutProperty('sheet', 'visibility', kind === 'topo' ? 'visible' : 'none');
    this.map.setLayoutProperty('satellite', 'visibility', kind === 'satellite' ? 'visible' : 'none');
    // The greyscale sheet prints its own names; the other two grounds borrow these.
    this.map.setLayoutProperty('names', 'visibility', kind === 'topo' ? 'none' : 'visible');
  }

  /** Takes the camera to a place the search found. */
  showPlace(at: LngLat, zoom: number): void {
    this.map.flyTo({ center: [at.lng, at.lat], zoom, duration: this.cameraMs(700) });
  }

  /** Frames one chosen climb: tapping its row means "show me this". */
  focusRoute(route: Route): void {
    if (route.points.length < 3) return;
    const first: [number, number] = [route.points[1], route.points[0]];
    const bounds = new maplibregl.LngLatBounds(first, first);
    for (let i = 0; i < route.points.length; i += 3) bounds.extend([route.points[i + 1], route.points[i]]);
    this.map.fitBounds(bounds, { padding: this.sheetPadding(60), duration: this.cameraMs(500), maxZoom: 14.5 });
  }

  /** Shows the visitor's own position, with the accuracy it was reported with. */
  showUserLocation(at: LngLat, accuracyM: number): void {
    if (!this.styled) return;
    (this.map.getSource('user') as maplibregl.GeoJSONSource).setData({
      type: 'FeatureCollection',
      features: [
        {
          type: 'Feature',
          properties: { accuracy: accuracyM },
          geometry: { type: 'Point', coordinates: [at.lng, at.lat] },
        },
      ],
    });
  }

  clearUserLocation(): void {
    if (!this.styled) return;
    (this.map.getSource('user') as maplibregl.GeoJSONSource).setData(emptyCollection());
  }

  ready(): Promise<void> {
    const { promise, resolve } = Promise.withResolvers<void>();
    this.map.once('load', () => {
      this.styled = true;
      this.applyCameraFloor();
      this.setArea(this.pending.area, this.pending.selected);
      this.setStarts(this.pending.starts);
      this.setRoutes(this.pending.routes, this.pending.selectedRank);
      this.setBasemap(this.pending.basemap);
      resolve();
    });
    return promise;
  }

  toScreen(points: LngLat[]): ScreenPoint[] {
    return points.map((point) => {
      const projected = this.map.project(point);
      return { x: projected.x, y: projected.y };
    });
  }

  fromScreen(point: ScreenPoint): LngLat {
    const unprojected = this.map.unproject([point.x, point.y]);
    return { lng: unprojected.lng, lat: unprojected.lat };
  }

  setPanEnabled(enabled: boolean): void {
    if (enabled) {
      this.map.dragPan.enable();
    } else {
      this.map.dragPan.disable();
    }
  }

  setArea(area: LngLat[] | null, selected: number | null): void {
    this.pending.area = area;
    this.pending.selected = selected;
    if (!this.styled) return;
    const ring = area && area.length >= 3 ? [...area, area[0]] : [];
    (this.map.getSource('area') as maplibregl.GeoJSONSource).setData({
      type: 'FeatureCollection',
      features: ring.length
        ? [{ type: 'Feature', properties: {}, geometry: { type: 'Polygon', coordinates: [ring.map((p) => [p.lng, p.lat])] } }]
        : [],
    });
    (this.map.getSource('vertices') as maplibregl.GeoJSONSource).setData({
      type: 'FeatureCollection',
      features: (area ?? []).map((point, index) => ({
        type: 'Feature',
        properties: { selected: index === selected ? 1 : 0 },
        geometry: { type: 'Point', coordinates: [point.lng, point.lat] },
      })),
    });
  }

  /** Pointer feedback over the drawn figure: what a press would do here. */
  setHoverCursor(cursor: 'grab' | 'copy' | 'move' | 'pointer' | ''): void {
    this.map.getCanvas().style.cursor = cursor;
  }

  setStarts(nodes: Float32Array | null): void {
    this.pending.starts = nodes;
    if (!this.styled) return;
    const features: Feature[] = [];
    if (nodes) {
      for (let i = 0; i < nodes.length; i += 2) {
        features.push({
          type: 'Feature',
          properties: {},
          geometry: { type: 'Point', coordinates: [nodes[i + 1], nodes[i]] },
        });
      }
    }
    (this.map.getSource('starts') as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features });
  }

  setRoutes(routes: Route[], selectedRank: number | null): void {
    this.pending.routes = routes;
    this.pending.selectedRank = selectedRank;
    if (!this.styled) return;
    const features: Feature[] = [];
    for (const route of routes) {
      const points: { lat: number; lng: number; ele: number }[] = [];
      for (let i = 0; i < route.points.length; i += 3) {
        points.push({ lat: route.points[i], lng: route.points[i + 1], ele: route.points[i + 2] });
      }
      if (points.length < 2) continue;

      const runs: number[] = [];
      const rises: number[] = [];
      for (let i = 0; i < points.length - 1; i++) {
        runs.push(Math.max(haversineMeters(points[i], points[i + 1]), 1));
        rises.push(points[i + 1].ele - points[i].ele);
      }
      const raw = rises.map((rise, i) => (rise / runs[i]) * 100);

      for (let i = 0; i < points.length - 1; i++) {
        // Smooth over three segments so a single DEM step does not read as a cliff.
        let weighted = 0;
        let weight = 0;
        for (let j = Math.max(0, i - 1); j <= Math.min(raw.length - 1, i + 1); j++) {
          weighted += raw[j] * runs[j];
          weight += runs[j];
        }
        const grade = Math.max(0, Math.min(60, weighted / weight));
        const coordinates: [number, number][] = [
          [points[i].lng, points[i].lat],
          [points[i + 1].lng, points[i + 1].lat],
        ];
        features.push({
          type: 'Feature',
          properties: { rank: route.rank, grade: Number(grade.toFixed(2)), selected: route.rank === selectedRank },
          geometry: { type: 'LineString', coordinates },
        });
      }
    }
    (this.map.getSource('routes') as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features });

    for (const badge of this.badges) badge.marker.remove();
    this.badges = routes.slice(0, BADGE_LIMIT).map((route) => {
      // MapLibre owns the holder's transform; the badge inside it is ours to
      // nudge, which is what keeps a crowded summit's numbers apart.
      const holder = document.createElement('span');
      holder.className = 'route-badge-holder';
      const badge = document.createElement('span');
      badge.className = 'route-badge';
      badge.textContent = String(route.rank);
      if (route.rank === selectedRank) badge.classList.add('is-selected');
      holder.appendChild(badge);
      const last = route.points.length - 3;
      const marker = new maplibregl.Marker({ element: holder, anchor: 'center' })
        .setLngLat([route.points[last + 1], route.points[last]])
        .addTo(this.map);
      return { marker, badge, route };
    });
    this.layoutBadges();
  }

  /// Rank is this world's only carrier of order, so a badge that lands on
  /// another one is unreadable: nudge it along a small ring until it is clear.
  layoutBadges(): void {
    const placed: { x: number; y: number }[] = [];
    for (const { badge, route } of this.badges) {
      const last = route.points.length - 3;
      const at = this.map.project([route.points[last + 1], route.points[last]]);
      // Candidates follow this route's own tail: sideways or back along its
      // final segment, never off toward a neighbouring line.
      // The point before the summit: its longitude at last-2, latitude at last-3.
      const tail = last >= 3 ? this.map.project([route.points[last - 2], route.points[last - 3]]) : at;
      const dx = at.x - tail.x;
      const dy = at.y - tail.y;
      const length = Math.hypot(dx, dy) || 1;
      const along: [number, number] = [dx / length, dy / length];
      const across: [number, number] = [-along[1], along[0]];
      const at2 = (axis: [number, number], distance: number): [number, number] => [axis[0] * distance, axis[1] * distance];
      const clearance = 20;
      const ring: [number, number][] = [
        [0, 0],
        at2(across, clearance), at2(across, -clearance),
        at2(along, clearance + 2), at2(along, -(clearance + 2)),
        at2(across, clearance * 1.7), at2(across, -clearance * 1.7),
        at2(along, clearance * 1.9), at2(along, -(clearance * 1.9)),
        at2(across, clearance * 2.4), at2(across, -(clearance * 2.4)),
        at2(along, clearance * 2.6), at2(along, -(clearance * 2.6)),
      ];
      // Take the first clear slot; with a crowded summit, take the roomiest.
      let chosen: [number, number] = [0, 0];
      let bestRoom = -1;
      for (const spot of ring) {
        const candidate = { x: at.x + spot[0], y: at.y + spot[1] };
        const room = placed.reduce(
          (closest, p) => Math.min(closest, Math.hypot(p.x - candidate.x, p.y - candidate.y)),
          Number.POSITIVE_INFINITY,
        );
        if (room >= clearance) {
          chosen = spot;
          bestRoom = room;
          break;
        }
        if (room > bestRoom) {
          bestRoom = room;
          chosen = spot;
        }
      }
      placed.push({ x: at.x + chosen[0], y: at.y + chosen[1] });
      badge.style.transform = `translate(${chosen[0]}px, ${chosen[1]}px)`;
    }
  }

  /** A camera flight respects a visitor who asked for less motion. */
  private cameraMs(milliseconds: number): number {
    return typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : milliseconds;
  }

  /**
   * The map fills the frame, but the panel covers part of it. Framing calls
   * reserve that part, so whatever they fit lands where it can be seen: the sheet
   * is a column on a wide screen and a band on a narrow one.
   */
  private sheetPadding(base: number): { top: number; right: number; bottom: number; left: number } {
    const rect = document.querySelector('.panel')?.getBoundingClientRect();
    const clear = { top: base, right: base, bottom: base, left: base };
    if (!rect || rect.width === 0) return clear;
    // Same breakpoint as the stylesheet: below it the sheet lies along the bottom.
    return matchMedia('(max-width: 900px)').matches
      ? { ...clear, bottom: base + rect.height }
      : { ...clear, left: base + rect.width };
  }

  fitToArea(area: LngLat[]): void {
    // `LngLatBounds.extend` mutates and returns nothing.
    const bounds = new maplibregl.LngLatBounds([area[0].lng, area[0].lat], [area[0].lng, area[0].lat]);
    for (const point of area) bounds.extend([point.lng, point.lat]);
    this.map.fitBounds(bounds, { padding: this.sheetPadding(80), duration: this.cameraMs(450), maxZoom: 14 });
  }

  /**
   * A play mark where the chosen climb begins, turned to the direction it
   * leaves in: the course reads as a route, not just as a line.
   */
  showRouteStart(route: Route | null): void {
    if (!this.styled) return;
    if (this.startMarker) {
      this.startMarker.remove();
      this.startMarker = null;
    }
    if (!route || route.points.length < 6) return;
    const east = route.points[3] - route.points[0];
    const north = route.points[4] - route.points[1];
    const bearing = (Math.atan2(east, north) * 180) / Math.PI;

    const holder = document.createElement('span');
    holder.className = 'route-start-holder';
    const mark = document.createElement('span');
    mark.className = 'route-start';
    mark.style.transform = `rotate(${bearing.toFixed(1)}deg)`;
    mark.innerHTML = ROUTE_START_MARK;
    holder.appendChild(mark);
    this.startMarker = new maplibregl.Marker({ element: holder, anchor: 'center' })
      .setLngLat([route.points[1], route.points[0]])
      .addTo(this.map);
  }

  /** Frames the drawn area together with the climbs found from it. */
  fitToAreaAndRoutes(area: LngLat[] | null, routes: Route[]): void {
    const first = area?.[0] ?? (routes[0] ? { lng: routes[0].points[1], lat: routes[0].points[0] } : null);
    if (!first) return;
    const bounds = new maplibregl.LngLatBounds([first.lng, first.lat], [first.lng, first.lat]);
    for (const point of area ?? []) bounds.extend([point.lng, point.lat]);
    for (const route of routes) {
      for (let i = 0; i < route.points.length; i += 3) bounds.extend([route.points[i + 1], route.points[i]]);
    }
    this.map.fitBounds(bounds, { padding: this.sheetPadding(60), duration: this.cameraMs(600), maxZoom: 14.5 });
  }
}

function emptyCollection(): FeatureCollection {
  return { type: 'FeatureCollection', features: [] };
}
