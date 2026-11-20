import AppIntents
import SwiftUI
import WidgetKit

@main
struct LatentControlsBundle: WidgetBundle {
    var body: some Widget {
        OpenLatentControl()
        PhotoWidget()
    }
}

/// A Control Center / Lock Screen / Action button control that opens Latent.
struct OpenLatentControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.latentcam.open") {
            ControlWidgetButton(action: OpenLatentIntent()) {
                Label("Latent", systemImage: "camera.aperture")
            }
        }
        .displayName("Latent Camera")
        .description("Open Latent to take a photo.")
    }
}
