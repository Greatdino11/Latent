import SwiftUI

/// A new frame developing full screen: it rises out of black, blurred and colourless, then the stock is named.
/// Tap anywhere, swipe down, or press the camera button (where the shutter is) to get back to shooting.
struct RevealView: View {
    @Environment(AppModel.self) private var model
    let item: RollItem
    var done: () -> Void
    @State private var image: UIImage?
    @State private var progress = 0.0
    @State private var named = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .saturation(progress)
                        .brightness(-(1 - progress) * 0.85)
                        .blur(radius: (1 - progress) * 14)
                        .rotationEffect(model.orientation.angle)
                } else {
                    ProgressView().tint(Theme.amber)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Text(item.stock?.displayName.uppercased() ?? "")
                    .font(Theme.mono(18, .bold)).foregroundStyle(Theme.amber)
                Text(item.stock?.blurb ?? "").font(.footnote).foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
            }
            .opacity(named ? 1 : 0)
            .frame(height: 70)
            RollBottomBar {
                Color.clear.frame(width: 52, height: 52)
            } center: {
                done()
            } trailing: {
                Color.clear.frame(width: 52, height: 52)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { done() }
        .gesture(DragGesture(minimumDistance: 30).onEnded { if $0.translation.height > 80 { done() } })
        .task(id: item.id) {
            progress = 0; named = false
            image = await model.roll.thumbnail(for: item, maxPixel: 2000)
            withAnimation(.easeOut(duration: 2.6)) { progress = 1 }
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeIn(duration: 0.5)) { named = true }
        }
    }
}
