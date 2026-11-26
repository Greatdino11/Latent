import ImageIO
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
                    .onDisappear { model.flushPhotos() }       // closing the viewer: one Photos update per edited frame
                    .transition(.opacity)
            } else {
                RollGrid(open: { id in withAnimation(.easeOut(duration: 0.2)) { selected = id } }, exit: { dismiss() })
                    .transition(.opacity)
            }
        }
        .statusBarHidden()
        .overlay(alignment: .top) {
            // Notices (Photos updates, frames removed with Photos) show here too, not only behind the roll.
            if let notice = model.notice {
                Text(notice)
                    .font(Theme.mono(12, .semibold)).foregroundStyle(Theme.amber)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.black.opacity(0.85), in: Capsule())
                    .padding(.top, 8).padding(.horizontal, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy, value: model.notice)
        .onChange(of: model.roll.items) { _, items in
            // The frame on screen left the roll (e.g. its photo was deleted in Photos): back to the grid.
            if let id = selected, !items.contains(where: { $0.id == id }) { withAnimation { selected = nil } }
        }
        .onAppear {
            guard !didOpen else { return }
            didOpen = true
            if openLatest, !ProcessInfo.processInfo.arguments.contains("-selectTwo") { selected = model.roll.items.first?.id }
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
    @State private var sheetURL: URL?
    @State private var doublePair: [RollItem]?
    @State private var naming: String?
    @State private var nameText = ""

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
                LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(RollDay.group(model.roll.items)) { day in
                        Section {
                            ForEach(day.items) { item in cell(item) }
                        } header: {
                            dayHeader(day)
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
            .alert("Name this day", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("e.g. Park walk", text: $nameText)
                Button("Save") {
                    if let key = naming { model.prefs.dayNames[key] = nameText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : nameText }
                }
                Button("Cancel", role: .cancel) {}
            }

            if selecting { actionBar }

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
                    Button { confirmDelete = true } label: {
                        RoundIcon(systemName: "trash", tint: chosen.isEmpty ? Theme.dim : .red)
                    }
                    .buttonStyle(.plain).disabled(chosen.isEmpty || busy).accessibilityLabel("Delete selected")
                } else {
                    Button { selecting = true } label: { RoundIcon(systemName: "checkmark.circle") }
                        .buttonStyle(.plain).accessibilityLabel("Select frames")
                }
            }
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-selectTwo") {
                selecting = true; chosen = Set(model.roll.items.prefix(2).map(\.id))
                if ProcessInfo.processInfo.arguments.contains("-openDouble") { makeDoubleExposure() }
            }
            #endif
        }
        .onChange(of: picks) { _, new in
            guard !new.isEmpty else { return }
            picks = []
            Task { await model.importPhotos(new) }
        }
        .sheet(isPresented: Binding(get: { sheetURL != nil }, set: { if !$0 { sheetURL = nil } })) {
            if let url = sheetURL { ContactSheetView(url: url) }
        }
        .sheet(isPresented: Binding(get: { doublePair != nil }, set: { if !$0 { doublePair = nil } })) {
            if let pair = doublePair {
                DoubleExposureView(base: pair[0], top: pair[1]) { item in
                    doublePair = nil; selecting = false; chosen = []
                    open(item.id)
                }
            }
        }
        .confirmationDialog("Delete \(chosen.count == 1 ? "1 frame" : "\(chosen.count) frames") and \(chosen.count == 1 ? "its negative" : "their negatives")?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            let linked = chosenItems.filter { model.roll.photosID(for: $0) != nil }.count
            if linked > 0 {
                Button("Delete from Latent and Photos", role: .destructive) {
                    let items = chosenItems
                    busy = true; status = "Deleting…"
                    Task {
                        status = await model.deleteEverywhere(items)
                        busy = false; chosen = []; selecting = false
                    }
                }
            }
            Button(linked > 0 ? "Delete from Latent only" : "Delete", role: .destructive) {
                for item in chosenItems { model.roll.delete(item) }
                chosen = []; selecting = false
            }
        } message: {
            let linked = chosenItems.filter { model.roll.photosID(for: $0) != nil }.count
            if linked > 0 {
                Text("\(linked) of these \(linked == 1 ? "is" : "are") saved in Photos. Deleting from Photos too moves \(linked == 1 ? "it" : "them") to Recently Deleted there. Negatives can't be recovered.")
            } else {
                Text("Negatives can't be recovered.")
            }
        }
    }

    /// What you can do with the selected frames, all in view.
    private var actionBar: some View {
        let none = chosen.isEmpty || busy
        let pairReady = chosenItems.count == 2 && chosenItems.allSatisfy(\.hasNegative)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                action("Save", "square.and.arrow.down", enabled: !none) { run("Saving") { try await model.saveToPhotos($0) } }
                ShareLink(items: chosenItems.map(\.url)) { actionLabel("Share", "square.and.arrow.up", enabled: !none) }
                    .disabled(none)
                Menu {
                    ForEach(model.prefs.orderedStocks) { stock in
                        Button(stock.displayName) { run("Developing") { try await model.reprint($0, stock: stock, syncPhotos: false) } }
                    }
                } label: { actionLabel("Develop as", "film", enabled: !none) }
                    .disabled(none)
                action("Contact sheet", "squares.below.rectangle", enabled: !none) { makeContactSheet() }
                action("Double", "circle.circle", enabled: pairReady && !busy) { makeDoubleExposure() }
                ShareLink(items: chosenItems.filter(\.hasNegative).flatMap { [$0.negativeURL, $0.recipeURL] }) {
                    actionLabel("Negatives", "film.stack", enabled: !none)
                }
                .disabled(none)
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 8)
        .overlay(alignment: .bottom) {
            if chosenItems.count == 1 || chosenItems.count > 2 {
                Text("Double exposure needs exactly two frames").font(Theme.mono(9)).foregroundStyle(Theme.dim)
                    .offset(y: 14)
            }
        }
        .padding(.bottom, 12)
    }

    private func action(_ title: String, _ icon: String, enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button { Feedback.selection(); run() } label: { actionLabel(title, icon, enabled: enabled) }
            .buttonStyle(.plain).disabled(!enabled)
    }

    private func actionLabel(_ title: String, _ icon: String, enabled: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium))
            Text(title.uppercased()).font(Theme.mono(9, .bold)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(enabled ? Theme.label : Theme.dim.opacity(0.6))
        .frame(minWidth: 64).frame(height: 58)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    private func cell(_ item: RollItem) -> some View {
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

    /// A day on the roll: its name (tap to set one) or date, how many frames, and a contact sheet of just that day.
    private func dayHeader(_ day: RollDay) -> some View {
        let name = model.prefs.dayNames[day.key]
        let ids = Set(day.items.map(\.id))
        return HStack(alignment: .center, spacing: 10) {
            Button {
                nameText = name ?? ""; naming = day.key
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name?.uppercased() ?? day.title).font(Theme.mono(12, .bold)).foregroundStyle(Theme.label).lineLimit(1)
                    Text((name != nil ? day.title + " · " : "") + "\(day.items.count) frame\(day.items.count == 1 ? "" : "s")")
                        .font(Theme.mono(9)).foregroundStyle(Theme.dim)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Name this day")
            Spacer()
            if selecting {
                Button(ids.isSubset(of: chosen) ? "NONE" : "ALL") {
                    if ids.isSubset(of: chosen) { chosen.subtract(ids) } else { chosen.formUnion(ids) }
                    Feedback.selection()
                }
                .font(Theme.mono(11, .bold)).foregroundStyle(Theme.amber)
            } else {
                Button { makeContactSheet(day.items, name: name) } label: {
                    Image(systemName: "squares.below.rectangle").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.amber)
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.plain).disabled(busy)
                .accessibilityLabel("Contact sheet of this day")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.body.opacity(0.96))
    }

    private func makeContactSheet() { makeContactSheet(chosenItems, name: nil) }

    private func makeContactSheet(_ items: [RollItem], name: String?) {
        busy = true
        Task {
            do {
                sheetURL = try await model.contactSheet(items, name: name) { i, n in status = "Printing contact sheet \(i) of \(n)…" }
                status = items.count > ContactSheet.maxFrames ? "Contact sheet of the first \(ContactSheet.maxFrames) frames" : nil
            } catch { status = error.localizedDescription }
            busy = false
        }
    }

    private func makeDoubleExposure() {
        // Starts with the earlier-taken frame as the base; the sheet can swap them.
        let pair = chosenItems.sorted { $0.date < $1.date }
        guard pair.count == 2 else { return }
        doublePair = pair
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
            model.flushPhotos(Set(items.map(\.id)))          // one Photos change for the whole batch
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

private enum DevelopTool: String, CaseIterable { case film = "FILM", light = "LIGHT", texture = "TEXTURE", lab = "LAB", lens = "LENS", frame = "FRAME" }

private struct PhotoPager: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String
    var close: () -> Void
    var exit: () -> Void

    @State private var comparing = false
    @State private var original: UIImage?
    @State private var originalFor: String?
    @State private var tool: DevelopTool = ProcessInfo.processInfo.arguments.contains("-frameTool") ? .frame
        : ProcessInfo.processInfo.arguments.contains("-textureTool") ? .texture : .film
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
    @State private var cropShift = 0.0
    /// The negative's size, to know which way the crop can slide.
    @State private var negativeSize: CGSize?
    @State private var dateStamp = false
    @State private var border: FrameStyle = .none
    @State private var leak = 0.0
    @State private var dust = false
    @State private var lens: PortraitLens?
    @State private var blur = 0.6
    @State private var focus = 0.8
    @State private var grain = 1.0
    @State private var socialURL: URL?
    @State private var halation = true
    @State private var flare = 0.6
    @State private var expired = 0.0
    @State private var crisp = false
    @State private var scanner: ScannerLook?
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
            .overlay {
                if comparing, let original {
                    ZStack(alignment: .top) {
                        Theme.body
                        Image(uiImage: original).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text("ORIGINAL").font(Theme.mono(11, .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.amber, in: Capsule()).padding(.top, 10)
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item?.hasNegative == true { compareButton.padding(12) }
            }
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
                        Menu {
                            ForEach(SocialPrint.Format.allCases) { f in
                                Button(f.label) { shareSocial(item, f) }
                            }
                        } label: { Label("Share for Instagram", systemImage: "rectangle.portrait.on.rectangle.portrait") }
                        if item.hasNegative {
                            ShareLink(items: [item.negativeURL, item.recipeURL]) {
                                Label("Share negative", systemImage: "film.stack")
                            }
                        }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    } label: { RoundIcon(systemName: "ellipsis") }
                }
            }
        }
        .onChange(of: selection, initial: true) { old, new in
            // A push/pull still settling on the frame being left would be lost: develop it now. Then the frame
            // just left gets its single Photos update.
            if old != new { commitPendingPush(for: old); model.flushPhotos([old]) }
            load()
        }
        .sheet(isPresented: Binding(get: { socialURL != nil }, set: { if !$0 { socialURL = nil } })) {
            if let socialURL { ShareSheet(items: [socialURL]).presentationDetents([.medium, .large]) }
        }
        .confirmationDialog("Delete this frame and its negative?", isPresented: $confirmDelete, titleVisibility: .visible) {
            let linked = item.map { model.roll.photosID(for: $0) != nil } ?? false
            if linked {
                Button("Delete from Latent and Photos", role: .destructive) { deleteCurrent(everywhere: true) }
            }
            Button(linked ? "Delete from Latent only" : "Delete", role: .destructive) { deleteCurrent(everywhere: false) }
        } message: {
            if let item, model.roll.photosID(for: item) != nil {
                Text("It's saved in Photos. Deleting from Photos too moves it to Recently Deleted there. Negatives can't be recovered.")
            } else {
                Text("Negatives can't be recovered.")
            }
        }
    }

    // MARK: pieces

    /// Hold to see the frame before the film: the neutral print of its negative.
    private var compareButton: some View {
        Image(systemName: "circle.lefthalf.filled")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(comparing ? .black : Theme.label)
            .frame(width: 40, height: 40)
            .background(Circle().fill(comparing ? Theme.amber : Color.black.opacity(0.55)))
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !comparing else { return }
                    comparing = true
                    Feedback.selection()
                    loadOriginal()
                }
                .onEnded { _ in comparing = false })
            .accessibilityLabel("Hold to compare with the original")
    }

    private func loadOriginal() {
        guard let item, originalFor != item.url.lastPathComponent + "\(item.stamp)" else { return }
        let key = item.url.lastPathComponent + "\(item.stamp)"
        let recipe = model.roll.recipe(for: item)
        guard let negative = try? Data(contentsOf: item.negativeURL) else { return }
        original = nil
        Task {
            if let cg = try? await Darkroom.shared.original(negative: negative, recipe: recipe) {
                original = UIImage(cgImage: cg); originalFor = key
            }
        }
    }

    private func caption(_ item: RollItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(model.stock(for: item)?.displayName.uppercased() ?? "STOCK DELETED")
                .font(Theme.mono(13, .bold)).foregroundStyle(Theme.amber)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 8)
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
            case .texture: textureTool
            case .lab: labTool
            case .frame: frameTool
            case .lens: lensTool
            }
        }
        .frame(height: tool == .frame ? 150 : 112)
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

    /// Grain, glow and flare for this frame (new photos take theirs from the look drawer).
    private var textureTool: some View {
        VStack(spacing: 10) {
            LookSlider(title: "GRAIN", value: $grain, range: 0...2, step: 0.25, label: LookLabels.grain) { apply() }
            LookSlider(title: "FLARE", value: $flare, range: 0...1.5, step: 0.1, label: LookLabels.flare) { apply() }
            HStack {
                LookChip(title: halation ? "HALATION ✓" : "HALATION", on: halation) { halation.toggle(); apply() }
                LookChip(title: "VINTAGE", on: !crisp) { crisp = false; apply() }
                LookChip(title: "CRISP", on: crisp) { crisp = true; apply() }
                Spacer()
            }
        }
        .padding(.horizontal, 18)
    }

    /// Expired film and the lab scanner, for this frame.
    private var labTool: some View {
        VStack(spacing: 12) {
            LookSlider(title: "EXPIRED", value: $expired, range: 0...1, step: 0.05,
                       label: { $0 < 0.01 ? "FRESH" : LookLabels.percent($0) }) { apply() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("PLAIN SCAN", on: scanner == nil) { scanner = nil; apply() }
                    ForEach(ScannerLook.allCases) { s in
                        chip(s.label.uppercased(), on: scanner == s) { scanner = s; apply() }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
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
            guard !Task.isCancelled, let item, push != (model.roll.recipe(for: item).pushPull ?? 0) else { return }
            apply()
        }
    }

    private var frameTool: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("FULL", on: aspect == nil) { aspect = nil; cropShift = 0; apply() }
                    ForEach(AspectRatio.allCases) { a in
                        chip(a.label, on: aspect == a) { aspect = a; apply() }
                    }
                }
                .padding(.horizontal, 16)
            }
            if let size = negativeSize, let axis = FilmPipeline.slideAxis(width: size.width, height: size.height, aspect: aspect) {
                // Slide the frame along its one free direction (the slider runs top→bottom or left→right).
                HStack(spacing: 10) {
                    Image(systemName: axis == .vertical ? "arrow.up.and.down" : "arrow.left.and.right")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.dim).frame(width: 40, alignment: .leading)
                    Text(axis == .vertical ? "top" : "left").font(.caption2).foregroundStyle(Theme.dim)
                    Slider(value: Binding(get: { axis == .vertical ? -cropShift : cropShift },
                                          set: { cropShift = axis == .vertical ? -$0 : $0 }),
                           in: -1...1) { editing in if !editing { apply() } }
                    Text(axis == .vertical ? "bottom" : "right").font(.caption2).foregroundStyle(Theme.dim)
                    chip("CENTRE", on: cropShift == 0) { cropShift = 0; apply() }
                }
                .padding(.horizontal, 18)
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
        LookChip(title: title, on: on, action: action)
    }

    // MARK: actions

    static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? CGFloat, let h = p[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
    }

    private func load() {
        status = nil
        guard let item else { return }
        let r = model.roll.recipe(for: item)
        stockID = item.stockID
        strength = r.strength ?? 1
        push = r.pushPull ?? 0
        aspect = r.aspect
        cropShift = r.cropShift ?? 0
        negativeSize = Self.pixelSize(item.negativeURL)
        dateStamp = r.dateStamp
        border = r.frame
        leak = r.lightLeak ?? 0
        dust = r.dust ?? false
        lens = r.portraitLens
        blur = r.blurAmount ?? model.prefs.blurAmount
        focus = r.focusDepth ?? 0.8
        grain = r.grainAmount
        halation = r.halation
        flare = r.flareStrength
        expired = r.expired ?? 0
        crisp = r.crisp ?? false
        scanner = r.scanner
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
        // Same stock: let reprint use the frame's own (saved copy of a custom stock). New stock: that one.
        let stock: FilmStock? = stockID == item.stockID ? nil : FilmStock.with(id: stockID)
        let (s, p, a, d, b) = (strength, push, aspect, dateStamp, border)
        let cs = cropShift
        let (lk, du) = (leak, dust)
        let (ln, bl, fc) = (lens, blur, focus)
        let (gr, ha, fl) = (grain, halation, flare)
        let (ex, sc, cr) = (expired, scanner, crisp)
        Task {
            do {
                status = try await model.reprint(item, stock: stock, syncPhotos: false) { o in
                    o.strength = s; o.pushPull = p; o.aspect = a; o.dateStamp = d; o.frame = b
                    o.cropShift = cs == 0 ? nil : cs
                    o.lightLeak = lk > 0 ? lk : nil; o.dust = du ? true : nil
                    o.portraitLens = ln; o.blurAmount = bl; o.focusDepth = fc
                    o.grainAmount = gr; o.halation = ha; o.flareAmount = fl
                    o.expired = ex > 0.01 ? ex : nil; o.scanner = sc; o.crisp = cr ? true : nil
                }
            } catch {
                status = error.localizedDescription
            }
            developing = false
            if dirty { apply() }
        }
    }

    /// Lays the print out as a 4:5 post or 9:16 story and opens the share sheet.
    private func shareSocial(_ item: RollItem, _ format: SocialPrint.Format) {
        let border = model.roll.recipe(for: item).frame
        let stock = model.stock(for: item)?.displayName ?? ""
        status = "Preparing…"
        Task {
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      let data = SocialPrint.render(cg, format: format, border: border, stock: stock) else { return nil }
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("Latent \(format.rawValue) \(item.base).jpg")
                return (try? data.write(to: out, options: .atomic)) == nil ? nil : out
            }.value
            status = url == nil ? "Couldn't prepare the image" : nil
            socialURL = url
        }
    }

    /// Develops a push/pull that hadn't settled when the user swiped to another frame.
    private func commitPendingPush(for id: String) {
        guard loadedFor == id, let left = model.roll.item(id: id), left.hasNegative,
              push != (model.roll.recipe(for: left).pushPull ?? 0) else { return }
        let p = push
        Task {
            _ = try? await model.reprint(left, syncPhotos: false) { $0.pushPull = p }
            model.flushPhotos([id])
        }
    }

    private func save(_ item: RollItem) {
        Task {
            do { status = try await model.saveToPhotos(item) } catch { status = error.localizedDescription }
        }
    }

    /// `everywhere`: also moves its Photos copy to Recently Deleted (same as deleting from the roll's selection).
    private func deleteCurrent(everywhere: Bool) {
        guard let item, let index = model.roll.items.firstIndex(where: { $0.id == item.id }) else { return }
        let items = model.roll.items
        let neighbour = index + 1 < items.count ? items[index + 1].id : (index > 0 ? items[index - 1].id : nil)
        let moveOn = { if let neighbour { selection = neighbour } else { close() } }
        guard everywhere else { model.roll.delete(item); moveOn(); return }
        status = "Deleting…"
        Task {
            let result = await model.deleteEverywhere([item])
            // If Photos said no, nothing was deleted: stay on the frame and say why.
            if model.roll.items.contains(where: { $0.id == item.id }) { status = result } else { status = nil; moveOn() }
        }
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

/// Sets up a double exposure: which frame is the base (it gives the frame, stock and settings) and which goes on
/// top, and how the light is shared between them, with a live preview.
private struct DoubleExposureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var base: RollItem
    @State var top: RollItem
    var done: (RollItem) -> Void

    @State private var balance = 0.5
    @State private var preview: UIImage?
    @State private var rendering = false
    @State private var exposing = false
    @State private var error: String?
    @State private var thumbs: [String: UIImage] = [:]

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("DOUBLE EXPOSURE").font(Theme.mono(14, .bold)).foregroundStyle(Theme.amber)
                Spacer()
                Button("CANCEL") { dismiss() }.font(Theme.mono(11, .bold)).foregroundStyle(Theme.label)
            }
            .padding(.horizontal, 20).padding(.top, 18)

            ZStack {
                Color.black
                if let preview { Image(uiImage: preview).resizable().scaledToFit() }
                if rendering || preview == nil { ProgressView().tint(Theme.amber) }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                card(base, role: "BASE", note: "sets frame & stock")
                Button {
                    Feedback.selection()
                    (base, top) = (top, base)
                    balance = 1 - balance
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 44, height: 44).background(Circle().fill(Theme.amber))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Swap base and top")
                card(top, role: "ON TOP", note: "laid over it")
            }
            .padding(.horizontal, 20)

            VStack(spacing: 4) {
                HStack {
                    Text("BASE \(Int(((1 - balance) * 100).rounded()))%")
                    Spacer()
                    Text("ON TOP \(Int((balance * 100).rounded()))%")
                }
                .font(Theme.mono(10, .bold)).foregroundStyle(Theme.dim)
                Slider(value: $balance, in: 0.15...0.85, step: 0.05)
            }
            .padding(.horizontal, 20)

            if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 20) }

            Button(action: expose) {
                HStack(spacing: 8) {
                    if exposing { ProgressView().tint(.black) }
                    Text(exposing ? "EXPOSING…" : "EXPOSE").font(Theme.mono(15, .bold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(Theme.amber, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(exposing)
            .padding(.horizontal, 22).padding(.bottom, 8)
        }
        .background(Theme.body.ignoresSafeArea())
        .interactiveDismissDisabled(exposing)
        .task(id: "\(base.id)|\(top.id)|\(balance)") { await render() }
        .task {
            for item in [base, top] { thumbs[item.id] = await model.roll.thumbnail(for: item, maxPixel: 200) }
        }
    }

    private func card(_ item: RollItem, role: String, note: String) -> some View {
        HStack(spacing: 10) {
            Group {
                if let t = thumbs[item.id] { Image(uiImage: t).resizable().scaledToFill() } else { Theme.panel }
            }
            .frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(role).font(Theme.mono(11, .bold)).foregroundStyle(Theme.amber)
                Text(note).font(.caption2).foregroundStyle(Theme.dim).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    private func render() async {
        try? await Task.sleep(for: .milliseconds(preview == nil ? 0 : 150))   // settle while sliding
        guard !Task.isCancelled,
              let na = try? Data(contentsOf: base.negativeURL), let nb = try? Data(contentsOf: top.negativeURL) else { return }
        rendering = true
        defer { rendering = false }
        let (ra, rb) = (model.roll.recipe(for: base), model.roll.recipe(for: top))
        let options = model.doubleExposureOptions(base: base)
        guard let stock = model.stock(for: base) else { error = DarkroomError.missingStock.localizedDescription; return }
        if let cg = try? await Darkroom.shared.doubleExposurePreview(na, ra, nb, rb, balance: balance,
                                                                       stock: stock, options: options),
           !Task.isCancelled {
            preview = UIImage(cgImage: cg)
        }
    }

    private func expose() {
        exposing = true; error = nil
        Task {
            do { done(try await model.doubleExposure(base, top, balance: balance)) }
            catch { self.error = error.localizedDescription }
            exposing = false
        }
    }
}

/// The finished contact sheet: zoomable preview, save to Photos, share.
private struct ContactSheetView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoomed = false
    @State private var status: String?

    var body: some View {
        VStack(spacing: 0) {
            ZoomableImage(image: image, zoomed: $zoomed)
                .background(Color.black)
            if let status { Text(status).font(Theme.mono(11)).foregroundStyle(Theme.dim).padding(.top, 6) }
            RollBottomBar {
                Button {
                    Task {
                        do {
                            _ = try await PhotoLibrary.create(print: try Data(contentsOf: url), original: nil, recipe: Data(), location: nil, date: Date())
                            status = "Saved to Photos"
                        }
                        catch { status = error.localizedDescription }
                    }
                } label: { RoundIcon(systemName: "square.and.arrow.down") }
                .buttonStyle(.plain)
            } center: {
                dismiss()
            } trailing: {
                ShareLink(item: url) { RoundIcon(systemName: "square.and.arrow.up") }
            }
        }
        .background(Theme.body.ignoresSafeArea())
        .task { image = RollStore.downsample(url, maxPixel: 4000) }
    }
}

/// The roll split into days, newest first.
struct RollDay: Identifiable {
    let key: String          // "2026-11-21"
    let title: String        // "SAT 21 NOV"
    let items: [RollItem]
    var id: String { key }

    static func group(_ items: [RollItem]) -> [RollDay] {
        let keyFormat = DateFormatter(); keyFormat.dateFormat = "yyyy-MM-dd"
        let titleFormat = DateFormatter(); titleFormat.dateFormat = "EEE d MMM"
        let thisYear = Calendar.current.component(.year, from: Date())
        var order: [String] = [], groups: [String: [RollItem]] = [:]
        for item in items {
            let k = keyFormat.string(from: item.date)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(item)
        }
        return order.map { k in
            let first = groups[k]![0].date
            var title = titleFormat.string(from: first).uppercased()
            if Calendar.current.component(.year, from: first) != thisYear { title += " \(Calendar.current.component(.year, from: first))" }
            return RollDay(key: k, title: title, items: groups[k]!)
        }
    }
}

/// The system share sheet (Instagram, AirDrop, Messages…) for files made on the spot.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
