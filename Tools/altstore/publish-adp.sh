#!/bin/bash
# Scarica da AltStore l'Alternative Distribution Package (ADP) di una versione
# notarizzata, lo copia in docs/adp/<versione>-<build>/ e aggiorna docs/source.json.
# Poi basta fare commit e push di docs/ per pubblicare l'aggiornamento.
#
# L'ADP ID si trova in App Store Connect › App › Distribuzione › Cronologia
# (campo "Alternative Distribution Package ID" accanto alla versione approvata).
#
# Uso: Tools/altstore/publish-adp.sh <ADP_ID> ["Novità di questa versione"]
set -euo pipefail

ADP_ID="${1:-}"
NOTES="${2:-}"
if [ -z "$ADP_ID" ]; then
    echo "Uso: $0 <ADP_ID> [\"Novità di questa versione\"]" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
API="https://api.altstore.io"

# Prints a field of a JSON object, or nothing if the text is not valid JSON
# (e.g. an HTML error page): the polling loop must not die on it.
json_field() {
    python3 -c '
import json, sys
try:
    value = json.loads(sys.argv[1]).get(sys.argv[2])
except Exception:
    value = None
print(value or "")
' "$1" "$2" || true
}

echo "→ Chiedo ad AltStore di elaborare l'ADP $ADP_ID…"
post=$(curl -sS -H "Content-Type: application/json" -X POST --data "{\"adpID\":\"$ADP_ID\"}" "$API/adps" || true)
echo "   risposta: ${post:-(vuota)}"

echo "→ Attendo che il pacchetto sia pronto (di solito pochi minuti)…"
url=""
for attempt in $(seq 1 60); do
    response=$(curl -sS "$API/adps/$ADP_ID" || true)
    url=$(json_field "$response" downloadURL)
    status=$(json_field "$response" status)
    [ -n "$url" ] && break
    if [ "$status" = "failure" ]; then
        echo "✘ AltStore non è riuscito a elaborare l'ADP: $response" >&2
        echo "  Controlla in App Store Connect › Business di aver accettato gli accordi più recenti (anche il Paid Apps Agreement)." >&2
        exit 1
    fi
    echo "   stato: ${status:-in attesa} ($attempt/60)"
    sleep 20
done
if [ -z "$url" ]; then
    echo "✘ Il pacchetto non è pronto dopo 20 minuti: rilancia lo script più tardi." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "→ Scarico il pacchetto…"
curl -sS -L --fail -o "$WORK/adp.zip" "$url"
mkdir "$WORK/adp"
if ! unzip -q "$WORK/adp.zip" -d "$WORK/adp"; then
    echo "✘ Il file scaricato non è un archivio zip: $url" >&2
    exit 1
fi

if [ -n "$NOTES" ]; then
    python3 "$ROOT/Tools/altstore/update_source.py" --adp "$WORK/adp" --site "$ROOT/docs" --notes "$NOTES"
else
    python3 "$ROOT/Tools/altstore/update_source.py" --adp "$WORK/adp" --site "$ROOT/docs"
fi
