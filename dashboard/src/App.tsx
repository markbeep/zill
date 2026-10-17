import { createEffect, createMemo, createSignal, Index, onCleanup, onMount, Show } from 'solid-js';
import type maplibregl from 'maplibre-gl';
import { CourseMap } from './map';
import type { Basemap } from './map';
import { clusterByScreen } from './cluster';
import { LocateIcon, RedoIcon, UndoIcon } from './icons';
import { downloadGpx } from './gpx';
import { DEDUP_PERMILLE, MAX_RESULT_ROUTES, PINPRICK_CELL_PX, ZillWorker } from './wasm';
import type { LoadState, Route, SearchStats } from './wasm';
import {
  areaM2,
  degreesPerMeter,
  haversineMeters,
  initialTriangle,
  insertVertex,
  insidePolygon,
  MIN_VERTICES,
  moveVertex,
  nearestEdge,
  nearestVertex,
  perimeterM,
  removeVertex,
} from './area';
import type { LngLat } from './area';
import type { Place } from './geocode';
import { Panel, HOVER_CAPABLE, swiss } from './components/Panel';
import { PlaceSearch } from './components/PlaceSearch';

const IDLE_LOAD: LoadState = {
  phase: 'idle',
  received: 0,
  total: 0,
  inflated: 0,
  graphBytes: 0,
  progress: 0,
  nodes: 0,
  edges: 0,
};

/** An edge shorter than this on screen carries no label: lengths drawn over a
 *  figure a few dozen pixels wide would cover the whole figure. */
const EDGE_LABEL_MIN_PX = 48;

