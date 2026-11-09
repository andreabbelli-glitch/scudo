#!/bin/bash
# Registra il tuo Developer ID presso AltStore PAL e stampa il token da inserire
# in App Store Connect › Utenti e accesso › Integrazioni › Marketplace.
#
# Il Developer ID si trova in App Store Connect: in alto a destra, il tuo nome ›
# Modifica profilo › Developer ID.
#
# Uso: Tools/altstore/register.sh <DEVELOPER_ID> <EMAIL>
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Uso: $0 <DEVELOPER_ID> <EMAIL>" >&2
    exit 2
fi

payload=$(python3 -c 'import json, sys; print(json.dumps({"developerID": sys.argv[1], "email": sys.argv[2]}))' "$1" "$2")
response=$(curl --fail-with-body -sS -H "Content-Type: application/json" -X POST --data "$payload" https://api.altstore.io/register)

echo "$response" | python3 -c '
import json, sys
data = json.load(sys.stdin)
token = data.get("token")
if not token:
    print("Risposta inattesa:", data)
    sys.exit(1)
print("Token AltStore PAL (valido fino a %s):\n\n%s\n" % (data.get("expiration", "?"), token))
print("Inseriscilo in App Store Connect › Utenti e accesso › Integrazioni › Marketplace › +.")
'
