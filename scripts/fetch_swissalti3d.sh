#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <min_lon> <min_lat> <max_lon> <max_lat> <output.tif>"
    echo "Example: $0 8.28 47.15 9.00 47.49 zurich_lake.tif"
    exit 1
fi

MIN_LON="$1"
MIN_LAT="$2"
MAX_LON="$3"
MAX_LAT="$4"
OUTPUT="$5"

# Ensure latitudes are properly ordered (min < max)
if (( $(echo "$MIN_LAT > "$MAX_LAT | bc -l) )); then
    SWAP="$MIN_LAT"
    MIN_LAT="$MAX_LAT"
    MAX_LAT="$SWAP"
fi

# Ensure longitudes are properly ordered (min < max)
if (( $(echo "$MIN_LON > "$MAX_LON | bc -l) )); then
    SWAP="$MIN_LON"
    MIN_LON="$MAX_LON"
    MAX_LON="$SWAP"
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Querying Swisstopo STAC API..."
URLS=$(curl -sG "https://data.geo.admin.ch/api/stac/v0.9/collections/ch.swisstopo.swissalti3d/items" \
  --data-urlencode "bbox=${MIN_LON},${MIN_LAT},${MAX_LON},${MAX_LAT}" \
  | jq -r '.features[].assets[] | select(.href | endswith("_2_2056_5728.tif")) | .href' \
  | sort -u)

if [ -z "$URLS" ]; then
    echo "Error: No tiles found for bounding box."
    exit 1
fi

COUNT=$(echo "$URLS" | wc -l)
echo "Found ${COUNT} tile(s). Downloading (this may take a while)..."

# Download preserving the remote basename
echo "$URLS" | xargs -P 8 -I {} curl -s -f -O --output-dir "${TMP_DIR}" "{}"

echo "Building VRT and clipping to bounding box..."
gdalbuildvrt -q "${TMP_DIR}/merged.vrt" "${TMP_DIR}"/*.tif

gdalwarp \
  -te "$MIN_LON" "$MIN_LAT" "$MAX_LON" "$MAX_LAT" \
  -te_srs EPSG:4326 \
  -r bilinear \
  -co TILED=YES \
  -co COMPRESS=DEFLATE \
  "${TMP_DIR}/merged.vrt" "$OUTPUT"

echo "Done: ${OUTPUT}"
