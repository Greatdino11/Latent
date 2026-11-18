#!/bin/zsh
# Renders sample photos through every stock in the iOS Simulator and writes a contact sheet, so look changes can
# be compared before/after. Usage: tools/lookbook.sh [output.jpg] [--raw]
#   --raw   treat inputs as under-exposed RAW captures (exercises lab exposure + highlight colour)
# Inputs: the simulator's sample photos, or your own files in tools/lookbook-input/ (JPEG/HEIC).
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
OUT=${1:-lookbook.jpg}; FLAG=""; [[ "$2" == "--raw" || "$1" == "--raw" ]] && FLAG="-asRAW"; [[ "$1" == "--raw" ]] && OUT=lookbook.jpg
SIM=$(xcrun simctl list devices available | grep -m1 "iPhone 16 Pro (" | grep -oE '[0-9A-F-]{36}')
BUNDLE=dev.latentcam.app11da0f
xcrun simctl boot "$SIM" 2>/dev/null || true
xcodebuild -project Latent.xcodeproj -scheme Latent -destination "id=$SIM" -derivedDataPath build/DerivedData build -quiet
xcrun simctl install "$SIM" build/DerivedData/Build/Products/Debug-iphonesimulator/Latent.app
xcrun simctl terminate "$SIM" $BUNDLE 2>/dev/null || true
DATA=$(xcrun simctl get_app_container "$SIM" $BUNDLE data)
rm -rf "$DATA/Documents/Roll" "$DATA/Documents/DemoInput"; mkdir -p "$DATA/Documents/DemoInput"
if [[ -d tools/lookbook-input ]]; then cp tools/lookbook-input/* "$DATA/Documents/DemoInput/"
else cp ~/Library/Developer/CoreSimulator/Devices/$SIM/data/Media/DCIM/100APPLE/IMG_000{1,3,5}.* "$DATA/Documents/DemoInput/"; fi
N=$(ls "$DATA/Documents/DemoInput" | wc -l | tr -d ' ')
EXPECT=$(( N * (${#FLAG} > 0 ? 4 : 10) ))
xcrun simctl launch "$SIM" $BUNDLE -demoInput $FLAG >/dev/null
for i in {1..120}; do c=$(ls "$DATA/Documents/Roll" 2>/dev/null | grep -c jpg || true); (( c >= EXPECT )) && break; sleep 2; done
sleep 2
swift tools/contact-sheet.swift "$OUT" $(ls "$DATA"/Documents/Roll/*.jpg | sort)
echo "wrote $OUT ($c frames)"
