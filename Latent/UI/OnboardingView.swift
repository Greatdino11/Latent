import SwiftUI

/// First launch: three ideas, then camera access. The start button sits where the shutter will be.
struct OnboardingView: View {
    var start: () -> Void

    private let points: [(icon: String, title: String, body: String)] = [
        ("eye.slash", "No live preview",
         "The viewfinder shows the plain scene. Each frame develops on its film after you take it."),
        ("film.stack", "Change the film any time",
         "Every frame keeps its negative. In the roll you can switch stock, push or pull exposure, and re-crop."),
        ("hand.raised", "Made for one hand",
         "The volume buttons take photos. Controls live at the bottom, and the button in the shutter's spot always brings you back."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 20)
            Text("LATENT").font(Theme.mono(30, .bold)).foregroundStyle(Theme.amber)
            Text("A point-and-shoot that develops like film.")
                .font(.subheadline).foregroundStyle(Theme.dim).padding(.top, 6)
            VStack(alignment: .leading, spacing: 26) {
                ForEach(points, id: \.title) { p in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: p.icon).font(.system(size: 22)).foregroundStyle(Theme.amber).frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.title).font(Theme.mono(15, .bold)).foregroundStyle(Theme.label)
                            Text(p.body).font(.subheadline).foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            .padding(.top, 40)
            Spacer(minLength: 20)
            Text("Next, Latent asks to use the camera. Photos and location access are asked for only when you use them.")
                .font(.footnote).foregroundStyle(Theme.dim)
                .padding(.bottom, 14)
            HStack {
                Spacer()
                Button(action: start) {
                    ZStack {
                        Circle().stroke(Theme.label, lineWidth: 3).frame(width: 78, height: 78)
                        Circle().fill(Theme.amber).frame(width: 64, height: 64)
                        Image(systemName: "arrow.right").font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start shooting")
                Spacer()
            }
            .frame(height: 84)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 28)
        .background(Theme.body.ignoresSafeArea())
        .statusBarHidden()
    }
}
