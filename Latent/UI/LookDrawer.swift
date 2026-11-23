import SwiftUI

// MARK: - Shared controls

/// A toggle-like pill used across the look controls.
struct LookChip: View {
    let title: String
    let on: Bool
    var action: () -> Void

    var body: some View {
        Button {
            Feedback.selection(); action()
        } label: {
            Text(title)
                .font(Theme.mono(11, .bold))
                .lineLimit(1).fixedSize()
                .foregroundStyle(on ? Theme.amber : Theme.label)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Theme.amber : .clear, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }
}

/// A labelled slider row: name on the left, current value on the right.
struct LookSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    let label: (Double) -> String
    var onRelease: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.mono(10, .bold)).foregroundStyle(Theme.dim).frame(width: 58, alignment: .leading)
            Slider(value: $value, in: range, step: step) { editing in if !editing { onRelease() } }
            Text(label(value)).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.amber)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

enum LookLabels {
    static func grain(_ v: Double) -> String {
        switch v {
        case 0: "OFF"
        case ..<0.75: "FINE"
        case ..<1.25: "NORMAL"
        case ..<1.75: "HEAVY"
        default: "PUSHED"
        }
    }

    static func flare(_ v: Double) -> String {
        switch v {
        case ..<0.05: "OFF"
        case ..<0.45: "FAINT"
        case ..<0.85: "SUBTLE"
        case ..<1.15: "NORMAL"
        default: "STRONG"
        }
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

// MARK: - Look drawer

/// Everything that shapes how the next photos come out, in one thumb-height sheet on the camera.
/// Opened with LOOK on the viewfinder, by tapping an active-look chip, or by swiping up on the stocks.
struct LookDrawer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        let stock = prefs.isRandom ? nil : FilmStock.with(id: prefs.selectedStockID)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("LOOK").font(Theme.mono(15, .bold)).foregroundStyle(Theme.amber)
                    Text("for the next photos").font(Theme.mono(11)).foregroundStyle(Theme.dim)
                    Spacer()
                    Button("RESET") { reset() }
                        .font(Theme.mono(11, .bold)).foregroundStyle(isDefault ? Theme.dim : Theme.label)
                        .disabled(isDefault)
                }

                group("MODE", note: prefs.panoMode ? "PANO: take 2–5 shots turning on the spot, each overlapping the last by about a third, then tap DONE. Exposure locks after the first shot." : nil) {
                    chips {
                        LookChip(title: "PHOTO", on: !prefs.panoMode) { setPano(false) }
                        LookChip(title: "PANO", on: prefs.panoMode) { setPano(true) }
                    }
                }

                group("FILM") {
                    if let stock {
                        LookSlider(title: "STRENGTH", value: Binding(get: { prefs.strength(for: stock) },
                                                                    set: { prefs.stockStrength[stock.id] = $0 }),
                                   range: 0...1, label: LookLabels.percent)
                        Text("How strongly \(stock.displayName) is applied.").font(.caption2).foregroundStyle(Theme.dim)
                    }
                    LookSlider(title: "GRAIN", value: $prefs.grainAmount, range: 0...2, step: 0.25, label: LookLabels.grain)
                    LookSlider(title: "FLARE", value: $prefs.flareAmount, range: 0...1.5, step: 0.1, label: LookLabels.flare)
                    chips {
                        LookChip(title: "VINTAGE", on: !prefs.crisp) { prefs.crisp = false }
                        LookChip(title: "CRISP", on: prefs.crisp) { prefs.crisp = true }
                    }
                    chips {
                        LookChip(title: prefs.halation ? "HALATION ✓" : "HALATION", on: prefs.halation) { prefs.halation.toggle() }
                        LookChip(title: prefs.dust ? "DUST ✓" : "DUST", on: prefs.dust) { prefs.dust.toggle() }
                        LookChip(title: prefs.dateStamp ? "DATE ✓" : "DATE", on: prefs.dateStamp) { prefs.dateStamp.toggle() }
                    }
                }

