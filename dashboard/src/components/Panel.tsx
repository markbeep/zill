import { createSignal, For, Show } from 'solid-js';
import { GRADE_DEPTH } from '../map';
import type { LoadState, Route, SearchStats } from '../wasm';
import type { LngLat } from '../area';

const DEPTH_GRADIENT = `linear-gradient(90deg, ${GRADE_DEPTH.map(
  ([grade, color]) =>
    `${color} ${(grade / GRADE_DEPTH[GRADE_DEPTH.length - 1][0]) * 100}%`,
).join(', ')})`;

type PanelProps = {
  area: LngLat[] | null;
  figures: { vertices: number; hectares: number; perimeterKm: number } | null;
  nodeCount: number;
  load: LoadState;
  stats: SearchStats | null;
  /** Wall-clock time the last finished search took, in milliseconds. */
  finishedMs: number;
  routes: Route[];
  distanceM: number;
  searching: boolean;
  searchProgress: number;
  selectedRoute: number | null;
  pinnedRoute: number | null;
  notice: string | null;
  panelOpen: boolean;
  onPanelChange: (open: boolean) => void;
  onDistance: (meters: number) => void;
  onSearch: () => void;
  onStop: () => void;
  /** Hover preview; clears when the pointer leaves. Fine pointers only. */
  onSelectRoute: (rank: number | null) => void;
  /** Click keeps the selection; null clears it. */
  onPinRoute: (rank: number | null) => void;
  /** Clicking a row also frames that climb. */
  onFocusRoute: (rank: number) => void;
  onExport: (rank: number) => void;
};

/** Touch fires mouseenter and pointerenter around a tap, which reads as a
 *  preview nobody asked for and a selection that drops itself. Hover, and the
 *  hints that hang off it, are a pointer's game. */
export const HOVER_CAPABLE =
  typeof matchMedia === 'function' &&
  matchMedia('(hover: hover) and (pointer: fine)').matches;

/** The sheet's height on small screens: the visitor sets it. Only a pull that
 *  ends near the bottom means "put it away", so pulling the sheet down a little
 *  parks it small instead of taking it off the map. */
const SHEET_KEY = 'zill:sheet';
const SHEET_DEFAULT = 52;
/** Below this, a released pull was aimed at the bottom of the screen. */
const SHEET_SNAP = 13;
const SHEET_MAX = 82;
/** The folded sheet's own height: no pull can take it below its head. */
const SHEET_TAB = 44;
/** A press that never moves is a tap on the head, which folds the sheet. */
const SHEET_SLOP_PX = 6;

function storedSheet(): number {
  try {
    const stored = Number(localStorage.getItem(SHEET_KEY));
    if (stored >= SHEET_SNAP && stored <= SHEET_MAX) return stored;
  } catch {
    // A browser that refuses storage still gets a sheet.
  }
  return SHEET_DEFAULT;
}

export const swiss = (value: number, digits: number) =>
  value.toLocaleString('de-CH', {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });

function megabytes(bytes: number): string {
  return swiss(bytes / (1024 * 1024), 1);
}

function routeFigures(route: Route, gradientSpan: number) {
  const kilometers = route.distance / 1000;
  const average =
    route.distance > 0 ? (route.elevation / route.distance) * 100 : 0;
  const start = route.points.length >= 3 ? route.points[2] : 0;
  const summit =
    route.points.length >= 3 ? route.points[route.points.length - 1] : 0;
  return {
    kilometers: swiss(kilometers, 1),
    average: swiss(average, 1),
    start: swiss(start, 0),
    summit: swiss(summit, 0),
    gradient: Math.min(average / gradientSpan, 1) * 100,
  };
}

function coordinate(route: Route): string {
  const lat = route.points.length >= 3 ? route.points[0] : 0;
  const lng = route.points.length >= 3 ? route.points[1] : 0;
  return `${swiss(lat, 4)} / ${swiss(lng, 4)}`;
}

