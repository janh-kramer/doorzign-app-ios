#!/bin/zsh
# Screenshots der App gegen eine Demo-Instanz (iPhone/iPad × de/en × hell/dunkel).
#
#   scripts/screenshots.sh <de.env> <en.env> [Ausgabeordner]
#
# Je Sprache eine Datei mit: link=doorzign://edge?…  user=…  password=…
#   optional: display=…  adhoc_display=…  schedule_display=…  (Teil des Display-Namens)
# Nutzt eigene Simulatoren „DZ Shot iPhone“/„DZ Shot iPad“ (werden bei Bedarf angelegt und gelöscht/zurückgesetzt),
# damit die eigenen Simulatoren unberührt bleiben. Speichert nichts auf der Instanz.
set -euo pipefail
ROOT=${0:A:h:h}
typeset -A ENV_FILES
ENV_FILES=(de "${1:?Pfad zu de.env fehlt}" en "${2:?Pfad zu en.env fehlt}")
OUT=${3:-$ROOT/Screenshots}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

value() { grep -E "^$2=" "$1" | head -1 | cut -d= -f2-; }
use_language() {
  local file=${ENV_FILES[$1]}
  export TEST_RUNNER_DZ_LANGUAGE=$1
  export TEST_RUNNER_DZ_LINK="$(value $file link)"
  export TEST_RUNNER_DZ_USER="$(value $file user)"
  export TEST_RUNNER_DZ_PASSWORD="$(value $file password)"
  export TEST_RUNNER_DZ_DISPLAY="$(value $file display)"
  export TEST_RUNNER_DZ_ADHOC_DISPLAY="$(value $file adhoc_display)"
  export TEST_RUNNER_DZ_SCHEDULE_DISPLAY="$(value $file schedule_display)"
  [[ -n $TEST_RUNNER_DZ_LINK && -n $TEST_RUNNER_DZ_USER && -n $TEST_RUNNER_DZ_PASSWORD ]] || { echo "link/user/password fehlen in $file"; exit 1; }
}
for l in de en; do use_language $l; done  # früh prüfen

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

for key in ${=DEVICES_TO_RUN:-iphone ipad}; do
  name=${DEVICES[$key]%%|*}; type=${DEVICES[$key]#*|}
  udid=$(xcrun simctl list devices -j | python3 -c "import json,sys;n=sys.argv[1];print(next((d['udid'] for v in json.load(sys.stdin)['devices'].values() for d in v if d['name']==n),''))" "$name")
  [[ -n $udid ]] || udid=$(xcrun simctl create "$name" "$type" "$RUNTIME")
  for language in ${=LANGUAGES:-de en}; do
    use_language $language
    for appearance in ${=APPEARANCES:-light dark}; do
      echo "== $key $language $appearance"
      xcrun simctl shutdown "$udid" 2>/dev/null || true
      xcrun simctl erase "$udid"          # frischer Start: Willkommensbildschirm, Anmeldung
      xcrun simctl boot "$udid"
      xcrun simctl bootstatus "$udid" -b >/dev/null
      xcrun simctl ui "$udid" appearance $appearance
      xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
      result="$WORK/$key-$language-$appearance.xcresult"
      xcodebuild test-without-building -project DoorZign.xcodeproj \
        -scheme DoorZign -destination "id=$udid" -derivedDataPath DerivedData \
        -only-testing:DoorZignUITests/ScreenshotTests \
        -test-timeouts-enabled YES -maximum-test-execution-time-allowance 900 -resultBundlePath "$result" -quiet || echo "!! Test meldet Fehler ($key $language $appearance), vorhandene Aufnahmen werden trotzdem exportiert"
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
        if not name[:2].isdigit():
            continue  # Diagnose-Anhänge von XCTest
        base = name.split("_")[0]
        shutil.copy(os.path.join(src, a["exportedFileName"]), os.path.join(dst, base + ".png"))
PY
      rm -rf "$WORK/att"
      xcrun simctl status_bar "$udid" clear
    done
  done
  xcrun simctl shutdown "$udid" 2>/dev/null || true
done
echo "Fertig: $OUT"
