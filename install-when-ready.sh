#!/bin/zsh
# Waits for the iPhone to appear over the local network (e.g. Personal Hotspot), then installs and opens Latent.
# Works without internet. Log: install-log.txt next to this script.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEVICE=00008120-001C152C0268C01E
APP="$(dirname "$0")/build/DerivedData/Build/Products/Release-iphoneos/Latent.app"
LOG="$(dirname "$0")/install-log.txt"
echo "$(date '+%H:%M:%S') waiting for iPhone (up to 15 min)…" > "$LOG"
end=$((SECONDS + 900))
while (( SECONDS < end )); do
  state=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE")
  if [[ "$state" != *unavailable* && -n "$state" ]]; then
    echo "$(date '+%H:%M:%S') phone visible, installing…" >> "$LOG"
    if out=$(xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1) && [[ "$out" == *"App installed"* ]]; then
      echo "$(date '+%H:%M:%S') INSTALLED" >> "$LOG"
      # Copy the newest portrait frames (depth map, negative, recipe, print) back for tuning. Skips quietly if none.
      PULL="$(dirname "$0")/tools/device-pull"; mkdir -p "$PULL"
      LIST="$PULL/.files.json"
      if xcrun devicectl device info files --device "$DEVICE" --domain-type appDataContainer \
           --domain-identifier dev.latentcam.app11da0f --subdirectory Documents/Roll --json-output "$LIST" >/dev/null 2>&1; then
        for base in $(python3 -c 'import json,re,sys; t=open(sys.argv[1]).read(); b=sorted(set(re.findall(r"(\d{13})\.depth\.png", t)))[-6:]; print(" ".join(b))' "$LIST"); do
          for f in $(python3 -c 'import re,sys; t=open(sys.argv[1]).read(); print(" ".join(sorted(set(re.findall(sys.argv[2]+r"[^\"/]*", t)))))' "$LIST" "$base"); do
            xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier dev.latentcam.app11da0f \
              --source "Documents/Roll/$f" --destination "$PULL/$f" >/dev/null 2>&1
          done
        done
        echo "$(date '+%H:%M:%S') pulled $(ls "$PULL" | grep -c depth.png) portrait frames" >> "$LOG"
      fi
      xcrun devicectl device process launch --device "$DEVICE" dev.latentcam.app11da0f >> "$LOG" 2>&1
      echo "DONE" >> "$LOG"
      exit 0
    fi
    echo "$(date '+%H:%M:%S') attempt failed: $(echo "$out" | grep -m1 -i error | cut -c1-160)" >> "$LOG"
  fi
  sleep 5
done
echo "$(date '+%H:%M:%S') GAVE UP (phone never accepted the install)" >> "$LOG"
exit 1