export function Panel(props: PanelProps) {
  const [sheet, setSheet] = createSignal(storedSheet());
  const [shifting, setShifting] = createSignal(false);
  let panel: HTMLElement | undefined;
  let gesture: {
    id: number;
    from: number;
    height: number;
    moved: boolean;
    onControl: boolean;
  } | null = null;

  /** The sheet is a bottom sheet on small screens only; elsewhere the head is
   *  just a head, and there is nothing to pull. */
  const smallScreen = () =>
    typeof matchMedia === 'function' &&
    matchMedia('(max-width: 900px)').matches;

  const toDvh = (pixels: number) => (pixels / window.innerHeight) * 100;

  function grabSheet(event: PointerEvent): void {
    if (event.button !== 0 || !smallScreen()) return;
    const box = panel?.getBoundingClientRect();
    if (!box) return;
    gesture = {
      id: event.pointerId,
      from: event.clientY,
      height: box.height,
      moved: false,
      // A press on a control belongs to that control: the button keeps its click.
      onControl:
        event.target instanceof Element &&
        event.target.closest('button, a, input') !== null,
    };
  }

  function dragSheet(event: PointerEvent): void {
    const started = gesture;
    if (!started || event.pointerId !== started.id) return;
    if (
      !started.moved &&
      Math.abs(started.from - event.clientY) < SHEET_SLOP_PX
    )
      return;
    if (!started.moved) {
      started.moved = true;
      // Capture only once this is a drag: capturing on the press would take the
      // head button's own click away from it.
      event.currentTarget instanceof Element &&
        event.currentTarget.setPointerCapture(event.pointerId);
      setShifting(true);
      // The pull takes over from the tab: the sheet follows the finger.
      props.onPanelChange(true);
    }
    setSheet(
      Math.min(
        SHEET_MAX,
        Math.max(
          toDvh(SHEET_TAB),
          toDvh(started.height + started.from - event.clientY),
        ),
      ),
    );
  }

  function releaseSheet(event: PointerEvent): void {
    const started = gesture;
    if (!started || event.pointerId !== started.id) return;
    gesture = null;
    if (!started.moved) {
      // A tap on the head folds the sheet, the way a bottom sheet's bar does. The
      // fold waits for the next frame: the browser still has a click to deliver
      // from this tap, and moving the layout first would hand that click to
      // whatever moved in underneath (the map, or a route row).
      if (!started.onControl)
        requestAnimationFrame(() => props.onPanelChange(!props.panelOpen));
      return;
    }
    setShifting(false);
    if (sheet() < SHEET_SNAP) {
      // The pull finished at the bottom of the screen: that means put it away.
      setSheet(storedSheet());
      props.onPanelChange(false);
      return;
    }
    // Anywhere above that is a height the visitor chose, and it is kept exactly
    // as it was left, however small.
    try {
      localStorage.setItem(SHEET_KEY, String(Math.round(sheet())));
    } catch {
      // A browser that refuses storage still gets the height for this visit.
    }
    props.onPanelChange(true);
  }

  function abortSheet(): void {
    if (!gesture) return;
    gesture = null;
    setShifting(false);
  }

  /** The bar's span comes from the result set, so it always carries data. */
  const gradientSpan = () => {
    const strongest = props.routes.reduce((max, route) => {
      const average =
        route.distance > 0 ? (route.elevation / route.distance) * 100 : 0;
      return Math.max(max, average);
    }, 0);
    return Math.max(10, Math.ceil(strongest / 5) * 5);
  };

  const actionState = () => {
    if (props.load.phase === 'error') return 'error';
    if (props.searching) return 'running';
    if (props.load.phase !== 'ready') return 'loading';
    return 'ready';
  };

  const actionLabel = () => {
    if (props.load.phase === 'error') return 'retry';
    if (props.searching) return 'stop search';
    if (props.load.phase !== 'ready') return 'preparing map';
    return 'search';
  };

  const actionFigure = () => {
    if (props.searching) return `${Math.round(props.searchProgress * 100)} %`;
    if (props.load.phase !== 'ready' && props.load.phase !== 'error')
      return `${Math.round(props.load.progress * 100)} %`;
    if (props.area) return `${swiss(props.distanceM, 0)} m`;
    return '';
  };

  const fillWidth = () => {
    if (props.searching) return `${props.searchProgress * 100}%`;
    if (props.load.phase === 'ready') return '100%';
    if (props.load.phase === 'error') return '0%';
    return `${props.load.progress * 100}%`;
  };

  const statusText = () => {
    switch (props.load.phase) {
      case 'download':
        return 'downloading the walkable graph of switzerland';
      case 'decompress':
        return 'unpacking the graph into the browser';
      case 'index':
        return 'indexing 4 million nodes';
      case 'ready':
        return props.searching
          ? 'working through the start nodes'
          : `graph ready · ${swiss(props.load.nodes / 1e6, 1)}M nodes`;
      case 'error':
        return props.load.detail ?? 'the graph could not be prepared';
      default:
        return 'waiting for the map to settle';
    }
  };

  const statusFigure = () => {
    if (props.load.phase === 'download' && props.load.total > 0) {
      return `${megabytes(props.load.received)} / ${megabytes(props.load.total)} MB`;
    }
    if (props.load.phase === 'decompress' && props.load.graphBytes > 0) {
      return `${megabytes(props.load.inflated)} / ${megabytes(props.load.graphBytes)} MB`;
    }
    if (props.searching && props.stats) {
      return `${swiss(props.stats.scanned, 0)} / ${swiss(props.stats.total, 0)} starts`;
    }
    if (props.load.phase === 'ready' && props.stats && !props.searching) {
      if (!props.stats.finished) return '';
      const ms = props.finishedMs;
      if (!Number.isFinite(ms)) return 'search finished';
      // Below 5 ms the seconds reading rounds to 0.00: the milliseconds say more.
      const time = ms < 5 ? `${swiss(ms, 0)} ms` : `${swiss(ms / 1000, 2)}s`;
      return `search finished in ${time}`;
    }
    return '';
  };

  return (
    <aside
      class="panel"
      classList={{
        'panel--closed': !props.panelOpen,
        'is-dragging': shifting(),
      }}
      style={{ '--sheet-h': `${sheet()}dvh` }}
      ref={panel}
    >
      <header
        class="panel__block panel__grab"
        on:pointerdown={grabSheet}
        on:pointermove={dragSheet}
        on:pointerup={releaseSheet}
        on:pointercancel={abortSheet}
      >
        <div class="panel__head">
          <div class="wordmark">
            zill<span>hill finder</span>
          </div>
          <span class="panel__tab-figures">
            {props.area
              ? `${swiss(props.nodeCount, 0)} starts · ${props.routes.length} kept`
              : 'no area yet'}
          </span>
          <button
            type="button"
            class="toolbar__button"
            aria-expanded={props.panelOpen}
            onClick={() => props.onPanelChange(!props.panelOpen)}
          >
            {props.panelOpen ? 'hide' : 'show'}
          </button>
        </div>
      </header>
      <Show when={props.panelOpen}>
        <div class="panel__body">
          <section class="panel__block">
            <p class="purpose">
              draw the ground you want to climb from. zill searches the routes
              that start inside it and keeps the steepest, distinct ones.
            </p>
          </section>

          <section class="panel__block" aria-labelledby="area-heading">
            <div class="label" id="area-heading">
              search area
            </div>
            <Show
              when={props.figures}
              fallback={
                <p class="routes__empty">
                  no area yet. click anywhere in switzerland to place a
                  triangle.
                </p>
              }
            >
              {(figures) => (
                <dl class="figures">
                  <dt>vertices</dt>
                  <dd>{figures().vertices}</dd>
                  <dt>area</dt>
                  <dd>{swiss(figures().hectares, 0)} ha</dd>
                  <dt>perimeter</dt>
                  <dd>{swiss(figures().perimeterKm, 1)} km</dd>
                  <dt>start nodes</dt>
                  <dd class="is-live">
                    {props.load.phase === 'ready'
                      ? swiss(props.nodeCount, 0)
                      : '–'}
                  </dd>
                </dl>
              )}
            </Show>
          </section>

          <section
            class="panel__block controls"
            aria-labelledby="search-heading"
          >
            <div class="label" id="search-heading">
              search
            </div>
            <label class="visually-hidden" for="distance">
              target distance in metres
            </label>
            <div class="field">
              <input
                id="distance"
                type="number"
                min="100"
                max="60000"
                step="100"
                value={props.distanceM}
                onInput={(event) =>
                  props.onDistance(Number(event.currentTarget.value))
                }
              />
              <span class="field__unit">m</span>
            </div>

            <button
              type="button"
              class="action"
              data-state={actionState()}
              disabled={
                props.load.phase === 'idle' ||
                (props.load.phase !== 'ready' &&
                  props.load.phase !== 'error' &&
                  !props.searching) ||
                (props.load.phase === 'ready' &&
                  (!props.area || (props.nodeCount === 0 && !props.searching)))
              }
              onClick={() =>
                props.searching ? props.onStop() : props.onSearch()
              }
            >
              <span class="action__fill" style={{ width: fillWidth() }} />
              <span class="action__inner">
                <span>{actionLabel()}</span>
                <span>{actionFigure()}</span>
              </span>
            </button>

            <div
              class="status"
              classList={{ 'status--error': props.load.phase === 'error' }}
            >
              <span>{statusText()}</span>
              <span>{statusFigure()}</span>
            </div>
            <Show
              when={
                props.load.phase === 'ready' &&
                props.area &&
                props.nodeCount === 0
              }
            >
              <p class="status">
                <span>
                  no walkable route starts inside this area. move it or pull an
                  edge out
                </span>
              </p>
            </Show>
            <Show when={props.notice}>
              <p class="status status--notice">
                <span>{props.notice}</span>
              </p>
            </Show>
            <Show when={props.load.phase !== 'ready'}>
              <div class="rule-progress">
                <i style={{ width: `${props.load.progress * 100}%` }} />
              </div>
            </Show>
          </section>

          <section class="panel__block" aria-labelledby="route-heading">
            <div class="label" id="route-heading">
              routes
              {props.routes.length ? ` · ${props.routes.length} kept` : ''}
            </div>
            <Show
              when={props.routes.length > 0}
              fallback={
                <p class="routes__empty">
                  {props.searching
                    ? 'searching. climbs appear here as they are found.'
                    : 'no routes yet. draw an area and start a search.'}
                </p>
              }
            >
              <ol class="routes">
                <For each={props.routes}>
                  {(route) => {
                    const figures = routeFigures(route, gradientSpan());
                    return (
                      <li class="route-row">
                        <button
                          type="button"
                          class="route"
                          data-rank={route.rank}
                          classList={{
                            'is-selected': props.selectedRoute === route.rank,
                          }}
                          aria-pressed={props.selectedRoute === route.rank}
                          onClick={() => {
                            const next =
                              props.pinnedRoute === route.rank
                                ? null
                                : route.rank;
                            props.onPinRoute(next);
                            // Choosing a climb means wanting to see it.
                            if (next !== null) props.onFocusRoute(route.rank);
                          }}
                          onMouseEnter={() =>
                            HOVER_CAPABLE && props.onSelectRoute(route.rank)
                          }
                          onMouseLeave={() =>
                            HOVER_CAPABLE && props.onSelectRoute(null)
                          }
                          onFocus={() =>
                            HOVER_CAPABLE && props.onSelectRoute(route.rank)
                          }
                          onBlur={() =>
                            HOVER_CAPABLE && props.onSelectRoute(null)
                          }
                        >
                          <span class="route__rank">{route.rank}</span>
                          <span class="route__body">
                            <span class="route__head">
                              <span class="route__name">
                                <span class="label">start</span>{' '}
                                {coordinate(route)}
                              </span>
                              <span class="route__gain">
                                {swiss(route.elevation, 0)} <small>HM</small>
                              </span>
                            </span>
                            <span class="route__foot">
                              <span class="route__bar">
                                <i style={{ width: `${figures.gradient}%` }} />
                              </span>
                              <span class="route__figures">
                                {figures.kilometers} km · Ø {figures.average} %
                                · {figures.start}→{figures.summit} m
                              </span>
                            </span>
                          </span>
                        </button>
                        <button
                          type="button"
                          class="route__gpx"
                          onClick={() => props.onExport(route.rank)}
                          title={`download route ${route.rank} as gpx`}
                          aria-label={`download route ${route.rank} as gpx`}
                        >
                          GPX
                        </button>
                      </li>
                    );
                  }}
                </For>
              </ol>
            </Show>
            <Show when={props.stats && props.stats.suppressed > 0}>
              <div class="status">
                <span>near-duplicates suppressed</span>
                <span>{swiss(props.stats!.suppressed, 0)}</span>
              </div>
            </Show>
          </section>

          <section class="panel__block">
            <details class="fold">
              <summary class="label">legend</summary>
              <ul class="legend">
                <li>
                  <span class="legend__mark">
                    <span
                      class="legend__line"
                      style={{ background: DEPTH_GRADIENT }}
                    />
                  </span>
                  <span>
                    route found by the search. one weight, one hue: the line
                    darkens as the ground steepens, stretch by stretch
                  </span>
                </li>
                <li>
                  <span class="legend__mark">
                    <span class="legend__badge">1</span>
                  </span>
                  <span>
                    rank of the ten strongest climbs, set beside each summit
                  </span>
                </li>
                <li>
                  <span class="legend__mark">
                    <span class="legend__start" />
                  </span>
                  <span>
                    where the chosen climb sets off. the mark turns to face the
                    way it goes along the first metres
                  </span>
                </li>
                <li>
                  <span class="legend__mark">
                    <span class="legend__pins" />
                  </span>
                  <span>
                    start nodes inside the area, thinned by zoom. the cost of
                    the search
                  </span>
                </li>
                <li>
                  <span class="legend__mark">
                    <span class="legend__vertex" />
                  </span>
                  <span>
                    area point · drag it; drag anywhere on an edge to bend the
                    area
                  </span>
                </li>
              </ul>
              <p class="legend__foot">
                elevation gain is counted from each route's own start, along the
                walkable network (~100 m resolution). gradient bars span 0–
                {gradientSpan()} %, the strongest climb found so far. every
                route downloads as gpx. baselayer © swisstopo. source on{' '}
                <a href="https://github.com/markbeep/zill">github</a>.
              </p>
            </details>
          </section>
        </div>
      </Show>
    </aside>
  );
}
