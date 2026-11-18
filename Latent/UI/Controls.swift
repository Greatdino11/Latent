import SwiftUI

// MARK: - Stock strip

/// Horizontal row of film "canisters". The first one is Random.
struct StockStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let prefs = model.prefs
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    StockChip(title: "RANDOM", subtitle: "\(randomCount) stocks", colors: nil, selected: prefs.isRandom)
                        .id(FilmStock.randomID)
                        .onTapGesture { select(FilmStock.randomID) }
                    ForEach(prefs.visibleStocks) { stock in
                        StockChip(title: stock.name.uppercased(), subtitle: "ISO \(stock.iso)",
                                  colors: LUT.chart.map { LUT.preview($0, stock) },
                                  selected: prefs.selectedStockID == stock.id)
                            .id(stock.id)
                            .onTapGesture { select(stock.id) }
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear { proxy.scrollTo(prefs.isRandom ? FilmStock.randomID : prefs.selectedStockID, anchor: .center) }
            .onChange(of: prefs.selectedStockID) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private var randomCount: Int {
        let prefs = model.prefs
        let n = prefs.visibleStocks.filter { prefs.randomPool.isEmpty || prefs.randomPool.contains($0.id) }.count
        return n == 0 ? prefs.visibleStocks.count : n
    }

    private func select(_ id: String) {
        Feedback.selection()
        model.prefs.selectedStockID = id
    }
}

struct StockChip: View {
    let title: String
    let subtitle: String
    let colors: [RGB]?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                if let colors {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
                        Rectangle().fill(Color(red: c.x, green: c.y, blue: c.z))
                    }
                } else {
                    LinearGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple],
                                   startPoint: .leading, endPoint: .trailing)
                        .overlay(Image(systemName: "dice.fill").font(.system(size: 9)).foregroundStyle(.white))
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            Text(title).font(Theme.mono(12, .bold)).foregroundStyle(selected ? Theme.amber : Theme.label)
            Text(subtitle).font(Theme.mono(9)).foregroundStyle(Theme.dim)
        }
        .frame(width: 84, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.amber : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
    }
}

// MARK: - Exposure dial

/// A ruler you slide sideways: ±2 EV in third stops. Double-tap resets.
struct ExposureDial: View {
    @Environment(AppModel.self) private var model
    @Binding var value: Double
    private var turn: Angle { model.orientation.angle }
    @State private var dragStart: Double?
    private let spacing: CGFloat = 15
    private let steps = 6   // thirds each side

    var body: some View {
        GeometryReader { geo in
            let mid = geo.size.width / 2
            ZStack {
                Canvas { ctx, size in
                    for i in -steps...steps {
                        let x = mid + (CGFloat(i) - CGFloat(value * 3)) * spacing
                        let major = i % 3 == 0
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: major ? 8 : 14))
                        p.addLine(to: CGPoint(x: x, y: size.height - 18))
                        ctx.stroke(p, with: .color(i == 0 ? Theme.amber : Color.white.opacity(major ? 0.7 : 0.35)), lineWidth: major ? 1.5 : 1)
                        if major {
                            let label = i == 0 ? "0" : String(format: "%+d", i / 3)
                            ctx.draw(Text(label).font(Theme.mono(9)).foregroundColor(Theme.dim), at: CGPoint(x: x, y: size.height - 7))
                        }
                    }
                    var needle = Path()
                    needle.move(to: CGPoint(x: mid - 5, y: 0)); needle.addLine(to: CGPoint(x: mid + 5, y: 0)); needle.addLine(to: CGPoint(x: mid, y: 7))
                    ctx.fill(needle, with: .color(Theme.amber))
                }
                HStack {
                    Text("EV").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.dim)
                    Spacer()
                    Text(value == 0 ? " 0.0" : String(format: "%+.1f", value))
                        .rotationEffect(turn)
                        .animation(.snappy, value: turn)
                        .font(Theme.mono(12, .semibold))
                        .foregroundStyle(value == 0 ? Theme.dim : Theme.amber)
                        .monospacedDigit()
                }
                .padding(.horizontal, 20)
                .offset(y: -6)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { g in
                        let start = dragStart ?? value
                        if dragStart == nil { dragStart = value }
                        let raw = start - Double(g.translation.width / spacing) / 3
                        let stepped = min(2, max(-2, (raw * 3).rounded() / 3))
                        if stepped != value {
                            value = stepped
                            Feedback.selection()
                        }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { withAnimation(.snappy) { value = 0 } }
        }
    }
}

// MARK: - Control deck (roll · shutter · lenses)

struct ControlDeck: View {
    @Environment(AppModel.self) private var model
    @Binding var showRoll: Bool

    var body: some View {
        HStack {
            RollThumb()
                .onTapGesture { showRoll = true }
                .frame(maxWidth: .infinity, alignment: .leading)
            ShutterButton(enabled: model.camera.isReady) { model.capture() }
            LensPicker()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 84)
    }
}

struct ShutterButton: View {
    var enabled: Bool
    var action: () -> Void
    @GestureState private var pressed = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.label, lineWidth: 3).frame(width: 78, height: 78)
            Circle().fill(Theme.amber).frame(width: 64, height: 64)
                .overlay(Circle().fill(.white.opacity(pressed ? 0.25 : 0)))
                .scaleEffect(pressed ? 0.9 : 1)
        }
        .opacity(enabled ? 1 : 0.4)
        .animation(.spring(duration: 0.15), value: pressed)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressed) { _, s, _ in s = true }
                .onEnded { _ in if enabled { action() } }
        )
        .accessibilityLabel("Take photo")
        .accessibilityAddTraits(.isButton)
    }
}

struct LensPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.camera.lenses) { lens in
                let selected = lens.id == model.camera.selectedLens
                Button { model.camera.select(lens: lens) } label: {
                    Text(selected ? "\(lens.label)×" : lens.label)
                        .font(Theme.mono(selected ? 12 : 11, .bold))
                        .foregroundStyle(selected ? Theme.amber : Theme.label)
                        .rotationEffect(model.orientation.angle)
                        .frame(width: selected ? 38 : 32, height: selected ? 38 : 32)
                        .background(Circle().fill(Theme.panel))
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy, value: model.camera.selectedLens)
        .animation(.snappy, value: model.orientation.angle)
    }
}

/// Last frame of the roll. New frames "develop" in: they fade up from black, blurred and colourless.
struct RollThumb: View {
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @State private var progress: Double = 1

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Theme.panel)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .saturation(progress)
                    .brightness(-(1 - progress) * 0.7)
                    .blur(radius: (1 - progress) * 6)
                    .opacity(0.25 + 0.75 * progress)
            } else {
                Image(systemName: "film").foregroundStyle(Theme.dim)
            }
            if model.developingCount > 0 {
                DevelopingBadge()
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .rotationEffect(model.orientation.angle)
        .animation(.snappy, value: model.orientation.angle)
        .task(id: model.roll.items.first) {
            guard let first = model.roll.items.first else { image = nil; return }
            let fresh = first.id == model.lastDeveloped?.id
            let thumb = await model.roll.thumbnail(for: first, maxPixel: 200)
            if fresh {
                progress = 0
                image = thumb
                withAnimation(.easeOut(duration: 2.4)) { progress = 1 }
            } else {
                image = thumb
            }
        }
    }
}

private struct DevelopingBadge: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 3) {
                Circle().fill(Theme.amber).frame(width: 7, height: 7).opacity(pulse ? 1 : 0.25)
                Text("DEV").font(Theme.mono(9, .bold)).foregroundStyle(Theme.amber)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { pulse = true } }
    }
}
