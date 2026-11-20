import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var usage = RollStore.Usage()
    @State private var confirmDiscard: Int??
    @State private var archiveURL: URL?
    @State private var archiveStatus: String?
    @State private var importing = false

    var body: some View {
        @Bindable var prefs = model.prefs
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Stocks & random pool") { StockManagerView() }
                } header: { Text("Film") } footer: {
                    Text("Grain, flare, halation, leaks, dust, borders, the portrait lens and 48MP are on the camera: tap LOOK on the viewfinder (or swipe up on the stocks). Long-press a stock for its options; + at the end of the stocks makes a new one or adds one from a code.")
                }
                Section {
                    Picker("Aspect ratio", selection: $prefs.aspect) {
                        ForEach(AspectRatio.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Grid", isOn: $prefs.showGrid)
                    Toggle("Level", isOn: $prefs.showLevel)
                    Toggle("Full-screen reveal", isOn: $prefs.bigReveal)
                    Toggle("Haptics", isOn: $prefs.haptics)
                    Toggle("Film advance sound", isOn: $prefs.advanceSound)
                } header: { Text("Capture") } footer: {
                    Text("The volume buttons also take a photo. Double-tap the viewfinder to switch cameras; long-press it to lock focus and exposure (tap to unlock). Full-screen reveal shows each frame developing (in Random mode, that's when you find out the stock).")
                }
                Section {
                    Toggle("Tag location", isOn: $prefs.saveLocation)
                        .onChange(of: prefs.saveLocation) { model.updateSensors() }
                    if prefs.saveLocation, model.location.denied {
                        Text("Location access is off for Latent in Settings.").font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section {
                    Toggle("Save to Photos", isOn: $prefs.saveToPhotos)
                    Toggle("Keep the original underneath", isOn: $prefs.saveOriginal).disabled(!prefs.saveToPhotos)
                } header: { Text("Library") } footer: {
                    Text("Each frame is one photo in your library: a standard-range (SDR) print that looks the same on every screen. Re-developing it on the roll updates that photo, and deleting it in Photos removes it from the roll too (it comes back if you restore it from Recently Deleted within 30 days; needs Full Access to Photos). \"Keep the original underneath\" also stores the RAW (about 25 MB) so Edit ▸ Revert in Photos brings it back — but Photos shows that RAW in HDR, and apps like Lightroom may import it instead of your print. Leave it off for SDR-only photos.")
                }
                Section {
                    LabeledContent("Prints", value: bytes(usage.prints))
                    LabeledContent("Negatives (\(usage.negativeCount))", value: bytes(usage.negatives))
                    Button("Export roll…") { exportRoll() }.disabled(model.roll.items.isEmpty)
                    if let archiveURL {
                        ShareLink(item: archiveURL) { Label("Share roll file", systemImage: "square.and.arrow.up") }
                    }
                    Button("Import roll…") { importing = true }
                    if let archiveStatus { Text(archiveStatus).font(.footnote).foregroundStyle(.secondary) }
                    Button("Discard negatives older than 30 days") { confirmDiscard = .some(30) }
                        .disabled(usage.negativeCount == 0)
                    Button("Discard all negatives", role: .destructive) { confirmDiscard = .some(nil) }
                        .disabled(usage.negativeCount == 0)
                } header: { Text("Storage") } footer: {
                    Text("Negatives let you re-develop a frame later. Without one, a frame keeps its current print. Export roll packs every frame and negative into one file (AirDrop it or keep it in Files); Import roll adds them back, e.g. after reinstalling.")
                }
                if let secs = model.lastDevelopSeconds {
                    LabeledContent("Last develop took", value: String(format: "%.1f s", secs))
                }
                Section {
                    Text("There is no live preview of the film look. The viewfinder shows the plain scene, and each frame develops after you take it. On iPhones with ProRAW, Latent shoots RAW and skips the phone's own processing. Every frame keeps its negative, so you can re-develop it on another stock from the roll.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .onAppear { usage = model.roll.usage() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                importRoll(url)
            }
            .confirmationDialog(confirmDiscard == .some(nil) ? "Discard every negative?" : "Discard negatives older than 30 days?",
                                isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    if case .some(let days) = confirmDiscard { model.roll.discardNegatives(olderThan: days) }
                    usage = model.roll.usage()
                }
            } message: { Text("Those frames can't be re-developed afterwards. This can't be undone.") }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                // Close where the thumb already is (swipe down works too).
                Button { dismiss() } label: {
                    Text("Done").font(Theme.mono(15, .bold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(Theme.amber, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 4)
                .background(.bar)
            }
        }
    }

    private func exportRoll() {
        archiveURL = nil
        archiveStatus = "Packing the roll…"
        let folder = model.roll.folderURL
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) { try RollArchive.export(from: folder) }.value
                archiveURL = url
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                archiveStatus = "Ready (\(bytes(Int64(size)))). Tap Share roll file."
            } catch {
                archiveStatus = "Couldn't export: \(error.localizedDescription)"
            }
        }
    }

    private func importRoll(_ url: URL) {
        archiveStatus = "Importing…"
        let folder = model.roll.folderURL
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let added = try await Task.detached(priority: .userInitiated) { try RollArchive.importArchive(url, into: folder) }.value
                model.roll.reload()
                usage = model.roll.usage()
                archiveStatus = added == 0 ? "Nothing new to add." : "Added \(added) files to the roll."
            } catch {
                archiveStatus = error.localizedDescription
            }
        }
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

}

