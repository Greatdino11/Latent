import SwiftUI

// MARK: - Stock strip

/// Horizontal row of film "canisters". The first one is Random; the last makes or adds a stock.
/// Long-press a stock for its options; swipe up on the row for the look drawer.
struct StockStrip: View {
    @Environment(AppModel.self) private var model
    var openLook: () -> Void = {}

    @State private var editing: CustomStock?
    @State private var editingIsNew = false
    @State private var managing = false
    @State private var adding = false
    @State private var pasting = false
    @State private var pasteCode = ""

    var body: some View {
        let prefs = model.prefs
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    StockChip(title: "RANDOM", subtitle: "\(randomCount) stocks", colors: nil, selected: prefs.isRandom)
                        .id(FilmStock.randomID)
                        .onTapGesture { select(FilmStock.randomID) }
                        .contextMenu {
                            Button { managing = true } label: { Label("Choose Random's stocks", systemImage: "dice") }
                        }
                    ForEach(prefs.visibleStocks) { stock in
                        StockChip(title: stock.name.uppercased(), subtitle: "ISO \(stock.iso)",
                                  colors: LUT.chart.map { LUT.preview($0, stock) },
                                  selected: prefs.selectedStockID == stock.id)
                            .id(stock.id)
                            .onTapGesture { select(stock.id) }
                            .contextMenu { menu(for: stock) }
                    }
                    AddStockChip()
                        .onTapGesture { Feedback.selection(); adding = true }
                }
                .padding(.horizontal, 16)
            }
            .onAppear { proxy.scrollTo(prefs.isRandom ? FilmStock.randomID : prefs.selectedStockID, anchor: .center) }
            .onChange(of: prefs.selectedStockID) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 18).onEnded { g in
                if g.translation.height < -36, abs(g.translation.height) > abs(g.translation.width) { openLook() }
            }
        )
        .confirmationDialog("Add a stock", isPresented: $adding) {
            Button("Make a new stock") { edit(CustomStock(), isNew: true) }
            Button("Paste a stock code") { pasteCode = ""; pasting = true }
            Button("Manage stocks") { managing = true }
        }
        .alert("Add stock from code", isPresented: $pasting) {
            TextField("LTN1-…", text: $pasteCode)
            Button("Add") {
                if let custom = StockCode.decode(pasteCode) {
                    model.prefs.save(custom)
                    model.prefs.selectedStockID = custom.id
                    model.show("Added \(custom.name)")
                } else {
                    model.show("That isn't a Latent stock code")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Paste a code someone shared with you (the whole message is fine).") }
        .sheet(item: $editing) { custom in
            NavigationStack {
                StockEditorView(custom: custom, isNew: editingIsNew)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } } }
            }
        }
        .sheet(isPresented: $managing) {
            NavigationStack {
                StockManagerView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { managing = false } } }
            }
        }
    }

    @ViewBuilder private func menu(for stock: FilmStock) -> some View {
        let prefs = model.prefs
        if let custom = prefs.customStocks.first(where: { $0.id == stock.id }) {
            Button { edit(custom, isNew: false) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
            if let code = StockCode.encode(custom) {
                ShareLink(item: "\(custom.name) — a Latent film stock. Paste in Latent (tap + at the end of the stocks):\n\(code)") {
                    Label("Share as code", systemImage: "square.and.arrow.up")
                }
            }
        } else {
            Button {
                var c = CustomStock(); c.baseID = stock.id; c.iso = stock.iso; c.name = "My \(stock.name)"
                edit(c, isNew: true)
            } label: { Label("Make my own version", systemImage: "plus.square.on.square") }
        }
        Button { prefs.toggleRandom(stock.id) } label: {
            prefs.randomPool.contains(stock.id)
                ? Label("Remove from Random", systemImage: "dice")
                : Label("Add to Random", systemImage: "dice.fill")
        }
        Button { prefs.toggleHidden(stock.id) } label: { Label("Hide from camera", systemImage: "eye.slash") }
        Button { managing = true } label: { Label("Manage stocks", systemImage: "list.bullet") }
    }

    private func edit(_ custom: CustomStock, isNew: Bool) {
        editingIsNew = isNew
        editing = custom
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

/// The last card in the stock row: make a stock or paste a code.
private struct AddStockChip: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.amber)
            Text("NEW").font(Theme.mono(10, .bold)).foregroundStyle(Theme.label)
        }
        .frame(width: 52, height: 53)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.dim, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .contentShape(Rectangle())
        .accessibilityLabel("Add a stock")
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
        let panoShots = model.pano?.scenes.count ?? 0
        HStack {
            if model.prefs.panoMode && panoShots > 0 {
                Button { model.cancelPanorama() } label: {
                    Text("CANCEL").font(Theme.mono(12, .bold)).foregroundStyle(Theme.label)
                        .frame(width: 76, height: 44).background(Capsule().fill(Theme.panel))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                RollThumb()
                    .onTapGesture { if model.exposing == nil { showRoll = true } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ShutterButton(enabled: model.camera.isReady && model.pano?.capturing != true, stop: model.exposing != nil) { model.capture() }
            if model.prefs.panoMode && panoShots > 0 {
                Button { model.finishPanorama() } label: {
                    Text("DONE").font(Theme.mono(13, .bold)).foregroundStyle(panoShots >= 2 ? .black : Theme.dim)
                        .frame(width: 76, height: 44).background(Capsule().fill(panoShots >= 2 ? Theme.amber : Theme.panel))
                }
                .buttonStyle(.plain)
                .disabled(panoShots < 2 || model.pano?.capturing == true)
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                LensPicker()
                    .disabled(model.captureBusy)
                    .opacity(model.captureBusy ? 0.4 : 1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: 84)
    }
}

struct ShutterButton: View {
    var enabled: Bool
    /// A long exposure is running: the button stops it.
    var stop = false
    var action: () -> Void
    @GestureState private var pressed = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.label, lineWidth: 3).frame(width: 78, height: 78)
            Circle().fill(Theme.amber).frame(width: 64, height: 64)
                .overlay(Circle().fill(.white.opacity(pressed ? 0.25 : 0)))
                .overlay { if stop { RoundedRectangle(cornerRadius: 4).fill(.black).frame(width: 22, height: 22) } }
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
        .accessibilityLabel(stop ? "Stop exposure" : "Take photo")
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
