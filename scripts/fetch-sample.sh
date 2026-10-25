#!/usr/bin/env bash
# Downloads one public chest CT series (LIDC-IDRI-0001, CC BY 3.0) from The Cancer Imaging Archive.
set -euo pipefail
cd "$(dirname "$0")/.."

SERIES="1.3.6.1.4.1.14519.5.2.1.6279.6001.179049373636438705059720603192"
OUT="sample-data/LIDC-IDRI-0001"
mkdir -p "$OUT"
curl -fL --progress-bar -o sample-data/lidc.zip \
    "https://services.cancerimagingarchive.net/nbia-api/services/v1/getImage?SeriesInstanceUID=$SERIES"
unzip -q -o sample-data/lidc.zip -d "$OUT"
rm sample-data/lidc.zip
echo "Saved $(ls "$OUT" | wc -l | tr -d ' ') files to $OUT"
