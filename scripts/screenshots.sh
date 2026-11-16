#!/bin/zsh
# Screenshots der App gegen eine Demo-Instanz (iPhone/iPad × de/en × hell/dunkel).
#
#   scripts/screenshots.sh <demo.env> [Ausgabeordner]
#
# demo.env enthält: link=doorzign://edge?…  user=…  password=…  [display=…]
# Nutzt eigene Simulatoren „DZ Shot iPhone“/„DZ Shot iPad“ (werden bei Bedarf angelegt und gelöscht/zurückgesetzt),
# damit die eigenen Simulatoren unberührt bleiben. Speichert nichts auf der Instanz.
set -euo pipefail
ROOT=${0:A:h:h}
ENV_FILE=${1:?Pfad zu demo.env fehlt}
OUT=${2:-$ROOT/Screenshots}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

value() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }
export TEST_RUNNER_DZ_LINK="$(value link)"
export TEST_RUNNER_DZ_USER="$(value user)"
export TEST_RUNNER_DZ_PASSWORD="$(value password)"
export TEST_RUNNER_DZ_DISPLAY="$(value display)"
[[ -n $TEST_RUNNER_DZ_LINK && -n $TEST_RUNNER_DZ_USER && -n $TEST_RUNNER_DZ_PASSWORD ]] || { echo "link/user/password fehlen in $ENV_FILE"; exit 1; }

typeset -A DEVICES
DEVICES=(
  iphone "DZ Shot iPhone|com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max"
  ipad   "DZ Shot iPad|com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
)
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys;r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]];print(r[-1]["identifier"])')

cd "$ROOT"
xcodegen generate >/dev/null
xcodebuild build-for-testing -project DoorZign.xcodeproj -scheme DoorZign \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData -quiet

for key in iphone ipad; do
  name=${DEVICES[$key]%%|*}; type=${DEVICES[$key]#*|}
  udid=$(xcrun simctl list devices -j | python3 -c "import json,sys;n=sys.argv[1];print(next((d['udid'] for v in json.load(sys.stdin)['devices'].values() for d in v if d['name']==n),''))" "$name")
  [[ -n $udid ]] || udid=$(xcrun simctl create "$name" "$type" "$RUNTIME")
  for language in de en; do
    for appearance in light dark; do
      echo "== $key $language $appearance"
      xcrun simctl shutdown "$udid" 2>/dev/null || true
      xcrun simctl erase "$udid"          # frischer Start: Willkommensbildschirm, Anmeldung
      xcrun simctl boot "$udid"
      xcrun simctl bootstatus "$udid" -b >/dev/null
      xcrun simctl ui "$udid" appearance $appearance
      xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
      result="$WORK/$key-$language-$appearance.xcresult"
      TEST_RUNNER_DZ_LANGUAGE=$language xcodebuild test-without-building -project DoorZign.xcodeproj \
        -scheme DoorZign -destination "id=$udid" -derivedDataPath DerivedData \
        -only-testing:DoorZignUITests/ScreenshotTests -resultBundlePath "$result" -quiet || echo "!! Test meldet Fehler ($key $language $appearance), vorhandene Aufnahmen werden trotzdem exportiert"
      dir="$OUT/$key/$language/$appearance"
      mkdir -p "$dir"
      xcrun xcresulttool export attachments --path "$result" --output-path "$WORK/att" >/dev/null
      python3 - "$WORK/att" "$dir" <<'PY'
import json, os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(src, "manifest.json")))
for test in manifest:
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName", a["exportedFileName"])
        base = name.split("_")[0] if name[:2].isdigit() else os.path.splitext(name)[0]
        shutil.copy(os.path.join(src, a["exportedFileName"]), os.path.join(dst, base + ".png"))
PY
      rm -rf "$WORK/att"
      xcrun simctl status_bar "$udid" clear
    done
  done
  xcrun simctl shutdown "$udid" 2>/dev/null || true
done
echo "Fertig: $OUT"
