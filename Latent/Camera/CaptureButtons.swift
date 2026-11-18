import AVKit
import SwiftUI

/// Lets the volume buttons (and Camera Control on newer iPhones) fire the shutter while the viewfinder is showing.
struct HardwareShutter: UIViewRepresentable {
    var enabled: Bool
    var action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .began { context.coordinator.action() }
            }
            interaction.isEnabled = enabled
            view.addInteraction(interaction)
            context.coordinator.interaction = interaction
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.action = action
        if #available(iOS 17.2, *) { (context.coordinator.interaction as? AVCaptureEventInteraction)?.isEnabled = enabled }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator {
        var action: () -> Void
        var interaction: AnyObject?
        init(action: @escaping () -> Void) { self.action = action }
    }
}