export default function App() {
  let mapContainer!: HTMLDivElement;
  let courseMap: CourseMap | undefined;
  let worker: ZillWorker | undefined;

  const [area, setArea] = createSignal<LngLat[] | null>(null);
  const [selectedVertex, setSelectedVertex] = createSignal<number | null>(null);
  const [dragging, setDragging] = createSignal<number | null>(null);
  const [hoveredVertex, setHoveredVertex] = createSignal<number | null>(null);
  const [mapVersion, setMapVersion] = createSignal(0);
  const [load, setLoad] = createSignal<LoadState>(IDLE_LOAD);
  const [nodeCount, setNodeCount] = createSignal(0);
  const [stats, setStats] = createSignal<SearchStats | null>(null);
  const [routes, setRoutes] = createSignal<Route[]>([]);
  const [distanceM, setDistanceM] = createSignal(1000);
  const [notice, setNotice] = createSignal<string | null>(null);
  const [nodes, setNodes] = createSignal<Float32Array | null>(null);
  const [viewKey, setViewKey] = createSignal(0);
  const [basemap, setBasemap] = createSignal<Basemap>('topo');
  const [locating, setLocating] = createSignal<'idle' | 'busy' | 'shown'>('idle');
  const [panelOpen, setPanelOpen] = createSignal(true);
  const [searching, setSearching] = createSignal(false);
  const [hoveredRoute, setHoveredRoute] = createSignal<number | null>(null);
  const [pinnedRoute, setPinnedRoute] = createSignal<number | null>(null);
  /** The point a tap asked about, held until the visitor answers. */
  const [pendingDelete, setPendingDelete] = createSignal<number | null>(null);
  /** A pinned route outlives the pointer; hover is only a preview. */
  const selectedRoute = () => pinnedRoute() ?? hoveredRoute();
  /** The camera frames the course once per search unless the visitor moves it. */
  let cameraOwned = true;
  let framedRun = false;
  /** Set when an edit stops a run; cleared when the next run starts. */
  let discardReports = false;

  const ready = createMemo(() => load().phase === 'ready');

  const vertexPoints = createMemo(() => {
    mapVersion();
    const current = area();
    const map = courseMap;
    if (!current || !map) return [];
    return map.toScreen(current);
  });
  const figures = createMemo(() => {
    const current = area();
    if (!current) return null;
    return {
      vertices: current.length,
      hectares: areaM2(current) / 10_000,
      perimeterKm: perimeterM(current) / 1000,
    };
  });

  /**
   * Each edge's length at its midpoint, for as long as a drag is in flight and
   * no longer. The same great-circle metric the search uses, so a number read
   * off the figure is the number the run will walk.
   */
  const edgeLabels = createMemo(() => {
    if (dragging() === null) return [];
    const current = area();
    const screen = vertexPoints();
    if (!current || screen.length !== current.length) return [];
    const labels: { x: number; y: number; text: string }[] = [];
    for (let i = 0; i < current.length; i += 1) {
      const a = screen[i];
      const b = screen[(i + 1) % screen.length];
      if (Math.hypot(b.x - a.x, b.y - a.y) < EDGE_LABEL_MIN_PX) continue;
      const km = haversineMeters(current[i], current[(i + 1) % current.length]) / 1000;
      labels.push({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, text: `${swiss(km, km < 1 ? 2 : 1)} km` });
    }
    return labels;
  });

  /** A press that never moves is a click; anything else belongs to the map. */
  const TAP_SLOP_PX = 6;
  let tap: { pointerId: number; x: number; y: number; moved: boolean } | null = null;
  /** The same rule on a vertex handle: a press that never moves asks to delete. */
  let vertexPress: { index: number; x: number; y: number; moved: boolean } | null = null;
  /** Pointers down on the map. A second one turns the gesture into a pinch. */
  const activePointers = new Set<number>();
  /** The pointer that owns the current vertex drag; no other may move it. */
  let dragPointer: number | null = null;

  let areaFrame = 0;
  function requestArea(): void {
    cancelAnimationFrame(areaFrame);
    areaFrame = requestAnimationFrame(() => {
      const current = area();
      if (!current || !ready()) {
        setNodeCount(0);
        setNodes(null);
        return;
      }
      worker?.post({ type: 'area', area: current });
    });
  }

  /**
   * The start-node field is always drawn, so it is a separate query. While the
   * figure is being dragged it reads one page per call and the settle reads the
   * whole field, which keeps the dots moving with the shape.
   */
  function requestNodes(interactive = false): void {
    const current = area();
    if (!current || !ready()) {
      setNodes(null);
      return;
    }
    worker?.post({ type: 'nodes', area: current, interactive });
  }

  /** Every state the figure has been in, including "no figure". */
  const undoStack: (LngLat[] | null)[] = [];
  const redoStack: (LngLat[] | null)[] = [];
  const [undoDepth, setUndoDepth] = createSignal(0);
  const [redoDepth, setRedoDepth] = createSignal(0);
  let lastNudgeSnapshot = 0;

  const snapshot = (): LngLat[] | null => {
    const current = area();
    return current ? current.map((point) => ({ ...point })) : null;
  };

  function applySnapshot(next: LngLat[] | null): void {
    stopSearch(true);
    setPendingDelete(null);
    setSelectedVertex(null);
    setArea(next);
    requestArea();
    requestNodes();
  }

  /** Snapshot before a change. `coalesce` folds a burst of nudges into one. */
  function remember(coalesce = false): void {
    if (coalesce) {
      const now = performance.now();
      if (now - lastNudgeSnapshot < 600) return;
      lastNudgeSnapshot = now;
    }
    undoStack.push(snapshot());
    redoStack.length = 0;
    setRedoDepth(0);
    if (undoStack.length > 20) undoStack.shift();
    setUndoDepth(undoStack.length);
  }

  function undo(): void {
    if (undoStack.length === 0) {
      announce('nothing to undo');
      return;
    }
    redoStack.push(snapshot());
    setRedoDepth(redoStack.length);
    const previous = undoStack.pop() ?? null;
    setUndoDepth(undoStack.length);
    applySnapshot(previous);
  }

  function redo(): void {
    if (redoStack.length === 0) {
      announce('nothing to redo');
      return;
    }
    undoStack.push(snapshot());
    setUndoDepth(undoStack.length);
    const next = redoStack.pop() ?? null;
    setRedoDepth(redoStack.length);
    applySnapshot(next);
  }

  onMount(() => {
    courseMap = new CourseMap(mapContainer);
    let badgeFrame = 0;
    courseMap.map.on('move', () => {
      setMapVersion((version) => version + 1);
      cancelAnimationFrame(badgeFrame);
      badgeFrame = requestAnimationFrame(() => courseMap?.layoutBadges());
    });
    // The pinprick field is re-thinned only when the camera settles.
    courseMap.map.on('moveend', () => setViewKey((key) => key + 1));
    courseMap.map.on('zoomend', () => setViewKey((key) => key + 1));
    courseMap.onRouteHover = (rank) => setHoveredRoute(rank);
    courseMap.onRouteClick = (rank) => {
      setPinnedRoute(rank);
      if (rank === null) return;
      // Instant, not smooth: a tap that lands while the panel is still gliding
      // is spent stopping the glide instead of doing what it was aimed at.
      document.querySelector(`.route[data-rank="${rank}"]`)?.scrollIntoView({ block: 'nearest' });
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setPendingDelete(null);
        return;
      }
      if (!(event.metaKey || event.ctrlKey) || event.target instanceof HTMLInputElement) return;
      const key = event.key.toLowerCase();
      if (key === 'z' && event.shiftKey) {
        event.preventDefault();
        redo();
      } else if (key === 'z' || key === 'y') {
        event.preventDefault();
        if (key === 'y') redo();
        else undo();
      }
    };
    window.addEventListener('keydown', onKeyDown);
    onCleanup(() => window.removeEventListener('keydown', onKeyDown));
    courseMap.map.on('dragstart', () => {
      cameraOwned = false;
    });
    courseMap.map.on('zoomstart', (event: { originalEvent?: unknown }) => {
      if (event.originalEvent) cameraOwned = false;
    });
    if (import.meta.env.DEV) {
      // Development handle for inspecting layers and camera in the browser.
      (globalThis as unknown as { zillMap?: maplibregl.Map }).zillMap = courseMap.map;
    }

    worker = new ZillWorker();
    worker.onLoad = (state) => {
      setLoad(state);
      if (state.phase === 'ready') requestArea();
    };
    worker.onArea = (count) => {
      setNodeCount(count);
    };
    worker.onNodes = (points) => setNodes(points.length > 0 ? points : null);
    worker.onError = (message) => announce(message);
    worker.onSearch = (next, nextRoutes, changed) => {
      if (discardReports) return;
      setStats(next);
      if (changed) setRoutes(nextRoutes);
      if (next.finished) setSearching(false);
      if (changed && nextRoutes.length > 0 && !framedRun && cameraOwned) {
        framedRun = true;
        courseMap?.fitToAreaAndRoutes(area(), nextRoutes);
      }
    };
    void courseMap.ready().then(() => {
      setMapVersion((version) => version + 1);
      setViewKey((key) => key + 1);
      worker?.post({ type: 'load' });
    });

    const container = mapContainer;
    const pointerOf = (event: PointerEvent) => {
      const rect = container.getBoundingClientRect();
      return { x: event.clientX - rect.left, y: event.clientY - rect.top };
    };

    const onPointerDown = (event: PointerEvent) => {
      activePointers.add(event.pointerId);
      // A second finger is a pinch, never an edit: drop any tap or vertex drag
      // the first finger started, so zooming does not reshape the area.
      if (activePointers.size > 1) {
        tap = null;
        abortDrag();
        return;
      }
      if (event.button !== 0 || !courseMap) return;
      // Map chrome and our own controls own their clicks: the attribution
      // toggle, the zoom buttons and the toolbar must never place an area.
      if ((event.target as HTMLElement).closest('.maplibregl-ctrl, .map__toolbar, button')) return;
      const point = pointerOf(event);
      const current = area();
      if (!current) {
        // Do not claim the gesture: a drag here is a pan. Whether this becomes
        // the first area is decided on release.
        tap = { pointerId: event.pointerId, x: point.x, y: point.y, moved: false };
        return;
      }
      const screen = courseMap.toScreen(current);
      const vertex = nearestVertex(screen, point);
      if (vertex !== null && event.shiftKey) {
        event.preventDefault();
        event.stopPropagation();
        removeVertexAt(vertex);
        return;
      }
      const edge = nearestEdge(screen, point);
      if (edge === null) return;
      event.preventDefault();
      event.stopPropagation();
      // Snapshot before the figure changes, and do not snapshot again when the
      // drag that follows starts: the new vertex is already part of this step.
      remember();
      const inserted = insertVertex(current, edge, courseMap.fromScreen(point));
      setArea(inserted);
      setSelectedVertex(edge + 1);
      startDrag(edge + 1, event, false);
    };

    const onPointerMove = (event: PointerEvent) => {
      // Fingers moving during a pinch must not drag a vertex or count as a tap.
      if (activePointers.size > 1) {
        abortDrag();
        return;
      }
      // Only the pointer that started the drag may move the vertex. A move
      // from another one means a second finger is down: a pinch, not an edit.
      if (dragging() !== null && event.pointerId !== dragPointer) {
        abortDrag();
        return;
      }
      if (tap && event.pointerId === tap.pointerId) {
        const point = pointerOf(event);
        if (Math.hypot(point.x - tap.x, point.y - tap.y) > TAP_SLOP_PX) tap.moved = true;
      }
      if (vertexPress && Math.hypot(event.clientX - vertexPress.x, event.clientY - vertexPress.y) > TAP_SLOP_PX) {
        vertexPress.moved = true;
      }
      const index = dragging();
      const current = area();
      if (index === null) {
        // Say what a press would do: move a point, bend an edge, or nothing.
        if (!courseMap || !current) {
          courseMap?.setHoverCursor('');
        } else if (event.target instanceof Node && container.contains(event.target)) {
          const at = pointerOf(event);
          const screen = courseMap.toScreen(current);
          if (nearestVertex(screen, at) !== null) courseMap.setHoverCursor('grab');
          else if (nearestEdge(screen, at) !== null) courseMap.setHoverCursor('copy');
          else if (insidePolygon(screen, at)) courseMap.setHoverCursor('move');
          else courseMap.setHoverCursor('');
        } else {
          courseMap.setHoverCursor('');
        }
      }
      if (index === null || !courseMap) return;
      event.preventDefault();
      updateVertex(index, courseMap.fromScreen(pointerOf(event)));
    };

    const endDrag = () => {
      if (dragging() === null) return;
      dragPointer = null;
      setDragging(null);
      courseMap?.setPanEnabled(true);
      requestArea();
      requestNodes();
    };

    const onPointerUp = (event: PointerEvent) => {
      activePointers.delete(event.pointerId);
      const pending = tap;
      if (pending && event.pointerId === pending.pointerId) {
        tap = null;
        if (!pending.moved && !area() && courseMap) {
          const placed = initialTriangle(courseMap.fromScreen({ x: pending.x, y: pending.y }));
          remember();
          setArea(placed);
          setNodeCount(0);
          // One frame on: MapLibre stops any camera flight it finds while it is
          // still finishing the press that started one, so a flight begun in
          // this handler is cancelled on a touch screen.
          requestAnimationFrame(() => courseMap?.fitToArea(placed));
          requestArea();
          requestNodes();
          return;
        }
      }
      const pressed = vertexPress;
      vertexPress = null;
      // Releasing a second finger ends the pinch, not the edit: put the figure
      // back instead of committing whatever the first finger had done.
      if (dragging() !== null && event.pointerId !== dragPointer) {
        abortDrag();
        return;
      }
      endDrag();
      // The press never moved, so nothing was dragged: it was a click on the
      // handle, which asks before it removes.
      if (pressed && !pressed.moved) setPendingDelete(pressed.index);
    };

    const onPointerCancel = () => {
      activePointers.clear();
      tap = null;
      abortDrag();
    };

    // The map's own listeners call stopPropagation on the canvas, so the drag
    // is tracked on the window in the capture phase: a release always lands.
    // MapLibre prevents the context menu on its canvas; stopping the event here
    // keeps the browser's own menu available over the map.
    const allowContextMenu = (event: MouseEvent) => event.stopPropagation();
    container.addEventListener('contextmenu', allowContextMenu, { capture: true });
    container.addEventListener('pointerdown', onPointerDown, { capture: true });
    window.addEventListener('pointermove', onPointerMove, { capture: true });
    window.addEventListener('pointerup', onPointerUp, { capture: true });
    window.addEventListener('pointercancel', onPointerCancel, { capture: true });
    window.addEventListener('blur', onPointerCancel);

    // The answer to a click on a point stays up until the visitor goes elsewhere.
    const dismissDelete = (event: PointerEvent) => {
      if (event.target instanceof Element && event.target.closest('.confirm')) return;
      setPendingDelete(null);
    };
    window.addEventListener('pointerdown', dismissDelete, { capture: true });

    // The map's scale and credits are pinned under the toolbar, which is one row
    // on a wide screen, two on a phone and taller again while a search is open.
    // They take its measured height rather than a guess at it.
    const toolbar = document.querySelector('.map__toolbar');
    const measured = new ResizeObserver(() => {
      if (toolbar) {
        container.style.setProperty('--toolbar-h', `${Math.round(toolbar.getBoundingClientRect().height)}px`);
      }
    });
    if (toolbar) measured.observe(toolbar);

    onCleanup(() => {
      measured.disconnect();
      window.removeEventListener('pointerdown', dismissDelete, { capture: true });
      container.removeEventListener('contextmenu', allowContextMenu, { capture: true });
      container.removeEventListener('pointerdown', onPointerDown, { capture: true });
      window.removeEventListener('pointermove', onPointerMove, { capture: true });
      window.removeEventListener('pointerup', onPointerUp, { capture: true });
      window.removeEventListener('pointercancel', onPointerCancel, { capture: true });
      window.removeEventListener('blur', onPointerCancel);
      worker?.terminate();
    });
  });

  function startDrag(index: number, event: PointerEvent, snapshot = true): void {
    event.preventDefault();
    if (snapshot) remember();
    dragPointer = event.pointerId;
    setSelectedVertex(index);
    setDragging(index);
    courseMap?.setPanEnabled(false);
    vertexPress = { index, x: event.clientX, y: event.clientY, moved: false };
  }

  /** A pinch cut a vertex drag short: put the figure back, drop its snapshot. */
  function abortDrag(): void {
    if (dragging() === null) return;
    dragPointer = null;
    setDragging(null);
    vertexPress = null;
    courseMap?.setPanEnabled(true);
    const previous = undoStack.pop();
    setUndoDepth(undoStack.length);
    if (previous === undefined) return;
    setArea(previous);
    setSelectedVertex(null);
    requestArea();
    requestNodes();
  }

  let lastInteractiveNodes = 0;
  function updateVertex(index: number, to: LngLat): void {
    const current = area();
    if (!current) return;
    setArea(moveVertex(current, index, to));
    cancelAnimationFrame(areaFrame);
    areaFrame = requestAnimationFrame(() => {
      const next = area();
      if (next && ready()) worker?.post({ type: 'area', area: next });
    });
    const now = performance.now();
    if (now - lastInteractiveNodes > 140) {
      lastInteractiveNodes = now;
      requestNodes(true);
    }
  }

  function removeVertexAt(index: number): void {
    const current = area();
    if (!current) return;
    if (current.length <= MIN_VERTICES) {
      announce(`an area needs at least ${MIN_VERTICES} points`);
      return;
    }
    remember();
    stopSearch(true);
    setPendingDelete(null);
    setArea(removeVertex(current, index));
    setSelectedVertex(null);
    requestArea();
    requestNodes();
  }

  function clearArea(): void {
    remember();
    stopSearch(true);
    setPinnedRoute(null);
    setHoveredRoute(null);
    setPendingDelete(null);
    setArea(null);
    setSelectedVertex(null);
    setRoutes([]);
    setStats(null);
    setNodeCount(0);
    setNodes(null);
  }

  function locate(): void {
    if (!navigator.geolocation) {
      announce('this browser exposes no location');
      return;
    }
    setLocating('busy');
    navigator.geolocation.getCurrentPosition(
      (position) => {
        setLocating('shown');
        courseMap?.showUserLocation(
          { lat: position.coords.latitude, lng: position.coords.longitude },
          position.coords.accuracy,
        );
        courseMap?.map.flyTo({
          center: [position.coords.longitude, position.coords.latitude],
          zoom: Math.max(courseMap.map.getZoom(), 13),
        });
      },
      (error) => {
        setLocating('idle');
        announce(error.code === error.PERMISSION_DENIED ? 'location permission denied' : 'your location could not be read');
      },
      { enableHighAccuracy: true, timeout: 8000, maximumAge: 60_000 },
    );
  }

  function exportRoute(rank: number): void {
    const chosen = routes().find((route) => route.rank === rank);
    if (!chosen) return;
    downloadGpx([chosen], `zill-route-${rank}.gpx`, new Date());
  }

  /** A row's click chooses a climb, which means wanting to see it. */
  function focusRoute(rank: number): void {
    const chosen = routes().find((route) => route.rank === rank);
    if (chosen) courseMap?.focusRoute(chosen);
  }

  function goToPlace(place: Place): void {
    courseMap?.showPlace({ lng: place.lng, lat: place.lat }, place.zoom);
  }

  function startSearch(): void {
    if (load().phase === 'error') {
      worker?.post({ type: 'load' });
      return;
    }
    const current = area();
    if (!current || !ready()) return;
    setSearching(true);
    setPinnedRoute(null);
    setHoveredRoute(null);
    discardReports = false;
    cameraOwned = true;
    framedRun = false;
    worker?.post({
      type: 'search',
      request: {
        area: current,
        maxDistanceM: Math.round(distanceM()),
        maxElevationM: 0, // the dashboard only ever searches within a distance
        maxResults: MAX_RESULT_ROUTES,
        dedupPermille: DEDUP_PERMILLE,
      },
    });
  }

  /**
   * `discard` is for edits that invalidate the run: the worker reports one last
   * time when it stops, and those results belong to the old figure.
   */
  function stopSearch(discard = false): void {
    if (searching()) worker?.post({ type: 'stop' });
    setSearching(false);
    if (discard) {
      discardReports = true;
      setRoutes([]);
      setStats(null);
    }
  }

  function onVertexKey(event: KeyboardEvent, index: number): void {
    const current = area();
    if (!current) return;
    if (event.key === 'Delete' || event.key === 'Backspace') {
      event.preventDefault();
      removeVertexAt(index);
      return;
    }
    const step = degreesPerMeter(current, event.shiftKey ? 25 : 5);
    const point = current[index];
    let moved: LngLat | null = null;
    if (event.key === 'ArrowUp') moved = { lng: point.lng, lat: point.lat + step.lat };
    else if (event.key === 'ArrowDown') moved = { lng: point.lng, lat: point.lat - step.lat };
    else if (event.key === 'ArrowLeft') moved = { lng: point.lng - step.lng, lat: point.lat };
    else if (event.key === 'ArrowRight') moved = { lng: point.lng + step.lng, lat: point.lat };
    if (!moved) return;
    event.preventDefault();
    remember(true);
    setSelectedVertex(index);
    updateVertex(index, moved);
    requestArea();
    requestNodes();
  }

  // The drawn area drives both the map layers and the start-node query.
  createEffect(() => {
    const current = area();
    mapVersion();
    courseMap?.setArea(current, selectedVertex());
    if (!current) return;
    if (searching()) return;
    requestArea();
  });

  createEffect(() => {
    basemap();
    courseMap?.setBasemap(basemap());
  });

  // Dense node fields are thinned in screen space: one pinprick per ~4 px cell,
  // so a whole country's worth of nodes still reads as texture, never as blobs.
  createEffect(() => {
    const points = nodes();
    viewKey();
    const map = courseMap;
    const shown =
      points && map
        ? clusterByScreen(points, (lngLat) => map.map.project(lngLat), PINPRICK_CELL_PX, 24_000)
        : null;
    map?.setStarts(shown);
  });

  createEffect(() => {
    courseMap?.setRoutes(routes(), selectedRoute());
  });

  // The direction mark belongs to the route the visitor actually chose.
  createEffect(() => {
    const rank = pinnedRoute();
    const chosen = rank === null ? null : routes().find((route) => route.rank === rank) ?? null;
    courseMap?.showRouteStart(chosen);
  });

  let noticeTimer: number | undefined;
  function announce(message: string): void {
    setNotice(message);
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => setNotice(null), 4000);
  }

  const searchProgress = createMemo(() => {
    const current = stats();
    if (!current || current.total === 0) return 0;
    return current.scanned / current.total;
  });

  return (
    <>
      <Panel
        area={area()}
        figures={figures()}
        nodeCount={nodeCount()}
        load={load()}
        stats={stats()}
        routes={routes()}
        distanceM={distanceM()}
        notice={notice()}
        panelOpen={panelOpen()}
        onPanelChange={setPanelOpen}
        searching={searching()}
        searchProgress={searchProgress()}
        selectedRoute={selectedRoute()}
        pinnedRoute={pinnedRoute()}
        onDistance={setDistanceM}

        onSearch={startSearch}
        onStop={stopSearch}
        onSelectRoute={setHoveredRoute}
        onPinRoute={setPinnedRoute}
        onFocusRoute={focusRoute}
        onExport={exportRoute}
      />
      <div class="map">
        <div class="map__canvas" ref={mapContainer} />
        <div class="map__toolbar">
          <div class="toolbar__group" role="group" aria-label="ground">
            <button
              type="button"
              class="toolbar__button"
              aria-pressed={basemap() === 'shade'}
              onClick={() => setBasemap('shade')}
              title="the relief shading with the names over it"
            >
              Shade
            </button>
            <button
              type="button"
              class="toolbar__button"
              aria-pressed={basemap() === 'topo'}
              onClick={() => setBasemap('topo')}
            >
              Topo
            </button>
            <button
              type="button"
              class="toolbar__button"
              aria-pressed={basemap() === 'satellite'}
              onClick={() => setBasemap('satellite')}
            >
              Satellite
            </button>
          </div>
          <PlaceSearch onPick={goToPlace} />
          <button
            type="button"
            class="toolbar__button toolbar__button--icon"
            onClick={locate}
            disabled={locating() === 'busy'}
            title="show my location on the map"
            aria-label="show my location on the map"
          >
            <LocateIcon />
          </button>
          <button
            type="button"
            class="toolbar__button toolbar__button--icon"
            onClick={undo}
            disabled={undoDepth() === 0}
            title="undo the last change to the area (ctrl+z)"
            aria-label="undo the last change to the area"
          >
            <UndoIcon />
          </button>
          <button
            type="button"
            class="toolbar__button toolbar__button--icon"
            onClick={redo}
            disabled={redoDepth() === 0}
            title="redo the change that was undone (ctrl+shift+z)"
            aria-label="redo the change that was undone"
          >
            <RedoIcon />
          </button>
          <button
            type="button"
            class="toolbar__button"
            onClick={clearArea}
            disabled={!area()}
            title="remove the search area"
          >
            Clear area
          </button>
        </div>
        <Show when={area()}>
          <Index each={edgeLabels()}>
            {(label) => (
              <span class="edge-length" style={{ left: `${label().x}px`, top: `${label().y}px` }}>
                {label().text}
              </span>
            )}
          </Index>
          <div class="map__vertices" role="group" aria-label="search area points">
            <Index each={area() ?? []}>
              {(_, index) => (
              <button
                type="button"
                class="vertex-handle"
                style={{
                  left: `${vertexPoints()[index]?.x ?? 0}px`,
                  top: `${vertexPoints()[index]?.y ?? 0}px`,
                }}
                aria-label={`point ${index + 1} of ${area()?.length}. drag to move, arrow keys to nudge, shift-click or delete to remove. dragging anywhere on an edge adds a point.`}
                on:pointerdown={(event) => {
                  if (activePointers.size > 1) return;
                  if (event.shiftKey) {
                    event.preventDefault();
                    event.stopPropagation();
                    removeVertexAt(index);
                    return;
                  }
                  event.stopPropagation();
                  startDrag(index, event);
                }}
                on:pointerenter={() => HOVER_CAPABLE && setHoveredVertex(index)}
                on:pointerleave={() => setHoveredVertex((current) => (current === index ? null : current))}
                on:focus={() => setHoveredVertex(index)}
                on:blur={() => setHoveredVertex((current) => (current === index ? null : current))}
                on:keydown={(event) => onVertexKey(event, index)}
              >
                <span class="visually-hidden">Point {index + 1}</span>
              </button>
              )}
            </Index>
          </div>
          <Show when={hoveredVertex() !== null}>
            <div
              class="map__tooltip"
              style={{
                left: `${vertexPoints()[hoveredVertex() ?? 0]?.x ?? 0}px`,
                top: `${vertexPoints()[hoveredVertex() ?? 0]?.y ?? 0}px`,
              }}
            >
              drag to move · <b>shift-click</b> or Delete to remove · drag an edge to add a point
            </div>
          </Show>
          {/* A click on a point asks first: the map has no other way to take one
              back on a touch screen, where there is no Delete key. */}
          <Show when={pendingDelete() !== null}>
            <div
              class="confirm"
              role="dialog"
              aria-label={`delete point ${(pendingDelete() ?? 0) + 1}?`}
              style={{
                left: `${vertexPoints()[pendingDelete() ?? 0]?.x ?? 0}px`,
                top: `${vertexPoints()[pendingDelete() ?? 0]?.y ?? 0}px`,
              }}
            >
              <span class="confirm__ask">delete point {(pendingDelete() ?? 0) + 1}?</span>
              <button
                type="button"
                class="confirm__delete"
                // MapLibre takes focus for its canvas on the press that opened
                // this, so the keyboard lands here on the next turn instead.
                ref={(element) => setTimeout(() => element.focus({ preventScroll: true }), 0)}
                onClick={() => {
                  const index = pendingDelete();
                  setPendingDelete(null);
                  if (index !== null) removeVertexAt(index);
                }}
              >
                delete
              </button>
            </div>
          </Show>
        </Show>
      </div>
    </>
  );
}
