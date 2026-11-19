import SwiftUI

/// Make or edit your own stock: pick a base, move sliders, watch a live print of your latest negative.
struct StockEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var custom: CustomStock
    let isNew: Bool

    @State private var preview: UIImage?
    @State private var rendering = false
    @State private var source: (negative: Data, recipe: DevelopOptions)?
    @State private var loadedSource = false
    @State private var confirmDelete = false

    private static let isoChoices = [50, 100, 160, 200, 400, 800, 1600, 3200]

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Color.black
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFit()
                } else {
                    ProgressView().tint(Theme.amber)
                }
                if rendering && preview != nil {
                    ProgressView().tint(Theme.amber).padding(10)
                }
            }
            .frame(height: 290)
            .clipped()

            Form {
                Section {
                    TextField("Name", text: $custom.name)
                    Picker("ISO", selection: $custom.iso) {
                        ForEach(Self.isoChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Based on", selection: $custom.baseID) {
                        ForEach(FilmStock.all) { Text($0.displayName).tag($0.id) }
                    }
                } footer: {
                    Text(source == nil ? "Preview shows a test scene. Take a photo to preview on your own." : "Preview shows your latest photo.")
                }
                Section("Light & colour") {
                    slider("Brightness", $custom.brightness, -1...1)
                    slider("Warmth", $custom.warmth, -1...1)
                    slider("Tint", $custom.tint, -1...1, left: "green", right: "magenta")
                    slider("Contrast", $custom.contrast, -1...1)
                    slider("Fade", $custom.fade, 0...1)
                    slider("Saturation", $custom.saturation, -1...1)
                }
                Section("Texture") {
                    slider("Grain", $custom.grain, 0...2, neutral: 1)
                    slider("Halation", $custom.halation, 0...2, neutral: 1)
                    slider("Glow", $custom.glow, -1...1)
                    slider("Softness", $custom.softness, -1...1)
                    slider("Vignette", $custom.vignette, -1...1)
                }
                Section {
                    Button("Surprise me") {
                        Feedback.selection()
                        custom = .random(keeping: custom.id, name: custom.name)
                    }
                    Button("Reset sliders") {
                        custom = CustomStock(id: custom.id, name: custom.name, iso: custom.iso, baseID: custom.baseID)
                    }
                    if !isNew {
                        Button("Delete stock", role: .destructive) { confirmDelete = true }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.prefs.save(custom)
                Feedback.success()
                dismiss()
            } label: {
                Text(isNew ? "Save stock" : "Save changes").font(Theme.mono(15, .bold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(Theme.amber, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 4)
            .background(.bar)
        }
        .navigationTitle(isNew ? "New stock" : custom.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete \(custom.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.prefs.delete(custom); dismiss() }
        } message: { Text("Photos already printed with it keep their prints.") }
        .task(id: custom) {
            if !loadedSource { loadSource() }
            try? await Task.sleep(for: .milliseconds(preview == nil ? 0 : 180))   // settle while dragging
            guard !Task.isCancelled else { return }
            rendering = true
            let (stock, src) = (custom.stock, source)
            if let cg = try? await Darkroom.shared.preview(negative: src?.negative, recipe: src?.recipe, stock: stock) {
                if !Task.isCancelled { preview = UIImage(cgImage: cg) }
            }
            rendering = false
        }
    }

    /// The newest frame that still has its negative.
    private func loadSource() {
        loadedSource = true
        guard let item = model.roll.items.first(where: \.hasNegative),
              let data = try? Data(contentsOf: item.negativeURL) else { return }
        source = (data, model.roll.recipe(for: item))
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, neutral: Double = 0,
                        left: String? = nil, right: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue == neutral ? "—" : String(format: "%+.0f", (value.wrappedValue - neutral) * 100))
                    .font(Theme.mono(12)).foregroundStyle(value.wrappedValue == neutral ? Theme.dim : Theme.amber)
                    .onTapGesture(count: 2) { value.wrappedValue = neutral }
            }
            Slider(value: value, in: range)
            if let left, let right {
                HStack { Text(left); Spacer(); Text(right) }.font(.caption2).foregroundStyle(Theme.dim)
            }
        }
    }
}
