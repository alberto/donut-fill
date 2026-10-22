#!/bin/sh
# Usage: contact_sheet.sh out.png a.png b.png ...  (3 per row, 400px tiles)
out=$1; shift; n=$#; rows=$(( (n + 2) / 3 ))
{
  echo "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"1200\" height=\"$((rows*400))\"><rect width=\"100%\" height=\"100%\" fill=\"#888\"/>"
  i=0; for f in "$@"; do
    echo "<image x=\"$(( (i%3)*400 ))\" y=\"$(( (i/3)*400 ))\" width=\"400\" height=\"400\" xlink:href=\"data:image/png;base64,$(base64 -i "$f")\"/>"
    i=$((i+1)); done
  echo '</svg>'
} | rsvg-convert -o "$out"
