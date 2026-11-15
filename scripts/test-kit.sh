#!/bin/zsh
# Tests von DoorZignKit (macOS). Mit Xcode genügt `swift test`; mit den Command Line Tools allein
# muss das Testing-Framework explizit eingebunden und das Foundation-Overlay abgeschaltet werden.
set -euo pipefail
cd ${0:A:h:h}/Packages/DoorZignKit
if xcode-select -p | grep -q CommandLineTools; then
  F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  swift test -Xswiftc -F$F -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L "$@"
else
  swift test "$@"
fi