                group("SHUTTER", note: prefs.shutter > 1
                      ? "Over 1 s, Latent stacks frames for the whole time. Prop the phone up or hold very still, and use the self-timer. TRAILS keeps moving lights as solid lines."
                      : prefs.shutter > 0 ? "A slow shutter blurs motion. In bright light it can only go so dark: watch the meter needle." : nil) {
                    chips {
                        ForEach(LongExposure.choices, id: \.self) { s in
                            LookChip(title: LongExposure.label(s), on: prefs.shutter == s) {
                                prefs.shutter = s
                                model.camera.setSlowShutter(s)
                            }
                        }
                    }
                    if prefs.shutter > 1 {
                        chips {
                            LookChip(title: prefs.trails ? "TRAILS ✓" : "TRAILS", on: prefs.trails) { prefs.trails.toggle() }
                        }
                    }
                }

                group("LAB", note: "Expired film fogs the blacks, fades the colour and shifts it a different way each frame. The scanner is the lab's: Frontier is punchy and warm, Noritsu flatter and truer.") {
                    LookSlider(title: "EXPIRED", value: $prefs.expired, range: 0...1, step: 0.05, label: { $0 < 0.01 ? "FRESH" : LookLabels.percent($0) })
                    chips {
                        LookChip(title: "PLAIN SCAN", on: prefs.scanner == nil) { prefs.scanner = nil }
                        ForEach(ScannerLook.allCases) { s in
                            LookChip(title: s.label.uppercased(), on: prefs.scanner == s) { prefs.scanner = s }
                        }
                    }
                }

                group("LIGHT LEAKS") {
                    chips {
                        LookChip(title: "OFF", on: prefs.lightLeak == 0) { prefs.lightLeak = 0 }
                        LookChip(title: "SUBTLE", on: prefs.lightLeak > 0 && prefs.lightLeak < 0.75) { prefs.lightLeak = 0.5 }
                        LookChip(title: "STRONG", on: prefs.lightLeak >= 0.75) { prefs.lightLeak = 1 }
                    }
                }

                group("BORDER") {
                    chips {
                        ForEach(FrameStyle.allCases) { f in
                            LookChip(title: f == .none ? "NONE" : f.label.uppercased(), on: prefs.frameStyle == f) { prefs.frameStyle = f }
                        }
                    }
                }

                group("PORTRAIT LENS", note: model.portrait ? nil : "Used when Portrait (the person icon) is on.") {
                    chips {
                        ForEach(PortraitLens.allCases) { l in
                            LookChip(title: l.label.uppercased(), on: prefs.portraitLens == l) { prefs.portraitLens = l }
                        }
                    }
                    LookSlider(title: "BLUR", value: $prefs.blurAmount, range: 0.1...1, label: LookLabels.percent)
                }

                group("RAW", note: prefs.zeroProcess
                      ? "ZERO: one frame straight off the sensor, no Apple processing. Real sensor grain, softer and truer; 12MP, noisier in low light, highlights clip sooner."
                      : "48MP uses the 1× camera: about 75 MB a photo and slower to develop. ZERO skips Apple's processing entirely.") {
                    chips {
                        LookChip(title: "12MP", on: !prefs.highResolution && !prefs.zeroProcess) { setCapture(highRes: false, zero: false) }
                        LookChip(title: "48MP", on: prefs.highResolution && !prefs.zeroProcess) { setCapture(highRes: true, zero: false) }
                        LookChip(title: "ZERO", on: prefs.zeroProcess) { setCapture(highRes: false, zero: true) }
                    }
                }

