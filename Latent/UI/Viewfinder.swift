import SwiftUI

/// 3:4 live view with aspect mask, grid, level and focus reticle. Never shows the film look.
struct Viewfinder: View {
    @Environment(AppModel.self) private var model
    @State private var focusPoint: CGPoint?
    @State private var blink = false
    /// Split focus and exposure (two-finger tap): where each marker sits in the viewfinder; nil = combined.
    @State private var split: (focus: CGPoint, exposure: CGPoint)?
    @State private var points = PreviewPoints()
    /// Focus or exposure was put somewhere by hand (tap, lock or split): offer the way back to automatic.
    @State private var pointSet = false

    var body: some View {
        let prefs = model.prefs
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let frame = Self.frameRect(in: geo.size, aspect: prefs.aspect)
                    ZStack {
                        source
                        AspectMask(frame: frame)
                        if prefs.showGrid { GridLines(frame: frame) }
                        if prefs.showLevel { LevelLine(tilt: model.level.tilt).position(x: frame.midX, y: frame.midY) }
                        if let p = focusPoint, split == nil { FocusReticle().position(p).allowsHitTesting(false) }
                        if let s = split {
                            SplitMarker(kind: .focus).position(s.focus)
                                .gesture(drag(geo.size) { p in split?.focus = p; if let d = points.devicePoint(for: p) { model.camera.setFocus(at: d) } })
                            SplitMarker(kind: .exposure).position(s.exposure)
                                .gesture(drag(geo.size) { p in split?.exposure = p; if let d = points.devicePoint(for: p) { model.camera.setExposure(at: d) } })
                        }
                        if model.camera.aeafLocked {
                            Text("AE/AF LOCK")
                                .font(Theme.mono(10, .bold)).foregroundStyle(.black)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.amber, in: Capsule())
                                .position(x: frame.midX, y: frame.minY + 18)
                                .allowsHitTesting(false)
                        }
                        if pointSet || split != nil || model.camera.aeafLocked {
                            Button {
                                split = nil; focusPoint = nil; pointSet = false
                                model.camera.resetToAuto()
                                Feedback.selection()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .bold))
                                    Text("AUTO").font(Theme.mono(10, .bold))
                                }
                                .foregroundStyle(Theme.amber)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.black.opacity(0.55), in: Capsule())
                                .overlay(Capsule().stroke(Theme.amber.opacity(0.6), lineWidth: 1))
                                .padding(8)                              // a bigger target than it looks
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Back to automatic focus and exposure")
                            .position(x: frame.minX + 48, y: frame.minY + 24)
                            .disabled(model.captureBusy)
                            .transition(.opacity)
                        }
                        if prefs.panoMode {
                            PanoGuide(frame: frame)
                        }
                        if prefs.showMeter {
                            MatchNeedle(meter: model.camera.meter, manual: prefs.shutter > 0, simulated: model.camera.isSimulated)
                                .position(x: frame.maxX - 62, y: frame.minY + 24)
                                .allowsHitTesting(false)
                        }
                        if let p = model.exposing {
                            // A long exposure is running: keep still.
                            VStack(spacing: 10) {
                                ZStack {
                                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 4)
                                    Circle().trim(from: 0, to: p).stroke(Theme.amber, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                    Text("\(max(0, Int((model.exposingSeconds * (1 - p)).rounded(.up))))")
                                        .font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(Theme.amber)
                                        .contentTransition(.numericText(countsDown: true))
                                }
                                .frame(width: 92, height: 92)
                                Text("EXPOSING · HOLD STILL").font(Theme.mono(11, .bold)).foregroundStyle(Theme.amber)
                            }
                            .padding(18).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                            .animation(.linear(duration: 0.2), value: p)
                            .position(x: frame.midX, y: frame.midY)
                            .allowsHitTesting(false)
                        }
                        if let n = model.countdown {
                            Text("\(n)")
                                .font(.system(size: 96, weight: .bold, design: .monospaced)).foregroundStyle(Theme.amber)
                                .shadow(color: .black.opacity(0.6), radius: 8)
                                .contentTransition(.numericText(countsDown: true))
                                .animation(.snappy, value: n)
                                .position(x: frame.midX, y: frame.midY)
                                .allowsHitTesting(false)
                        }
                        Color.black.opacity(blink ? 1 : 0).allowsHitTesting(false)
                    }
                    .coordinateSpace(name: "viewfinder")
                    .animation(.snappy, value: prefs.aspect)
                }
            }
            .clipped()
            .onChange(of: model.shutterTick) {
                blink = true
                withAnimation(.easeOut(duration: 0.18).delay(0.05)) { blink = false }
            }
            .onChange(of: prefs.showLevel) { model.updateSensors() }
    }

    @ViewBuilder private var source: some View {
        switch model.camera.status {
        case .simulated:
            Image(uiImage: SimulatedScene.preview).resizable().scaledToFill()
                .scaleEffect(x: model.camera.position == .front ? -1 : 1, y: 1)
                .onTapGesture(count: 2) { Task { await model.camera.flip() } }
                .overlay(alignment: .topLeading) {
                    Text("SIMULATOR · TEST SCENE")
                        .font(Theme.mono(9, .semibold)).foregroundStyle(.white.opacity(0.7))
                        .padding(6).background(.black.opacity(0.4)).padding(8)
                }
        case .running:
            CameraPreview(session: model.camera.session, points: points, onTap: { layer, device in
                // A panorama's locked exposure or a long exposure's manual settings mustn't be reset by a tap.
                guard !model.captureBusy else { return }
                split = nil                                     // one finger: back to combined focus and exposure
                pointSet = true
                model.camera.focus(at: device)
                focusPoint = layer
                Task { try? await Task.sleep(for: .seconds(1.2)); focusPoint = nil }
            }, onDoubleTap: {
                guard !model.captureBusy else { return }
                pointSet = false; split = nil                   // the other camera starts on automatic
                Task { await model.camera.flip() }
            }, onLongPress: { layer, device in
                guard !model.captureBusy else { return }
                split = nil
                pointSet = true
                model.camera.lock(at: device)
                focusPoint = layer
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }, onTwoFingerTap: { mid in
                guard !model.captureBusy else { return }
                // Two markers either side of where the fingers landed: square focuses, sun meters. Drag either.
                let f = CGPoint(x: mid.x - 56, y: mid.y), e = CGPoint(x: mid.x + 56, y: mid.y)
                split = (f, e)
                pointSet = true
                if let d = points.devicePoint(for: f) { model.camera.setFocus(at: d) }
                if let d = points.devicePoint(for: e) { model.camera.setExposure(at: d) }
                Feedback.selection()
            })
        case .unauthorized:
            VStack(spacing: 12) {
                Text("Camera access is off").font(Theme.mono(14, .semibold))
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(Theme.mono(13))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
        case .failed:
            Text("Camera unavailable").font(Theme.mono(14)).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
        case .idle:
            Color.black
        }
    }

    /// Rect of the chosen aspect (portrait orientation) inside the 3:4 viewfinder.
    static func frameRect(in size: CGSize, aspect: AspectRatio) -> CGRect {
        let target = 1 / aspect.longOverShort   // width / height in portrait
        var w = size.width, h = size.height
        if w / h > target { w = h * target } else { h = w / target }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

private struct AspectMask: View {
    let frame: CGRect
    var body: some View {
        GeometryReader { geo in
            Path { p in
                // Overshoot the edges: a fractional viewfinder width otherwise leaves the last pixel column only
                // half covered, and the live preview shows through as a bright line. `.clipped()` trims the excess.
                p.addRect(CGRect(origin: .zero, size: geo.size).insetBy(dx: -4, dy: -4))
                p.addRect(frame)
            }
            .fill(Color.black.opacity(0.88), style: FillStyle(eoFill: true))
            Rectangle().path(in: frame).stroke(Color.white.opacity(0.25), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct GridLines: View {
    let frame: CGRect
    var body: some View {
        Path { p in
            for i in 1...2 {
                let x = frame.minX + frame.width * CGFloat(i) / 3
                let y = frame.minY + frame.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: frame.minY)); p.addLine(to: CGPoint(x: x, y: frame.maxY))
                p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
        .allowsHitTesting(false)
    }
}

private struct LevelLine: View {
    let tilt: Double
    var body: some View {
        let level = abs(tilt) < 1
        HStack(spacing: 0) {
            Rectangle().frame(width: 18, height: 1.5)
            Spacer().frame(width: 10)
            Rectangle().frame(width: 60, height: 1.5).rotationEffect(.degrees(level ? 0 : -tilt))
            Spacer().frame(width: 10)
            Rectangle().frame(width: 18, height: 1.5)
        }
        .foregroundStyle(level ? Theme.amber : Color.white.opacity(0.6))
        .opacity(abs(tilt) > 20 ? 0 : 1)
        .animation(.easeOut(duration: 0.1), value: level)
        .allowsHitTesting(false)
    }
}

extension Viewfinder {
    /// Dragging a split marker: follows the finger inside the viewfinder, and re-aims as it moves (throttled by
    /// the drag's own rate), so the picture responds while you drag.
    fileprivate func drag(_ size: CGSize, _ moved: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("viewfinder"))
            .onChanged { g in
                guard !model.captureBusy else { return }
                moved(CGPoint(x: min(max(g.location.x, 24), size.width - 24), y: min(max(g.location.y, 24), size.height - 24)))
            }
            .onEnded { _ in Feedback.selection() }
    }
}

/// A split marker: square for focus, circle with a sun for exposure.
private struct SplitMarker: View {
    enum Kind { case focus, exposure }
    let kind: Kind
    var body: some View {
        ZStack {
            switch kind {
            case .focus:
                RoundedRectangle(cornerRadius: 3).stroke(Theme.amber, lineWidth: 1.5).frame(width: 60, height: 60)
                Text("AF").font(Theme.mono(9, .bold)).foregroundStyle(Theme.amber).offset(y: -40)
            case .exposure:
                Circle().stroke(Color.yellow, lineWidth: 1.5).frame(width: 60, height: 60)
                Image(systemName: "sun.max.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.yellow)
                Text("AE").font(Theme.mono(9, .bold)).foregroundStyle(Color.yellow).offset(y: -40)
            }
        }
        .frame(width: 84, height: 84)           // a comfortable target to drag
        .contentShape(Rectangle())
        .shadow(color: .black.opacity(0.5), radius: 2)
        .accessibilityLabel(kind == .focus ? "Focus point, drag to move" : "Exposure point, drag to move")
    }
}

private struct FocusReticle: View {
    @State private var scale = 1.4
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(Theme.amber, lineWidth: 1.2)
            .frame(width: 64, height: 64)
            .scaleEffect(scale)
            .onAppear { withAnimation(.spring(duration: 0.3)) { scale = 1 } }
    }
}

/// A match-needle light meter, like an old SLR's: the shutter and ISO in use, and a needle for how far the exposure
/// is from what the meter reads as right. With a manual shutter the needle shows over or under exposure.
struct MatchNeedle: View {
    let meter: CameraController.Meter
    let manual: Bool
    let simulated: Bool

    var body: some View {
        let off = simulated || !meter.offset.isFinite ? 0 : Double(meter.offset)
        let clamped = min(2, max(-2, off))
        let good = abs(off) < 0.5
        VStack(alignment: .trailing, spacing: 4) {
            Text("\(Self.shutter(meter.shutter))  ISO \(meter.iso.isFinite ? String(Int(meter.iso.rounded())) : "—")")
                .font(Theme.mono(10, .bold)).foregroundStyle(Theme.amber)
            Canvas { ctx, size in
                let mid = size.width / 2, step = size.width / 4.4
                for i in -2...2 {
                    let x = mid + CGFloat(i) * step
                    var p = Path(); p.move(to: CGPoint(x: x, y: i == 0 ? 0 : 3)); p.addLine(to: CGPoint(x: x, y: 8))
                    ctx.stroke(p, with: .color(.white.opacity(i == 0 ? 0.9 : 0.45)), lineWidth: i == 0 ? 1.5 : 1)
                }
                ctx.draw(Text("−").font(Theme.mono(9, .bold)).foregroundColor(.white.opacity(0.6)), at: CGPoint(x: 4, y: 14))
                ctx.draw(Text("+").font(Theme.mono(9, .bold)).foregroundColor(.white.opacity(0.6)), at: CGPoint(x: size.width - 4, y: 14))
                let nx = mid + CGFloat(clamped) * step
                var n = Path(); n.move(to: CGPoint(x: nx - 4, y: 18)); n.addLine(to: CGPoint(x: nx + 4, y: 18)); n.addLine(to: CGPoint(x: nx, y: 10))
                ctx.fill(n, with: .color(good ? Theme.amber : Color(red: 1, green: 0.35, blue: 0.25)))
            }
            .frame(width: 96, height: 20)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.25), value: meter)
        .accessibilityLabel(manual && !good ? (off > 0 ? "Overexposed" : "Underexposed") : "Exposure \(Self.shutter(meter.shutter))")
    }

    static func shutter(_ s: Double) -> String {
        // While the camera is paused (or just restarting) the exposure reads as not-a-number: show a dash, never
        // convert it (Int(.nan) crashes).
        guard s.isFinite, s > 0 else { return "—" }
        if s >= 0.95 { return String(format: "%.0f\"", s.rounded()) }
        return "1/\(Int((1 / max(s, 1e-4)).rounded()))"
    }
}

/// Panorama help on the viewfinder: the last shot's right edge, faint, at the left so the next shot can overlap
/// it, and how many shots are in.
struct PanoGuide: View {
    @Environment(AppModel.self) private var model
    let frame: CGRect

    var body: some View {
        let n = model.pano?.scenes.count ?? 0
        ZStack {
            if let ghost = model.pano?.ghost {
                // The right third of the last shot, laid over the left third of the view.
                Image(uiImage: ghost).resizable().scaledToFill()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: -frame.width * 0.67)
                    .frame(width: frame.width * 0.33, height: frame.height, alignment: .leading)
                    .clipped()
                    .opacity(0.45)
                    .position(x: frame.minX + frame.width * 0.165, y: frame.midY)
                Rectangle().fill(Theme.amber).frame(width: 2, height: frame.height)
                    .position(x: frame.minX + frame.width * 0.33, y: frame.midY)
            }
            Text(n == 0 ? "PANO · FIRST SHOT LOCKS EXPOSURE" : "PANO \(n)/\(Panorama.maxFrames) · TURN RIGHT, LINE UP THE EDGE")
                .font(Theme.mono(10, .bold)).foregroundStyle(Theme.amber)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .position(x: frame.midX, y: frame.minY + 56)
            if model.pano?.capturing == true {
                ProgressView().tint(Theme.amber).position(x: frame.midX, y: frame.midY)
            }
        }
        .allowsHitTesting(false)
    }
}
