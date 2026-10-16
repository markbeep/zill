---
name: Zill
description: Client-side hill finder for Switzerland — a course overprint on an official map sheet.
colors:
  overprint: "#8e5cc0"
  overprint-tint: "rgba(142, 92, 192, 0.12)"
  overprint-veil: "rgba(142, 92, 192, 0.32)"
  paper: "#fbfaf7"
  ink: "#14161a"
  ink-muted: "#5b6068"
  rule: "#c9c7c4"
  rule-soft: "#e4e2de"
  alert: "#a3362c"
typography:
  wordmark:
    fontFamily: "Archivo Narrow, Arial Narrow, system-ui, sans-serif"
    fontSize: "20px"
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: "0.02em"
  figure:
    fontFamily: "Archivo Narrow, Arial Narrow, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "normal"
  body:
    fontFamily: "Archivo Narrow, Arial Narrow, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
    letterSpacing: "normal"
  label:
    fontFamily: "Archivo Narrow, Arial Narrow, system-ui, sans-serif"
    fontSize: "10px"
    fontWeight: 400
    lineHeight: 1.2
    letterSpacing: "0.12em"
rounded:
  none: "0"
  mark: "50%"
spacing:
  xs: "5px"
  sm: "8px"
  md: "14px"
  lg: "16px"
  xl: "24px"
components:
  action-idle:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.none}"
    padding: "10px 12px"
  action-ready:
    backgroundColor: "{colors.overprint}"
    textColor: "{colors.paper}"
    rounded: "{rounded.none}"
    padding: "10px 12px"
  action-loading:
    backgroundColor: "{colors.overprint-tint}"
    textColor: "{colors.ink-muted}"
    rounded: "{rounded.none}"
    padding: "10px 12px"
  toolbar-button:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.none}"
    padding: "5px 8px"
  segment-selected:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    rounded: "{rounded.none}"
    padding: "7px 8px"
  rank-badge:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.overprint}"
    rounded: "{rounded.mark}"
    height: "18px"
    width: "18px"
  input:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.none}"
    height: "34px"
---

# Design System: Zill

## Overview

**Creative North Star: "The Course Overprint"**

Zill is an orienteering sheet that happens to compute: the ground is an official swisstopo map in its
own grey language, and the only thing this interface adds is the course — a purple figure you draw,
the purple lines the search finds, and the numbered badges that rank them. Everything else is
apparatus: a paper legend panel, hairline rules, tabular figures, and controls with no radius. The
map is never decorated and the panel is never coloured, because that split is what makes a route
instantly legible over terrain.

The system is deliberately calm — it is an instrument, not a game. There is no second accent, no
shadow, no card, no gradient, and no motion that is not carrying information: the search control's
fill *is* the progress, and the camera moves once to frame the course it just found. Numbers are the
loudest thing on the screen and are always right-aligned in tabular columns, so climbs can be
compared straight down the panel edge.

**Key Characteristics:**
- One overprint purple on a greyscale ground; terrain keeps its own colours.
- Flat by construction: separation is a one-device-pixel rule, never a shadow or a card.
- Every figure in a right-aligned tabular column; Swiss thousands separators.
- Zero radius on every control; circles exist only as course notation (vertices, edge handles, rank badges).
- State, cost and progress are always on screen: load stage, start-node count, scanned starts, suppressed duplicates.

## Colors

A single accent against paper, ink and two rules. The palette is closed: nothing new may be added
for a new feature.