                Text("To change a photo you've already taken, open it in the roll.")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.body)
        .presentationCornerRadius(22)
        .preferredColorScheme(.dark)
    }

    private func group<Content: View>(_ title: String, note: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.mono(10, .bold)).foregroundStyle(Theme.dim)
            content()
            if let note { Text(note).font(.caption2).foregroundStyle(Theme.dim) }
        }
    }

    private func chips<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { content() } }
    }

    private func setHighResolution(_ on: Bool) {
        guard model.prefs.highResolution != on else { return }
        model.prefs.highResolution = on
        model.camera.setHighResolution(on)
    }

    private func setPano(_ on: Bool) {
        guard model.prefs.panoMode != on else { return }
        if on, model.portrait { model.togglePortrait() }          // a panorama is a plain capture
        if !on { model.cancelPanorama() }
        model.prefs.panoMode = on
    }

    /// 12MP, 48MP and ZERO are one choice: ZERO (single-frame Bayer RAW) is always 12MP.
    private func setCapture(highRes: Bool, zero: Bool) {
        if model.prefs.zeroProcess != zero {
            model.prefs.zeroProcess = zero
            model.camera.setZero(zero)
        }
        setHighResolution(highRes)
    }

    private var isDefault: Bool { ActiveLook.items(model).isEmpty }

    private func reset() {
        let p = model.prefs
        p.grainAmount = 1; p.flareAmount = 0.6; p.halation = true; p.dust = false; p.dateStamp = false
        if p.panoMode { model.cancelPanorama(); p.panoMode = false }
        p.lightLeak = 0; p.frameStyle = .none; p.blurAmount = 0.6; p.expired = 0; p.scanner = nil; p.crisp = false
        if !p.isRandom { p.stockStrength[p.selectedStockID] = nil }
        if p.highResolution || p.zeroProcess { setCapture(highRes: false, zero: false) }
        if p.shutter > 0 { p.shutter = 0; model.camera.setSlowShutter(0) }
    }
}

// MARK: - Active look

/// What's set differently from a plain photo, as short labels for the viewfinder.
@MainActor
enum ActiveLook {
    static func items(_ model: AppModel) -> [String] {
        let p = model.prefs
        var out: [String] = []
        if p.panoMode { out.append("PANO") }
        if model.portrait { out.append("PORTRAIT · \(p.portraitLens.label.uppercased())") }
        if !p.isRandom, let s = FilmStock.with(id: p.selectedStockID), p.strength(for: s) < 0.995 {
            out.append("STRENGTH \(LookLabels.percent(p.strength(for: s)))")
        }
        if p.grainAmount != 1 { out.append(p.grainAmount == 0 ? "NO GRAIN" : "\(LookLabels.grain(p.grainAmount)) GRAIN") }
        if !p.halation { out.append("NO HALATION") }
        if p.flareAmount < 0.05 { out.append("NO FLARE") } else if p.flareAmount < 0.45 || p.flareAmount >= 0.85 {
            out.append("\(LookLabels.flare(p.flareAmount)) FLARE")
        }
        if p.lightLeak > 0 { out.append(p.lightLeak < 0.75 ? "LEAKS" : "STRONG LEAKS") }
        if p.dust { out.append("DUST") }
        if p.crisp { out.append("CRISP") }
        if p.expired > 0.01 { out.append("EXPIRED \(LookLabels.percent(p.expired))") }
        if let s = p.scanner { out.append(s.label.uppercased()) }
        switch p.frameStyle {
        case .none: break
        case .film: out.append("35MM")
        case .white, .black: out.append("\(p.frameStyle.label.uppercased()) BORDER")
        }
        if p.dateStamp { out.append("DATE") }
        if p.shutter > 0 { out.append(LongExposure.label(p.shutter) + (p.shutter > 1 && p.trails ? " TRAILS" : "")) }
        if p.zeroProcess { out.append("ZERO") } else if p.highResolution { out.append("48MP") }
        return out
    }
}

/// The row along the bottom of the viewfinder: what's on, and the LOOK button that opens the drawer.
struct ActiveLookBar: View {
    @Environment(AppModel.self) private var model
    var open: () -> Void

    var body: some View {
        let items = ActiveLook.items(model)
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.self) { label in
                        Text(label)
                            .font(Theme.mono(10, .bold)).foregroundStyle(Theme.amber)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.black.opacity(0.6), in: Capsule())
                    }
                }
                .padding(.leading, 10)
            }
            .onTapGesture { open() }
            Button(action: open) {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .bold))
                    Text("LOOK").font(Theme.mono(11, .bold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Theme.amber, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .accessibilityLabel("Look settings")
        }
        .animation(.snappy, value: items)
    }
}
