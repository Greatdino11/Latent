import AppIntents

/// Opens Latent straight to the viewfinder. Shared by the app and the Control Center / Lock Screen control.
struct OpenLatentIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Latent"
    static let description = IntentDescription("Opens the Latent film camera.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult { .result() }
}
