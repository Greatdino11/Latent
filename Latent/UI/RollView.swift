import PhotosUI
import SwiftUI

/// The roll. Opens on the newest frame like the Camera app; swipe sideways between frames, swipe down for the grid.
/// All controls sit in a bottom bar that mirrors the camera's: the centre button (where the shutter is) goes back to shooting.
struct RollView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let openLatest: Bool
    @State private var selected: String?
    @State private var didOpen = false

    var body: some View {
        ZStack {
            Theme.body.ignoresSafeArea()
            if let id = selected {
                PhotoPager(selection: Binding(get: { id }, set: { selected = $0 }),
                           close: { withAnimation(.easeOut(duration: 0.2)) { selected = nil } },
                           exit: { dismiss() })
                    .transition(.opacity)
            } else {
                RollGrid(open: { id in withAnimation(.easeOut(duration: 0.2)) { selected = id } }, exit: { dismiss() })
                    .transition(.opacity)
            }
        }
        .statusBarHidden()
        .onAppear {
            guard !didOpen else { return }
            didOpen = true
            if openLatest { selected = model.roll.items.first?.id }
        }
    }
}

// MARK: - Bottom bar (mirrors the camera's control deck)

struct RollBottomBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    var center: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: center) {
                ZStack {
                    Circle().stroke(Theme.label, lineWidth: 3).frame(width: 78, height: 78)
                    Circle().fill(Theme.panel).frame(width: 64, height: 64)
                    Image(systemName: "camera.fill").font(.system(size: 22)).foregroundStyle(Theme.amber)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to camera")
            trailing.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 84)
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

struct RoundIcon: View {
    let systemName: String
    var tint: Color = Theme.label
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 52, height: 52)
            .background(Circle().fill(Theme.panel))
    }
}

// MARK: - Grid

private struct RollGrid: View {
    @Environment(AppModel.self) private var model
    var open: (String) -> Void
    var exit: () -> Void
    @State private var picks: [PhotosPickerItem] = []
    @State private var selecting = false
    @State private var chosen: Set<String> = []
    @State private var status: String?
    @State private var busy = false
    @State private var confirmDelete = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    private var chosenItems: [RollItem] { model.roll.items.filter { chosen.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selecting ? "\(chosen.count) SELECTED" : "ROLL").font(Theme.mono(14, .bold)).foregroundStyle(Theme.amber)
                Spacer()
                if selecting {
                    Button(chosen.count == model.roll.items.count ? "None" : "All") {
                        chosen = chosen.count == model.roll.items.count ? [] : Set(model.roll.items.map(\.id))
                    }
                    .font(Theme.mono(12, .semibold))
                } else {
                    Text("\(model.roll.items.count) frames").font(Theme.mono(12)).foregroundStyle(Theme.dim)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 44)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(model.roll.items) { item in
                        RollCell(item: item, mark: selecting ? chosen.contains(item.id) : nil)
                            .onTapGesture {
                                if selecting {
                                    if chosen.contains(item.id) { chosen.remove(item.id) } else { chosen.insert(item.id) }
                                    Feedback.selection()
                                } else {
                                    open(item.id)
                                }
                            }
                            .onLongPressGesture {
                                guard !selecting else { return }
                                selecting = true; chosen = [item.id]; Feedback.selection()
                            }
                    }
                }
            }
            .overlay {
                if model.roll.items.isEmpty {
                    ContentUnavailableView("No frames yet", systemImage: "film",
                                           description: Text("Take a photo, or import one with the button below."))
                }
            }

            if let line = status ?? model.importStatus {
                HStack(spacing: 8) {
                    if busy || model.developingCount > 0 { ProgressView().tint(Theme.amber) }
                    Text(line).font(Theme.mono(12)).foregroundStyle(Theme.amber)
                }
                .padding(.top, 8)
            }

            RollBottomBar {
                if selecting {
                    Button { selecting = false; chosen = [] } label: { RoundIcon(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Cancel selection")
                } else {
                    PhotosPicker(selection: $picks, maxSelectionCount: 20, matching: .images, preferredItemEncoding: .current) {
                        RoundIcon(systemName: "photo.badge.plus")
                    }
                    .accessibilityLabel("Import photos")
                }
            } center: {
                exit()
            } trailing: {
                if selecting {
                    selectionMenu
                } else {
                    Button { selecting = true } label: { RoundIcon(systemName: "checkmark.circle") }
                        .buttonStyle(.plain).accessibilityLabel("Select frames")
                }
            }
        }
        .onChange(of: picks) { _, new in
            guard !new.isEmpty else { return }
            picks = []
            Task { await model.importPhotos(new) }
        }
        .confirmationDialog("Delete \(chosen.count) frames and their negatives?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                for item in chosenItems { model.roll.delete(item) }
                chosen = []; selecting = false
            }
        } message: { Text("Copies already saved to Photos are kept.") }
    }

    private var selectionMenu: some View {
        Menu {
            Button { run("Saving") { try await model.saveToPhotos($0) } } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
            }
            ShareLink(items: chosenItems.map(\.url)) { Label("Share", systemImage: "square.and.arrow.up") }
            ShareLink(items: chosenItems.filter(\.hasNegative).flatMap { [$0.negativeURL, $0.recipeURL] }) {
                Label("Share negatives", systemImage: "film.stack")
            }
            Menu {
                ForEach(model.prefs.orderedStocks) { stock in
                    Button(stock.displayName) { run("Developing") { try await model.reprint($0, stock: stock) } }
                }
            } label: { Label("Re-develop as…", systemImage: "film") }
            Button { run("Reprinting") { try await model.reprint($0) } } label: {
                Label("Reprint with current settings", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
        } label: {
            RoundIcon(systemName: "ellipsis", tint: chosen.isEmpty ? Theme.dim : Theme.label)
        }
        .disabled(chosen.isEmpty || busy)
    }

    /// Runs an action over the selected frames one at a time, with progress.
    private func run(_ verb: String, _ action: @escaping (RollItem) async throws -> Any) {
        let items = chosenItems
        busy = true
        Task {
            var failed = 0
            for (i, item) in items.enumerated() {
                status = "\(verb) \(i + 1) of \(items.count)…"
                // Skip negative-less frames for re-developing.
                if verb != "Saving", !item.hasNegative { failed += 1; continue }
                do { _ = try await action(item) } catch { failed += 1 }
            }
            status = failed == 0 ? "Done (\(items.count))" : "Done, \(failed) skipped"
            busy = false
            selecting = false
            chosen = []
        }
    }
}

