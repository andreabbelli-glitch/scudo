#!/usr/bin/env python3
"""Pubblica un ADP estratto nel sito statico e aggiorna la source di AltStore.

- copia la cartella dell'ADP (quella che contiene manifest.json) in
  docs/adp/<versione>-<build>/ senza modificarne alcun file, come richiede
  AltStore (gli hash devono restare identici);
- legge versione, build, iOS minimo, entitlement e permessi privacy
  direttamente dall'app firmata da Apple contenuta nell'ADP;
- aggiunge la nuova versione in cima a "versions" in docs/source.json e
  aggiorna "appPermissions" (AltStore rifiuta di installare app con
  entitlement non dichiarati).

Uso: update_source.py --adp <cartella estratta> --site docs [--notes "Novità"]
"""
import argparse
import datetime
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

# AltStore li ignora nella verifica (VerifyAppOperation.ignoredEntitlements).
IGNORED_ENTITLEMENTS = {"application-identifier", "com.apple.developer.team-identifier"}
PLACEHOLDER_MARKERS = ("TUO-UTENTE", "TUO-REPO", "DA-APP-STORE-CONNECT", "IL TUO NOME")


def fail(message: str) -> None:
    print(f"✘ {message}", file=sys.stderr)
    sys.exit(1)


def find_adp_root(folder: Path) -> Path:
    manifests = [p for p in folder.rglob("manifest.json") if "__MACOSX" not in p.parts]
    if not manifests:
        fail("manifest.json non trovato nel pacchetto scaricato.")
    return min(manifests, key=lambda p: len(p.parts)).parent


def read_entitlements(bundle: Path) -> dict:
    for flag in (["--xml"], []):
        target = "-" if flag else ":-"
        result = subprocess.run(
            ["codesign", "-d", "--entitlements", target, *flag, str(bundle)],
            capture_output=True,
        )
        output = result.stdout.strip()
        if result.returncode == 0 and output.startswith(b"<?xml"):
            return plistlib.loads(output)
    return {}


def inspect_ipa(ipa: Path) -> tuple[dict, list[str], dict]:
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(ipa) as archive:
            archive.extractall(tmp)
        apps = sorted(Path(tmp, "Payload").glob("*.app"))
        if not apps:
            fail(f"Nessuna app dentro {ipa.name}.")
        app = apps[0]
        info = plistlib.loads((app / "Info.plist").read_bytes())
        bundles = [app, *sorted((app / "PlugIns").glob("*.appex"))]

        entitlements: set[str] = set()
        privacy: dict[str, str] = {}
        for bundle in bundles:
            # Declaring an entitlement AltStore would ignore is harmless; missing
            # one blocks the install, so everything else is declared.
            for key in read_entitlements(bundle):
                if key not in IGNORED_ENTITLEMENTS:
                    entitlements.add(key)
            bundle_info = plistlib.loads((bundle / "Info.plist").read_bytes())
            for key, value in bundle_info.items():
                if key.endswith("UsageDescription") and isinstance(value, str):
                    privacy[key] = value
        return info, sorted(entitlements), privacy


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--adp", required=True, type=Path, help="cartella con l'ADP estratto")
    parser.add_argument("--site", required=True, type=Path, help="cartella del sito (docs)")
    parser.add_argument("--notes", default=None, help="novità della versione")
    args = parser.parse_args()

    source_path = args.site / "source.json"
    source = json.loads(source_path.read_text(encoding="utf-8"))

    website = source.get("website", "")
    if not website.startswith("https://") or any(m in website for m in PLACEHOLDER_MARKERS):
        fail('Imposta "website" in docs/source.json con l\'indirizzo HTTPS del tuo sito (es. https://utente.github.io/scudo/).')
    base_url = website.rstrip("/") + "/"

    adp_root = find_adp_root(args.adp)
    ipas = sorted(adp_root.rglob("*.ipa"), key=lambda p: p.stat().st_size, reverse=True)
    if not ipas:
        fail("Nessun file .ipa nel pacchetto.")
    info, entitlements, privacy = inspect_ipa(ipas[0])
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    bundle_id = info["CFBundleIdentifier"]

    apps = [app for app in source.get("apps", []) if app.get("bundleIdentifier") == bundle_id]
    if not apps:
        fail(f'In docs/source.json nessuna app ha "bundleIdentifier": "{bundle_id}". Correggilo e rilancia.')
    app = apps[0]
    for key in ("marketplaceID", "developerName", "iconURL"):
        value = str(app.get(key, ""))
        if not value or any(m in value for m in PLACEHOLDER_MARKERS):
            fail(f'Compila "{key}" dell\'app in docs/source.json (vedi README).')

    folder_name = f"{version}-{build}"
    destination = args.site / "adp" / folder_name
    if destination.exists():
        fail(f"{destination} esiste già: per una nuova pubblicazione aumenta il numero di build.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(adp_root, destination)

    entry = {
        "version": version,
        "buildVersion": build,
        "date": datetime.date.today().isoformat(),
        "localizedDescription": args.notes or f"Versione {version} ({build}).",
        "downloadURL": f"{base_url}adp/{folder_name}/manifest.json",
        "size": ipas[0].stat().st_size,
        "minOSVersion": info.get("MinimumOSVersion", "17.0"),
    }
    app["versions"] = [entry] + [
        v for v in app.get("versions", [])
        if not (v.get("version") == version and v.get("buildVersion") == build)
    ]
    app["appPermissions"] = {"entitlements": entitlements, "privacy": privacy}

    source_path.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(f"✔ ADP copiato in {destination.relative_to(args.site.parent)}")
    print(f"✔ source.json aggiornata: {bundle_id} {version} ({build}), {entry['size']:,} byte")
    print(f"  entitlement dichiarati: {', '.join(entitlements) or 'nessuno'}")
    print("\nOra pubblica il sito, per esempio:")
    print(f'  git add docs && git commit -m "Scudo {version} ({build})" && git push')


if __name__ == "__main__":
    main()
