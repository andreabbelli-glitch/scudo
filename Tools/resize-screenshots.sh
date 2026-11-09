#!/bin/bash
# App Store Connect vuole screenshot per lo schermo da 6,9" (1290×2796).
# Quelli di iPhone 15 (1179×2556) hanno le stesse proporzioni: basta
# ridimensionarli. L'output è JPEG, quindi senza canale alfa (rifiutato da Apple).
#
# Uso: Tools/resize-screenshots.sh [cartella]   (predefinita: Screenshots)
set -euo pipefail

DIR="${1:-Screenshots}"
OUT="$DIR/AppStore"
mkdir -p "$OUT"
shopt -s nullglob nocaseglob
count=0
for file in "$DIR"/*.png "$DIR"/*.jpg "$DIR"/*.jpeg "$DIR"/*.heic; do
    name="$(basename "${file%.*}")"
    sips -z 2796 1290 -s format jpeg -s formatOptions 92 "$file" --out "$OUT/$name.jpg" >/dev/null
    echo "✔ $OUT/$name.jpg"
    count=$((count + 1))
done
[ "$count" -gt 0 ] || echo "Nessuna immagine in $DIR (metti lì gli screenshot fatti con l'iPhone)."