private struct RollCell: View {
    @Environment(AppModel.self) private var model
    let item: RollItem
    var mark: Bool?
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.1)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if let mark {
                    Image(systemName: mark ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(mark ? Theme.amber : .white, .black.opacity(0.4))
                        .padding(6)
                }
            }
            .opacity(mark == false ? 0.75 : 1)
            .contentShape(Rectangle())
            .task(id: item) { image = await model.roll.thumbnail(for: item) }
    }
}

// MARK: - Pager

private enum DevelopTool: String, CaseIterable { case film = "FILM", light = "LIGHT", lens = "LENS", frame = "FRAME" }

private struct PhotoPager: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String
    var close: () -> Void
    var exit: () -> Void

    @State private var tool: DevelopTool = .film
    @State private var developing = false
    @State private var dirty = false
    @State private var status: String?
    @State private var confirmDelete = false
    @State private var drag: CGFloat = 0
    @State private var zoomed = false

    // The edit being shown; loaded from the frame's recipe whenever the frame changes.
    @State private var stockID = ""
    @State private var strength = 1.0
    @State private var push = 0.0
    @State private var aspect: AspectRatio?
    @State private var dateStamp = false
    @State private var border: FrameStyle = .none
    @State private var leak = 0.0
    @State private var dust = false
    @State private var lens: PortraitLens?
    @State private var blur = 0.6
    @State private var focus = 0.8
    @State private var loadedFor = ""

    private var item: RollItem? { model.roll.item(id: selection) }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selection) {
                ForEach(model.roll.items) { item in
                    PagerImage(item: item, developing: developing && item.id == selection, zoomed: $zoomed)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: drag)
            .opacity(1 - Double(min(drag, 300)) / 600)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { g in
                        if !zoomed, g.translation.height > abs(g.translation.width) { drag = g.translation.height }
                    }
                    .onEnded { _ in
                        if drag > 110 { close() } else { withAnimation(.spring(duration: 0.25)) { drag = 0 } }
                    }
            )

            if let item {
                caption(item)
                if item.hasNegative {
                    tools(item)
                } else {
                    Text("Taken before negatives were kept, so it can't be re-developed.")
                        .font(.footnote).foregroundStyle(Theme.dim).padding(.horizontal).frame(height: 112)
                }
            }
            Text(status ?? " ").font(Theme.mono(11)).foregroundStyle(Theme.dim).padding(.top, 4).lineLimit(1)

            RollBottomBar {
                Button(action: close) { RoundIcon(systemName: "square.grid.2x2") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("All frames")
            } center: {
                exit()
            } trailing: {
                if let item {
                    Menu {
                        Button { save(item) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                        ShareLink(item: item.url) { Label("Share", systemImage: "square.and.arrow.up") }
                        if item.hasNegative {
                            ShareLink(items: [item.negativeURL, item.recipeURL]) {
                                Label("Share negative", systemImage: "film.stack")
                            }
                            Button { apply() } label: { Label("Reprint with current settings", systemImage: "arrow.clockwise") }
                        }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    } label: { RoundIcon(systemName: "ellipsis") }
                }
            }
        }
        .onChange(of: selection, initial: true) { load() }
        .confirmationDialog("Delete this frame and its negative?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
        } message: { Text("Copies already saved to Photos are kept.") }
    }

    // MARK: pieces

    private func caption(_ item: RollItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(item.stock?.displayName.uppercased() ?? item.stockID.uppercased())
                .font(Theme.mono(13, .bold)).foregroundStyle(Theme.amber)
            Spacer()
            if item.hasNegative {
                ForEach(DevelopTool.allCases.filter { $0 != .lens || item.hasDepth }, id: \.self) { t in
                    Button(t.rawValue) { withAnimation(.snappy) { tool = t } }
                        .font(Theme.mono(11, .bold))
                        .foregroundStyle(tool == t ? Theme.amber : Theme.dim)
                }
            } else {
                Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(Theme.mono(11)).foregroundStyle(Theme.dim)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func tools(_ item: RollItem) -> some View {
        Group {
            switch tool {
            case .film: filmTool
            case .light: lightTool
            case .frame: frameTool
            case .lens: lensTool
            }
        }
        .frame(height: 112)
        .disabled(false)
    }

    private var filmTool: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.prefs.orderedStocks) { stock in
                            StockChip(title: stock.name.uppercased(), subtitle: "ISO \(stock.iso)",
                                      colors: LUT.chart.map { LUT.preview($0, stock) },
                                      selected: stockID == stock.id)
                                .id(stock.id)
                                .onTapGesture {
                                    guard stock.id != stockID else { return }
                                    Feedback.selection()
                                    stockID = stock.id
                                    strength = model.prefs.strength(for: stock)
                                    apply()
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onAppear { proxy.scrollTo(stockID, anchor: .center) }
                .onChange(of: loadedFor) { proxy.scrollTo(stockID, anchor: .center) }
            }
            HStack(spacing: 10) {
                Text("LOOK").font(Theme.mono(10, .bold)).foregroundStyle(Theme.dim)
                Slider(value: $strength, in: 0...1, step: 0.05) { editing in if !editing { apply() } }
                Text("\(Int(strength * 100))%").font(Theme.mono(11, .semibold)).foregroundStyle(Theme.amber)
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 18)
        }
    }

    /// Portrait blur, for frames with a depth map: lens character, how much blur, and where focus sits.
    private var lensTool: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("OFF", on: lens == nil) { lens = nil; apply() }
                    ForEach(PortraitLens.allCases) { l in
                        chip(l.label.uppercased(), on: lens == l) { lens = l; apply() }
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack(spacing: 10) {
                Text("BLUR").font(Theme.mono(10, .bold)).foregroundStyle(Theme.dim).frame(width: 40, alignment: .leading)
                Slider(value: $blur, in: 0.1...1) { editing in if !editing, lens != nil { apply() } }
            }
            .padding(.horizontal, 18)
            HStack(spacing: 10) {
                Text("FOCUS").font(Theme.mono(10, .bold)).foregroundStyle(Theme.dim).frame(width: 40, alignment: .leading)
                Text("far").font(.caption2).foregroundStyle(Theme.dim)
                Slider(value: $focus, in: 0...1) { editing in if !editing, lens != nil { apply() } }
                Text("near").font(.caption2).foregroundStyle(Theme.dim)
                chip("AUTO", on: false) {
                    guard let item, let depth = try? Data(contentsOf: item.depthURL) else { return }
                    Task {
                        if let f = await Darkroom.shared.autoFocus(depth: depth) {
                            focus = f
                            if lens == nil { lens = model.prefs.portraitLens }
                            apply()
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
        }
        .disabled(false)
    }

    private var lightTool: some View {
        VStack(spacing: 4) {
            Text(push == 0 ? "DEVELOP NORMAL" : push > 0 ? "PUSH +\(String(format: "%.1f", push))" : "PULL \(String(format: "%.1f", push))")
                .font(Theme.mono(11, .bold)).foregroundStyle(push == 0 ? Theme.dim : Theme.amber)
            ExposureDial(value: $push).frame(height: 46)
            Text("Brighten or darken from the negative. Highlights hold up to about +5 stops.")
                .font(.caption2).foregroundStyle(Theme.dim)
        }
        .task(id: push) {
            // Develop once the dial has settled.
            guard loadedFor == selection else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, push != (model.roll.recipe(for: item!).pushPull ?? 0) else { return }
            apply()
        }
    }

    private var frameTool: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("FULL", on: aspect == nil) { aspect = nil; apply() }
                    ForEach(AspectRatio.allCases) { a in
                        chip(a.label, on: aspect == a) { aspect = a; apply() }
                    }
                }
                .padding(.horizontal, 16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(leak == 0 ? "LEAK" : leak < 0.75 ? "LEAK ·" : "LEAK ··", on: leak > 0) {
                        leak = leak == 0 ? 0.5 : leak < 0.75 ? 1 : 0; apply()
                    }
                    chip(dust ? "DUST ✓" : "DUST", on: dust) { dust.toggle(); apply() }
                    chip(dateStamp ? "DATE ✓" : "DATE", on: dateStamp) { dateStamp.toggle(); apply() }
                    ForEach(FrameStyle.allCases) { f in
                        chip(f == .none ? "NO BORDER" : "\(f.label.uppercased()) BORDER", on: border == f) { border = f; apply() }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Feedback.selection(); action()
        } label: {
            Text(title)
                .font(Theme.mono(11, .bold))
                .foregroundStyle(on ? Theme.amber : Theme.label)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Theme.amber : .clear, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }

    // MARK: actions

    private func load() {
        status = nil
        guard let item else { return }
        let r = model.roll.recipe(for: item)
        stockID = item.stockID
        strength = r.strength ?? 1
        push = r.pushPull ?? 0
        aspect = r.aspect
        dateStamp = r.dateStamp
        border = r.frame
        leak = r.lightLeak ?? 0
        dust = r.dust ?? false
        lens = r.portraitLens
        blur = r.blurAmount ?? model.prefs.blurAmount
        focus = r.focusDepth ?? 0.8
        if tool == .lens, !item.hasDepth { tool = .film }
        loadedFor = item.id
    }

    /// Re-develops the current frame with everything the tools show. If a develop is already running, the latest
    /// state is applied as soon as it finishes.
    private func apply() {
        guard let item else { return }
        if developing { dirty = true; return }
        developing = true
        dirty = false
        let stock = FilmStock.with(id: stockID) ?? item.stock
        let (s, p, a, d, b) = (strength, push, aspect, dateStamp, border)
        let (lk, du) = (leak, dust)
        let (ln, bl, fc) = (lens, blur, focus)
        Task {
            do {
                status = try await model.reprint(item, stock: stock) { o in
                    o.strength = s; o.pushPull = p; o.aspect = a; o.dateStamp = d; o.frame = b
                    o.lightLeak = lk > 0 ? lk : nil; o.dust = du ? true : nil
                    o.portraitLens = ln; o.blurAmount = bl; o.focusDepth = fc
                }
            } catch {
                status = error.localizedDescription
            }
            developing = false
            if dirty { apply() }
        }
    }

    private func save(_ item: RollItem) {
        Task {
            do { status = try await model.saveToPhotos(item) } catch { status = error.localizedDescription }
        }
    }

    private func deleteCurrent() {
        guard let item, let index = model.roll.items.firstIndex(where: { $0.id == item.id }) else { return }
        let items = model.roll.items
        let neighbour = index + 1 < items.count ? items[index + 1].id : (index > 0 ? items[index - 1].id : nil)
        model.roll.delete(item)
        if let neighbour { selection = neighbour } else { close() }
    }
}

private struct PagerImage: View {
    @Environment(AppModel.self) private var model
    let item: RollItem
    let developing: Bool
    @Binding var zoomed: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if image != nil {
                ZoomableImage(image: image, zoomed: $zoomed)
                    .blur(radius: developing ? 8 : 0)
                    .saturation(developing ? 0.2 : 1)
                    .animation(.easeInOut(duration: 0.5), value: developing)
            } else {
                ProgressView()
            }
            if developing {
                VStack(spacing: 6) {
                    ProgressView().tint(Theme.amber)
                    Text("Developing").font(Theme.mono(12, .semibold)).foregroundStyle(Theme.amber)
                }
                .padding(14).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item) {
            if let fresh = await model.roll.thumbnail(for: item, maxPixel: 2400) { image = fresh }
        }
    }
}
