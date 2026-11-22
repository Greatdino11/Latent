import SwiftUI
import WatchConnectivity

@main
struct LatentWatchApp: App {
    @State private var link = PhoneLink()

    var body: some Scene {
        WindowGroup { ShutterView().environment(link) }
    }
}

/// Talks to Latent on the iPhone: fires the shutter, and receives the phone's state and the newest frame.
@Observable
final class PhoneLink: NSObject, WCSessionDelegate {
    var reachable = false
    var cameraReady = false
    var frames = 0
    var stock = ""
    var thumbnail: UIImage?
    var status: String?
    var busy = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func shoot(timer: Int) {
        guard WCSession.default.isReachable else { status = "Open Latent on your iPhone"; return }
        busy = true; status = timer > 0 ? "Timer \(timer)s…" : nil
        WCSession.default.sendMessage(["action": "shoot", "timer": timer], replyHandler: { reply in
            Task { @MainActor in
                self.busy = false
                self.status = (reply["ok"] as? Bool) == true ? nil : (reply["reason"] as? String ?? "Couldn't take the photo")
            }
        }, errorHandler: { _ in
            Task { @MainActor in self.busy = false; self.status = "Open Latent on your iPhone" }
        })
    }

    private func absorb(_ context: [String: Any]) {
        Task { @MainActor in
            if let ready = context["ready"] as? Bool { self.cameraReady = ready }
            if let n = context["frames"] as? Int { self.frames = n }
            if let s = context["stock"] as? String { self.stock = s }
            if let data = context["thumb"] as? Data, let img = UIImage(data: data) { self.thumbnail = img }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        absorb(session.receivedApplicationContext)
        Task { @MainActor in self.reachable = session.isReachable }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.reachable = session.isReachable }
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) { absorb(applicationContext) }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { absorb(message) }
}

struct ShutterView: View {
    @Environment(PhoneLink.self) private var link
    @State private var timer = 0
    private let amber = Color(red: 0.95, green: 0.64, blue: 0.23)

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if let t = link.thumbnail {
                    Image(uiImage: t).resizable().scaledToFill().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "№%03d", link.frames)).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(amber)
                    Text(link.stock.uppercased()).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            Button { link.shoot(timer: timer) } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 3).frame(width: 74, height: 74)
                    Circle().fill(amber.opacity(link.reachable && link.cameraReady ? 1 : 0.35)).frame(width: 62, height: 62)
                    if link.busy { ProgressView().tint(.black) }
                }
            }
            .buttonStyle(.plain)
            .disabled(link.busy)
            .accessibilityLabel("Take photo")
            Button {
                timer = timer == 0 ? 3 : timer == 3 ? 10 : 0
            } label: {
                Label(timer == 0 ? "No timer" : "\(timer)s timer", systemImage: "timer")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(timer == 0 ? .secondary : amber)
            }
            .buttonStyle(.plain)
            if let s = link.status ?? (!link.reachable ? "Open Latent on your iPhone" : nil) {
                Text(s).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 6)
    }
}
