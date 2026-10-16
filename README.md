# Zill

Generates graphs from OpenStreetMap data optimized for elevation-based routing.

## Structure

Three subprojects in one repo:

- `convert/` (`zillconv`) - Converts OSM data into a `.zl` file. _Requires PROJ and expat as a system dependency._
- `find/` (`zill`) - Loads the `.zl` file and runs graph algorithms on it. _Has no dependencies._
- `dashboard/` - Web UI for drawing inclusion areas and showing steep routes on an interactive map.

Each Zig subproject is a standalone project with its own `build.zig` and `build.zig.zon`. `convert` uses the graph library from `find` through a Zig path dependency (`convert/build.zig.zon`). `data/` and `dist/` are shared at the repo root.

`.zl` is a custom binary format to store the graph data in a compact way. It does not follow the OSM data model of nodes and ways directly; only nodes are stored that are either part of an intersection or mark the beginning or end of a way. Intermediate nodes that are only part of a single way are not stored. The file is split up into three parts (view `find/src/graph/shared.zig` for the exact layout):

- **Header:** Contains the Zill version the file was generated with, as well as the number of nodes and edges.
- **Nodes:** Each node store the OSM node ID, latitude, longitude, and elevation.
- **Edges:** Each edge `(u,v)` stores the _indices_ of nodes `u` and `v` (not the OSM ID directly). It additionally stores the total elevation gain, loss, and distance from `u` to `v`. The elevation and distances are accumulated to include intermediate nodes along the original OSM ways, allowing for accurate route elevation calculations, but result in incorrect map routes when converting the nodes of a network path into a GPX file.

> [!NOTE]
> [Releases page](https://github.com/markbeep/zill/releases) includes pre-generated `.zl` files.

## Building

Run everything from the repo root through the [`justfile`](justfile), so the `data/` paths in the defaults resolve:

```sh
just          # build both Zig subprojects
just test     # run both test suites
just generate # convert OSM data into a .zl file
just dist     # cross-compile release binaries into dist/
```

The recipes are thin wrappers around `zig build --build-file <subproject>/build.zig`. They must run from the repo root: the executables and tests resolve `data/` relative to the working directory.

## Graph Algorithms

There are two variants. You can either find:

- the maximum elevation under a given distance `--max-distance`
- the minimum distance required to reach a point `--max-elevation` higher than the start (can be very slow and find extremely long distances if there are no close-by climbs)

```
Usage: zill [options]

Options:
  -i, --input-path      Path to the input graph file. Default: data/graph.zl
  -d, --max-distance    Maximum total distance (in m) path to compute. Default: null
  -e, --max-elevation   Maximum total elevation path (in m) to compute. Default: null
  -r, --max-radius      Maximum radius (in m) to consider for starting nodes. Default: 10_000
      --lat             Latitude of the starting point. Default: 47.38300076849868
      --lon             Longitude of the starting point. Default: 8.539661719099556
  -t, --max-threads     Maximum number of threads to use. Default: 1
  -h, --help            Show this help message
```

```sh
just run -- -i data/switzerland_walkable_100m.zl -d 1000
```

## Convert - Generate .zl file from OSM data

If you want to generate your own `.zl` file, you can use the `convert/` subproject (`zillconv`). It depends on [PROJ](https://proj.org/) to convert the coordinates from WGS84 to Swiss coordinate system (EPSG:21781) and [expat](https://libexpat.github.io/) to parse the OSM XML data. End goal would be to fully remove these system dependencies and build everything with the Zig build system.

### Generating graph.zl

Requires `proj.db` for now.

```sh
PROJ_DATA=/usr/share/proj just generate
```

### Elevation Map

Requires [GDAL](https://gdal.org/en/stable/download.html#binaries) to convert the coarse elevation data from SwissTopo into a GeoTIFF.

1. Download coarse elevation data from [SwissTopo](https://www.swisstopo.admin.ch/de/hoehenmodell-dhm25#DHM25---Download).
2. Convert the `.asc` into `.tif`.

```sh
curl -f -o /tmp/dhm25.zip "https://cms.geo.admin.ch/ogd/topography/DHM25_MM_ASCII_GRID.zip"
unzip -q -j /tmp/dhm25.zip -d /tmp/dhm25

gdal_translate \
    -a_srs EPSG:21781 \
    -a_nodata -9999 \
    -co TILED=YES \
    -co COMPRESS=DEFLATE \
    -co PREDICTOR=2 \
    -co BIGTIFF=IF_SAFER \
    /tmp/dhm25/dhm25_grid_raster.asc \
    data/switzerland_dhm25.tif
```

### OSM Extraction

https://download.geofabrik.de/europe/switzerland.html
