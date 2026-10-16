# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

SolidJS + TypeScript + Vite, MapLibre GL for the map. The search core is `find/` (Zig) compiled to
`wasm32-freestanding` and driven from a Web Worker; the graph asset is a static `.zl` file shipped
as `tar.gz` beside the app. No server-side compute.

## Users

Primary: the route planner — first the project author, then cyclists and hikers who want a climb
rather than a distance. They arrive knowing roughly where they want to ride or walk, do not know
which road, trail or forest track gains the most height, and are unwilling to click through a dozen
candidate routes one by one.

## Product Purpose

Turn a drawn area plus a target distance into the steepest routes that start inside it, entirely in
the visitor's browser. Success is: the visitor sees how expensive their search will be before
running it, starts a search that visibly progresses, and reads ranked climbs that are genuinely
different from each other rather than the same climb from twelve neighbouring junctions.

## Positioning

Two things a neighbouring product cannot truthfully copy: the search maximizes elevation gain under
a distance bound over a purpose-built routing graph, and the search runs client-side from a shipped
graph file — the area, the search and the results never leave the browser, and there is no query
budget to ration. The area is an editable concave polygon, not a radius circle, because the terrain
a climber wants is rarely round.

## Operating Context

- `find/` (`zill`) stays a first-class local CLI: same algorithms, multi-threaded, scriptable, GPX
  output. The dashboard is a second front end over the same graph library, not a replacement.
- The shipped `.zl` is pre-generated from OpenStreetMap plus the SwissTopo DHM25 elevation model by
  `convert/` (`zillconv`); visitors never build a graph.
- Graph variants exist per activity (walkable, cycleable, roadbike) with ways chunked to ~100 m so
  route geometry follows the real road rather than jumping between intersections.
- Areas are ephemeral: no accounts, no saved searches, no server round trips.

## Capabilities and Constraints

- Concave polygon area with vertex dragging, insertion by dragging an edge, vertex removal, and a
  keyboard path for all three; live count of graph start nodes inside the area. The first click
  places a ~5 km triangle, and the panel collapses to a one-line tab on small screens.
- One search in the dashboard: the strongest climb that starts inside the drawn area within the
  entered distance (metres, default 1'000). The CLI keeps both directions, including the elevation
  target; the dashboard deliberately exposes only the distance one.
- Progressive search: the client watches routes appear while the algorithm works through start
  nodes, with duplicated climbs suppressed and up to 60 distinct climbs kept. Steepness is carried by
  line weight and strength within the single course colour, and every route exports as GPX.
- The visitor's own position can be shown on the map, and the basemap switches between the swisstopo
  sheet and the aerial image.
- Every start node inside the area is drawn, however large the area, thinned by zoom so the field
  reads as texture rather than as blobs.
- Resource budget: the walkable graph is ~146 MB decompressed and must stay resident in the browser
  (~200 MB including the index) plus ~60 MB compressed transfer. Load progress and search
  availability must be honest at every stage.
- Key-free basemap only: © swisstopo WMTS raster. Attribution is mandatory.
- The `.zl` format is validated on load: a graph whose length does not match its header is rejected
  rather than silently mis-read.
- Undecided: how areas and searches might be shared by URL; whether multiple graph variants are
  ever ship-selectable.

## Brand Commitments

The name `zill` stays (hill finder, written in Zig). The declared mood is minimal, calm and
analytic: the map is the product and the interface must not compete with it. No gamification, no
neon, no score badges, no marketing copy.

## Evidence on Hand

- Graphs: `data/switzerland_walkable_100m.zl` and siblings; the raw inputs are
  `data/switzerland-260907.osm.pbf` and `data/switzerland_dhm25.tif`.
- Sample outputs: `data/route_*.gpx`, `data/wil/`, `data/wildhaus/`, `data/top/`.
- No testimonials, benchmarks, customer counts or pricing exist; none may be invented.

## Product Principles

1. Show the cost before the work: area size, start-node count and graph load state are visible
   before a search starts.
2. The map is the interface — every control earns its pixels or moves into the map.
3. Results must differ from each other; suppression of near-duplicates is part of correctness, not
   cosmetic filtering.
4. Long operations stay legible: download, decompress, index and search each report their own
   progress, and the reason a control is unavailable is always on screen.
5. One algorithm core: the CLI and the browser call the same Zig code, so a fix lands in both.

## Accessibility & Inclusion

Route grade is never encoded by colour alone (rank and numeric gain carry it). Area editing must be
operable by pointer on touch and by keyboard for vertex selection and deletion, and every icon-only
control carries an accessible name.
