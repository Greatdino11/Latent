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