struct StockManagerView: View {
    @Environment(AppModel.self) private var model
    @State private var showPaste = false
    @State private var pasteCode = ""
    @State private var codeStatus: String?

    var body: some View {
        let prefs = model.prefs
        List {
            Section {
                ForEach(prefs.customStocks) { custom in
                    NavigationLink {
                        StockEditorView(custom: custom, isNew: false)
                    } label: {
                        HStack(spacing: 12) {
                            HStack(spacing: 0) {
                                ForEach(Array(LUT.chart.enumerated()), id: \.offset) { _, c in
                                    let o = LUT.preview(c, custom.stock)
                                    Rectangle().fill(Color(red: o.x, green: o.y, blue: o.z))
                                }
                            }
                            .frame(width: 60, height: 10)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            Text(custom.stock.displayName).font(Theme.mono(14, .bold))
                        }
                    }
                }
                NavigationLink {
                    StockEditorView(custom: CustomStock(), isNew: true)
                } label: {
                    Label("New stock", systemImage: "plus.circle.fill").foregroundStyle(Theme.amber)
                }
                Button { pasteCode = ""; showPaste = true } label: {
                    Label("Add from code", systemImage: "doc.on.clipboard").foregroundStyle(Theme.amber)
                }
                if let codeStatus { Text(codeStatus).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Your stocks") } footer: {
                Text("Start from any stock and adjust colour, contrast and texture with a live preview. Your stocks appear in the camera, Random and the roll.")
            }
            Section {
                ForEach(prefs.orderedStocks) { stock in
                    let hidden = prefs.hiddenStocks.contains(stock.id)
                    let inPool = prefs.randomPool.contains(stock.id)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 0) {
                                ForEach(Array(LUT.chart.enumerated()), id: \.offset) { _, c in
                                    let o = LUT.preview(c, stock)
                                    Rectangle().fill(Color(red: o.x, green: o.y, blue: o.z))
                                }
                            }
                            .frame(width: 90, height: 10)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            Text(stock.displayName).font(Theme.mono(14, .bold))
                                .foregroundStyle(hidden ? Theme.dim : Theme.label)
                            Text(stock.blurb).font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text("LOOK").font(Theme.mono(9, .bold)).foregroundStyle(Theme.dim)
                                Slider(value: Binding(get: { prefs.strength(for: stock) },
                                                      set: { prefs.stockStrength[stock.id] = $0 }), in: 0...1, step: 0.05)
                                Text("\(Int(prefs.strength(for: stock) * 100))%").font(Theme.mono(10)).foregroundStyle(Theme.amber)
                                    .frame(width: 34, alignment: .trailing)
                            }
                            .disabled(hidden)
                        }
                        Spacer()
                        Button { prefs.toggleRandom(stock.id) } label: {
                            Image(systemName: inPool ? "dice.fill" : "dice")
                                .foregroundStyle(inPool ? Theme.amber : Theme.dim)
                        }
                        .disabled(hidden)
                        Button { prefs.toggleHidden(stock.id) } label: {
                            Image(systemName: hidden ? "eye.slash" : "eye")
                                .foregroundStyle(hidden ? Theme.dim : Theme.label)
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 2)
                }
                .onMove { prefs.moveStocks(from: $0, to: $1) }
            } footer: {
                Text("Drag to reorder. The eye hides a stock from the strip. Dice marks the stocks Random may choose; with none marked, Random uses every visible stock. LOOK sets how strongly each stock is applied to new frames.")
            }
        }
        .alert("Add stock from code", isPresented: $showPaste) {
            TextField("LTN1-…", text: $pasteCode)
            Button("Add") {
                if let custom = StockCode.decode(pasteCode) {
                    model.prefs.save(custom); codeStatus = "Added \(custom.name)."
                } else {
                    codeStatus = "That doesn't look like a Latent stock code."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Paste a code someone shared with you (the whole message is fine).") }
        .navigationTitle("Stocks")
        .toolbar { EditButton() }
    }
}
