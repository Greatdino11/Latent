# Latent

An original iOS film camera inspired by how **mood.camera** (Alex Fox) works: a point-and-shoot with no live
filter preview, where each frame "develops" after you take it. All names, film looks, code and artwork here are new.

## How this was derived

mood.camera isn't installed on this Mac. App Store binaries are FairPlay-encrypted, and decrypting them would
mean circumventing DRM, so the app's code was **not** decompiled. The feature set comes from its public App Store
listing and a published review:

| Observed in public sources | How Latent does it |
|---|---|
| No live preview of the look; result revealed after capture | Plain viewfinder; roll thumbnail "develops" in over ~2.4 s |
| 14 colour emulations, hide & reorder | 10 original stocks (8 colour, 2 B&W), hide / drag to reorder |
| "Random" emulation mode from a chosen set | RANDOM chip + per-stock dice toggle for the pool |
| Phone photos look over-processed | Shoots **Apple ProRAW** and decodes it neutrally (no local tone mapping, sharpening or boost curve); the stock's film curve does the tone |
| Film grain modelled on development, adjustable | Midtone-weighted grain in gamma space, size per stock, global slider |
| Halation from the brightest highlights (gain map) | Highlight mask → wide + tight blur → tinted glow; iOS 18 loads the HDR gain map |
| Filmic, compressed dynamic range | `CIToneMapHeadroom` rolloff (iOS 18) + per-stock S-curve, black lift, white shoulder |
| On-screen exposure dial | ±2 EV ruler in ⅓ stops, drives the sensor's exposure bias |
| Multiple aspect ratios, optional grid & level | 3:2, 4:3, 1:1, 16:9, 65:24 pano; grid; CoreMotion level |
| Default lens per focal length | Lens buttons from the virtual device's switch-over zooms (.5 / 1 / tele) |
| (Requested) change the look afterwards | Every frame keeps a 10-bit "negative" (`<base>.neg.heic`) + recipe; re-develop on any stock from the roll |
| Lens character | Bloom, softness, lateral chromatic aberration, lens-flare ghosts from bright point sources |
| Custom frames added at capture | None / white / black print frame with stock caption |
| Optionally save the original too | "Also save the original" setting |

Not built (paid-tier or larger features): portrait lens bokeh models, double exposure, custom preset editor, 24MP mode.
Date stamp is an extra.

## Using it

- **Shoot:** shutter, or either volume button. Double-tap the viewfinder (or the top-right camera icon) for the front camera.
- **Roll:** tap the thumbnail → newest frame full screen; swipe sideways, pinch/double-tap to zoom, swipe down for the grid.
  Long-press in the grid (or the ✓ button) to select several frames: save, share, re-develop, delete.
- **Develop afterwards** (from the frame's negative): FILM = stock + look strength, LIGHT = push/pull ±2 EV,
  FRAME = re-crop (full frame or any ratio), date stamp, border. ••• ▸ Reprint applies current grain/halation/flare.
- **Photos:** each frame is one asset, edited in place when re-developed; with "Keep the original underneath" the RAW
  is the base image and Photos ▸ Revert returns it.
- **Control Center / Lock Screen:** add the "Latent Camera" control (iOS 18) — `LatentControls/` widget extension.
- **Portrait:** the person icon on the camera captures depth (instead of ProRAW); the roll's LENS tool sets the
  lens (Classic, Bubble, Swirl), blur and focus afterwards. iPhone Portrait-mode photos you import keep their depth.
- **Your own stocks:** Settings ▸ Stocks ▸ New stock — sliders on top of any stock with a live preview.
- **Scan character:** light leaks, dust & scratches, and a 35mm sprocket border (Settings ▸ Finishing, or FRAME).
- Settings also has: lens flare strength, per-stock look strength, location tagging, full-screen reveal, haptics,
  film-advance sound, storage usage and discarding old negatives.

## Development

- **Tests:** `xcodebuild test -project Latent.xcodeproj -scheme Latent -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`
  (film curves, crop maths, old-recipe compatibility, negative round-trip, roll archive safety, EXIF dates).
- **Lookbook:** `tools/lookbook.sh out.jpg [--raw]` renders sample photos (or `tools/lookbook-input/`) through
  every stock in the Simulator and writes a contact sheet — run before and after a look change.
- **Calibrating on real captures:** in the roll, ••• ▸ Share negative (or select several ▸ Share negatives), AirDrop
  them here, put them in the app's `Documents/DemoNegatives/`, launch with `-demoNegatives`.
- **Installing without a cable:** `./install-when-ready.sh` waits for the phone (e.g. on its Personal Hotspot) and
  installs offline. `dist/Latent.ipa` is the same build for SideStore.
- **Moving the roll** (e.g. to a SideStore install): Settings ▸ Storage ▸ Export roll / Import roll (`.latentroll`).

## Layout

```
Latent/
  App/        LatentApp (theme), AppModel (capture → develop → save)
  Camera/     CameraController (AVFoundation), CameraPreview, LevelMonitor, SimulatedScene
  Film/       FilmStock (looks), LUT (cube generator), Darkroom (develop actor, LUT cache, lab exposure, NegativeCodec),
              FilmPipeline (Core Image stages), Finisher (date stamp, border, JPEG), DevelopTypes
  Storage/    RollStore (roll, negatives, recipes, Photos linking, storage), RollArchive, Preferences
  LatentTests/  unit tests      tools/  lookbook contact sheets
  Shared/     OpenLatentIntent (used by the app and the control extension)
  LatentControls/  iOS 18 Control Center / Lock Screen control
  UI/         CameraScreen, Viewfinder, Controls (stock strip, EV dial, shutter, lenses), RollView, SettingsView
```

Pipeline (`Film/Darkroom.swift`), all from scene-linear light: crop → exposure → highlight mask → 64³ LUT
(colour in linear, then per-channel log-exposure S-curves = the film's characteristic curve, lifted/tinted black,
cream white; covers +5.5 stops) → halation → bloom → softness → chromatic aberration → flare → vignette → grain
→ (date stamp / frame) → JPEG with original EXIF. Debug builds accept `-demoInput` to develop every image in the
app's Documents/DemoInput on every stock.

## Run

Open `Latent.xcodeproj` in Xcode, pick your team under Signing, the bundle ID is `dev.latentcam.app11da0f` (change if you like), and run
on an iPhone (iOS 17+). On the Simulator there is no camera, so the viewfinder shows a generated test scene and the
shutter develops it. To develop that scene on every stock at launch (Debug builds only), pass the launch argument `-demoRoll`.

Command line, without changing `xcode-select`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Latent.xcodeproj -scheme Latent -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -derivedDataPath build/DerivedData build
```
