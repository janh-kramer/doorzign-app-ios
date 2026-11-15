#!/bin/zsh
# Typecheck der App-Quellen unter macOS – Behelf, solange kein Xcode/iOS-SDK verfügbar ist.
# iOS-spezifische APIs werden durch scripts/macos-shims/IOSShims.swift nachgebildet; QRScannerView.swift,
# CameraPicker.swift und AppInfo.swift (UIKit/AVFoundation) sind ausgenommen und damit NICHT geprüft.
# Ersetzt keinen echten iOS-Build (`xcodegen generate` + Xcode).
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
(cd Packages/DoorZignKit && swift build >/dev/null)
{ find App/Sources -name '*.swift' ! -name QRScannerView.swift ! -name AppInfo.swift ! -name CameraPicker.swift
  echo scripts/macos-shims/IOSShims.swift
} | xargs swiftc -typecheck -target arm64-apple-macos14 -strict-concurrency=complete \
  -I Packages/DoorZignKit/.build/debug/Modules
echo "Typecheck der App-Quellen erfolgreich (ohne QRScannerView, CameraPicker, AppInfo)."
