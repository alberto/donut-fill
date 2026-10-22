#!/bin/sh
# Rasterizes assets/icon.svg into assets/AppIcon.icns (needs rsvg-convert: brew install librsvg).
set -eu
cd "$(dirname "$0")/.."
set="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$set"
for s in 16 32 128 256 512; do
  rsvg-convert -w "$s" -h "$s" assets/icon.svg -o "$set/icon_${s}x${s}.png"
  rsvg-convert -w "$((s*2))" -h "$((s*2))" assets/icon.svg -o "$set/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$set" -o assets/AppIcon.icns
rsvg-convert -w 1024 assets/icon.svg -o assets/icon.png
echo "wrote assets/AppIcon.icns, assets/icon.png"