### Primary
- **Overprint Purple** (#8e5cc0): the course and nothing else — the drawn area's outline and tint,
  route lines, rank badges, the gradient bar, the live start-node count, and the search control's
  ready state. Its rarity is what makes a 2.4 px route line readable over a busy raster.

### Neutral
- **Sheet Paper** (#fbfaf7): the legend panel's ground and the fill of rank badges and vertex marks.
- **Ink** (#14161a): type, hairline boxes, filled segment buttons on their active side.
- **Ink Muted** (#5b6068): field labels, secondary figures, the legend footnote, disabled text. It
  measures 6.0:1 on paper and 5.2:1 over the load-fill tint, so no text tone sits below the floor;
  there is no lighter grey in the system.
- **Rule** (#c9c7c4) and **Rule Soft** (#e4e2de): every divider and the empty track of the gradient bar.
- **Alert** (#a3362c): failure text only (a graph that could not be prepared). Never decorative.

### Named Rules
**The One Overprint Rule.** Exactly one colour carries data. If it is not the course, a live figure,
or a progress fill, it is ink. Terrain tints belong to the map's own layers, never to the panel.

**The Ground Rule.** The basemap is swisstopo's own product over its relief shading — the greyscale
sheet by default, the aerial image on request — credited © swisstopo. It is never restyled, tinted
purple, or replaced with a darker "dashboard" basemap.

**The Sheet-Ends-At-Paper Rule.** Where the swisstopo tiles stop, the map becomes the panel's own
paper: the camera is bounded to the data's extent and its zoom floor is the level at which that
extent still fills the viewport, so there is never a white seam or a ragged tile row in view.

## Typography

**Body Font:** Archivo Narrow (with Arial Narrow, system-ui fallbacks), self-hosted as one variable
woff2.

**Character:** a narrow printed grotesque — the voice of a map margin. It is used for everything,
with hierarchy carried by size, weight, letterspacing and case rather than by a second family.
Figures are set with `font-variant-numeric: tabular-nums` on the body so columns align.

### Hierarchy
- **Wordmark** (700, 20px, 0.02em, uppercase): the product name and its one-line purpose.
- **Figure** (700, 15–20px): elevation gain, the distance input, and the area's headline numbers.
- **Body** (400, 13px, 1.35): route rows, prose in the legend, status text.
- **Label** (400, 10–11px, 0.12em, uppercase): every field name ("VERTICES", "START NODES", "COURSE"),
  legend captions, toolbar buttons.

### Named Rules
**The Column Rule.** Any figure a visitor might compare is right-aligned in a column with tabular
numerals; no measurement is ever set inside a sentence. Thousands separators are Swiss (`1'042`).

**The One Family Rule.** One typeface, self-hosted, no display face for the wordmark, no second
family for figures. Hierarchy comes from the ramp above.

## Layout

Two layers: a paper sheet of 360 px over a map that fills the whole frame. The map is the ground and
never changes size or position, so the sheet can open and close without a single map pixel moving;
what the sheet covers, it covers. The camera is clamped to the country's extent plus about 40 km of
headroom on every side, so the country reads with ground around it instead of pinned to its own
border; that rectangle sits far inside the sheets, whose map carries on for over a hundred kilometres.
The floor is the widest view that keeps it in frame, so the frame is always over tiles, never over the
edge where they stop, and a drag pulls against the rectangle rather than leaving it. The map's own chrome (toolbar, scale, attribution) starts
clear of the sheet and stays there. The panel is a single scrolling column of hairline-separated
blocks in reading order - area figures, search controls, the ranked routes, the legend - and never
grows cards or tabs. Below 900 px the sheet lies along the bottom at up to 62 dvh over the same
untouched map; the block order is identical in both.

Space is a four-step rhythm (5/8/14/16 px inside blocks, 16 px block padding) with 14 px between
figure rows. Blocks are separated by a full-width 1 px `{colors.rule}` border, and every row inside
the figure table carries the same rule across its top edge.

## Elevation & Depth

There are no shadows anywhere and no translucency in the panel: the interface is flat paper on a
flat map. Depth is expressed by hairlines, by the purple tint over terrain, and by z-order on the
map (terrain → area line and tint → start-node pinpricks → route lines → edge handles → vertices →
rank badges). The only layered surfaces are the two raster basemap layers, where relief shading sits
at 50 % under the sheet at 88 %.

### Named Rules
**The Flat-By-Default Rule.** A new surface is flat at rest and flat under interaction. Nothing gains
a shadow, a blur or a raised state; state is shown by fill, rule weight, or the overprint.

## Shapes

Radius 0 on every control: inputs, buttons, segmented toggles, the action, toolbar buttons, progress
rules and the bar inside each route row are rectangles. Circles are reserved for the course's own
notation, and only there: area vertices (a paper disc with a 2.25 px overprint ring, 3 px when
selected), hollow mid-edge handles (4 px, 1.5 px ring), and the 20 px rank badge worn at a climb's
summit. No border below 1 px and no dashes anywhere.

The two lines that carry the course — the drawn area's edge (solid 2 px) and each route (2.6 px) —
sit on a paper casing (5 px and 5.4 px at 0.66–0.7 opacity). That is map-making's own device for
keeping a line readable over contour-dense terrain, and it costs no second colour.

## Components

### The Search Control (signature)
The primary action is also the instrument. It is a full-width hairline rectangle in uppercase label
type whose **fill is the state**: nothing when idle, the overprint at the graph's overall load
progress while the map prepares (label "preparing map", percentage at the right edge), solid
overprint when a search can run (label "search", the current target distance at the right — metres,
default `1'000 m`), and the overprint at the search's own progress while it runs (label "stop
search", scanned/total below). It is disabled
exactly while the graph is unavailable, and a 2 px rule under it repeats the same progress.

### Layout & Navigation
- **States:** an unavailable control shows no fill at all — the fill means work is happening, so a
  disabled action is a hairline box with muted text, never a purple one.
- **Map controls:** MapLibre's navigation and scale controls, kept in their stock rendering, plus
  basemap, locate, undo and redo controls in paper boxes with hairline borders and 11 px uppercase
  labels (icons carry a lowercase `title` and `aria-label`).
- **Vertex handles:** 28 px invisible buttons positioned over the drawn vertices - the pointer target
  and the keyboard path (Tab to reach, arrow keys to nudge by 5 m, shift+arrows 25 m, Delete or
  shift-click removes; a new point comes from dragging an edge). A tooltip appears above the focused
  or hovered vertex: drag to move · shift-click or delete to remove · drag an edge to add a point.
- **Pointer cursors:** `grab` over a vertex, `copy` over an edge (a press and drag bends the figure
  there), `move` inside the area, `pointer` over a route line, and the map's own cursor elsewhere.
- **Refused edits speak:** removing a point from a triangle is refused with the reason on screen
  ("an area needs at least 3 points") rather than doing nothing silently.

### Browser and map chrome
- **MapLibre controls:** rebuilt in the world's terms — radius 0, hairline border, paper ground, no
  drop ring, the overprint focus ring instead of the stock blue glow; the scale and attribution boxes
  take the same paper, hairline and 10 px type.
- **Browser surfaces:** `::selection` uses the overprint veil, the caret is overprint, and the panel's
  scrollbar is thin, rule-coloured and square-cornered. No default chrome survives.

### Fields & Segments
- **Style:** a hairline box with a transparent input, the unit in a bordered cell at the right
  (`KM`, `M UP`); the segmented mode toggle beside it is the same box with two cells, the active one
  filled ink and set in paper.
- **Focus:** the overprint ring at 2 px with a 2 px offset, never a browser-default outline.

### Basemap and location controls
- **Segments:** `TOPO` / `SATELLITE` in one hairline group, the pressed one filled ink — the same
  control language as the panel's fields, not MapLibre's stock chrome.
- **Undo and redo:** icon controls (a returning arrow each way, 14 px stroke at 1.6, `currentColor`),
  each disabled while its stack is empty and each staying visible even when the figure has been
  cleared — a clear is itself a step. Ctrl/⌘+Z undoes, Ctrl+Shift+Z or Ctrl+Y redoes; both stacks hold
  20 states, one per change (a burst of arrow-key nudges counts as one, and "no figure" is a state, so
  a placement can be taken back to nothing). Either direction stops any running search and discards
  its results: climbs computed from a figure that no longer exists never appear.
- **Chrome owns its clicks:** the attribution toggle, the zoom buttons and the toolbar never place an
  area — only the sheet itself answers a click. The sheet still answers a right-click with the
  browser's own menu: the panel container stops the event before MapLibre's canvas can suppress it.
- **Locate:** one icon control (a crosshair with a filled centre), disabled while the browser is
  asking. The visitor's position is a paper disc with a 2.5 px overprint ring over a 12 % overprint
  accuracy halo; it is never animated and never follows without being asked again.
- **Icon controls:** icon-only buttons carry an `aria-label` and a `title`, and keep the toolbar's
  hairline box at a 26 px minimum so the row stays a ruled set of cells.

### Route Rows
- **Shape:** flat rows separated by hairlines, each a full-width button with its own `GPX` control
  beside it. Hovering previews — a row hover draws its route as a 9 px overprint line over the ramped
  one, a route hover selects its row — and clicking **pins**: clicking a route line scrolls its row
  into view and keeps it selected after the pointer leaves, while clicking the empty sheet or the row
  again releases it.
- **Export:** every row downloads its own GPX 1.1 track, matching the CLI's `writeGpx` shape.
- **Content:** rank in a ringed badge, the start's coordinates in tabular figures under a `START`
  label, the gain in 15 px bold with an `HM` unit, a 4 px gradient bar whose span is derived from the
  result set (`max(10, ceil(strongest average / 5) * 5)` %), and a figure line
  `distance · Ø gradient · start→summit elevation`.
- **Gradient bar:** the span is announced in the legend footnote ("… span 0–50 %, the strongest climb
  found so far"); a bar pinned at 100 % for every row means the span is wrong, not the data.
- **Collision:** badges keep 20 px of clearance, nudged along their own route's tail (sideways or
  back along the final segment) with a roomiest-slot fallback, and re-laid on every camera move; the
  legend says "set beside the summit", not "at" it. Only the ten strongest climbs wear one.
- **Steepness ramp:** the one overprint carries a second signal without a second colour — line width
  and opacity follow the route's average gradient (2.6 px / 0.72 at flat, 7.4 px / 1.0 at 50 % and
  above), on a paper casing at 1.75× width. A search keeps up to 60 climbs, so a whole area fills
  with route lines and the steep ground reads first. The floor is heavy on purpose: the course is
  the point of the surface, so no route is drawn faint.
- **Course ground:** inside the drawn area the sheet is washed towards paper (46 % paper veil plus a
  6 % overprint tint), so the terrain still reads and the routes sit on a quieter ground.
- **Start-node field:** every start node is drawn, however large the area — thinned twice (worker:
  one node per cell of the area's own grid; map: one per 4 px screen cell) down to a dot 1–2.1 px
  wide. The field follows the figure while it is dragged (one page per update, the whole field on
  release), and is texture for "how much is here", never a blob.

### Figure Table
- **Shape:** two columns (label | value) with a hairline above every row; the live start-node count is
  the only value set in overprint bold, because it is the one number that changes as you drag.

## Do's and Don'ts

### Do:
- **Do** keep the overprint for course data, live figures and progress fills only.
- **Do** set every comparable figure right-aligned with tabular numerals and Swiss separators.
- **Do** separate with 1 px `{colors.rule}` rules; keep the panel at 360 px on desktop.
- **Do** state cost and state before work: start-node count before a search, load stage and bytes
  before the control unlocks, scanned starts while it runs.
- **Do** set the target distance in metres (default 1'000 m, step 100) and leave route distances in
  kilometres, where the number is a route length rather than a search budget.
- **Do** write every description, label, hint, notice and tooltip in lowercase - the instrument talks
  the way it reads, not the way a manual is printed - and **never** use an em dash: a full stop starts
  the next thought.
- **Do** start the map with a ~5 km triangle, so the first search has something to work with.
- **Do** answer every search. A small or flat area has no climb to find, so it ranks the strongest
  lines its distance allows, however little they rise, and shows their real gains rather than an empty
  list or an apology.
- **Do** keep the map's greyscale sheet and credited attribution untouched beneath the course, and
  credit everything on the frame: the swisstopo product in use, the walkable graph's OpenStreetMap
  data, and MapLibre as the renderer.
- **Do** return every camera flight, fill transition and the panel's collapse to 0 ms under
  `prefers-reduced-motion`.
- **Do** keep the node field and the route ramp data-driven: the field thins with the camera, the
  ramp follows gradient. Neither may become decoration.

### Don't:
- **Don't** add a second accent colour, a gradient, a glow or a coloured map tint.
- **Don't** use cards, shadows, blur, or any radius other than 0 (circles are course notation only).
- **Don't** colour the panel's ground or set measurements inside sentences.
- **Don't** use the overprint decoratively — a purple element that carries no data is a bug.
- **Don't** hide the reason a control is unavailable, or let a search appear to run with no start
  nodes inside the area.
