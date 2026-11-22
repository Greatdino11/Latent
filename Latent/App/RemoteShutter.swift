import UIKit
import WatchConnectivity

/// The Apple Watch remote: fires the shutter when the watch asks, and keeps the watch's view of the camera (ready,
/// frame count, stock, newest frame) up to date. The camera only runs with Latent open on the phone, so a press
/// while it's in the background is answered with a hint to open it.
@MainActor
final class RemoteShutter: NSObject, WCSessionDelegate {
    static let shared = RemoteShutter()
    private weak var model: AppModel?

    func start(_ model: AppModel) {
        self.model = model
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends the current state; called when the roll or camera changes.
    func publish() {
        guard let model, WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        var context: [String: Any] = [
            "ready": model.camera.isReady && model.isActive,
            "frames": model.roll.items.count,
            "stock": model.prefs.isRandom ? "Random" : (FilmStock.with(id: model.prefs.selectedStockID)?.displayName ?? ""),
        ]
        if let first = model.roll.items.first, let thumb = RollStore.downsample(first.url, maxPixel: 120),
           let jpeg = thumb.jpegData(compressionQuality: 0.6) { context["thumb"] = jpeg }
        try? WCSession.default.updateApplicationContext(context)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let timer = message["timer"] as? Int ?? 0
        Task { @MainActor in
            guard let model = self.model, model.camera.isReady, model.isActive,
                  UIApplication.shared.applicationState == .active else {
                replyHandler(["ok": false, "reason": "Open Latent on your iPhone"]); return
            }
            model.capture(timer: timer)
            replyHandler(["ok": true])
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publish() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
