## Start

Requires `proj.db` for now.

```sh
PROJ_DATA="/usr/share/proj" zig build run
```

## Elevation Map

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
