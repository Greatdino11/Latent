import SwiftUI

/// 3:4 live view with aspect mask, grid, level and focus reticle. Never shows the film look.
struct Viewfinder: View {
    @Environment(AppModel.self) private var model
    @State private var focusPoint: CGPoint?
    @State private var blink = false

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
                        if model.portrait {
                            Text("PORTRAIT · \(prefs.portraitLens.label.uppercased())")
                                .font(Theme.mono(10, .bold)).foregroundStyle(Theme.amber)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                                .position(x: frame.midX, y: frame.maxY - 18)
                                .allowsHitTesting(false)
                        }
                        if let p = focusPoint { FocusReticle().position(p).allowsHitTesting(false) }
                        Color.black.opacity(blink ? 1 : 0).allowsHitTesting(false)
                    }
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
            CameraPreview(session: model.camera.session, onTap: { layer, device in
                model.camera.focus(at: device)
                focusPoint = layer
                Task { try? await Task.sleep(for: .seconds(1.2)); focusPoint = nil }
            }, onDoubleTap: {
                Task { await model.camera.flip() }
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
                p.addRect(CGRect(origin: .zero, size: geo.size))
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
