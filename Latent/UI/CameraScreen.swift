import SwiftUI

struct CameraScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showRoll = false
    @State private var showEditor = false   // debug: -openEditor
    @State private var showLook = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TopBar(showSettings: $showSettings)
                .padding(.horizontal, 18)
                .frame(height: 44)
            Viewfinder()
                .overlay(alignment: .bottom) { ActiveLookBar { showLook = true }.padding(.bottom, 10) }
                .layoutPriority(1)
            StockStrip(openLook: { showLook = true })
                .padding(.top, 12)
            ExposureDial(value: $model.exposure)
                .frame(height: 46)
                .padding(.top, 6)
            ControlDeck(showRoll: $showRoll)
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
        .background(Theme.body.ignoresSafeArea())
        .background {
            // Volume buttons fire the shutter while the viewfinder is showing.
            HardwareShutter(enabled: !showRoll && !showSettings && !showLook && model.reveal == nil) { model.capture() }
        }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice)
                    .font(Theme.mono(12, .semibold)).foregroundStyle(Theme.amber)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.black.opacity(0.8), in: Capsule())
                    .padding(.top, 56).padding(.horizontal, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy, value: model.notice)
        .overlay {
            if let item = model.reveal {
                RevealView(item: item) { withAnimation(.easeOut(duration: 0.2)) { model.reveal = nil } }
                    .transition(.opacity)
            }
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showLook) { LookDrawer() }
        .sheet(isPresented: $showEditor) {
            NavigationStack { StockEditorView(custom: CustomStock.random(keeping: "custom-preview", name: "Test"), isNew: true) }
        }
        .fullScreenCover(isPresented: $showRoll) { RollView(openLatest: true) }
        .fullScreenCover(isPresented: Binding(get: { !model.prefs.onboarded && !Self.automated }, set: { _ in })) {
            OnboardingView {
                model.prefs.onboarded = true
                Task { await model.launch() }
            }
        }
        .task {
            if model.prefs.onboarded || Self.automated { await model.launch() }
            #if DEBUG
            await model.developDemoRollIfRequested()
            if ProcessInfo.processInfo.arguments.contains("-openRoll") { showRoll = true }
            if ProcessInfo.processInfo.arguments.contains("-openEditor") { showEditor = true }
            if ProcessInfo.processInfo.arguments.contains("-openLook") { showLook = true }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in model.isActive = phase == .active }
        .onChange(of: model.roll.items, initial: true) { _, items in WidgetPublisher.shared.publish(items) }
        .onChange(of: showRoll || showSettings) { _, covered in model.viewfinderCovered = covered }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }
}

extension CameraScreen {
    /// Launched by a test or demo script: skip the introduction.
    static var automated: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-demo") || $0.hasPrefix("-open") }
        #else
        false
        #endif
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool

    var body: some View {
        let prefs = model.prefs
        let turn = model.orientation.angle
        HStack(spacing: 14) {
            if model.camera.hasFlash || (model.camera.isSimulated && model.camera.position == .back) {
                Button { model.flash = model.flash.next } label: {
                    Image(systemName: model.flash.icon)
                        .foregroundStyle(model.flash == .off ? Theme.label : Theme.amber)
                        .rotationEffect(turn)
                }
                .accessibilityLabel("Flash \(model.flash.rawValue)")
            }
            Button { withAnimation(.snappy) { prefs.aspect = prefs.aspect.next } } label: {
                Text(prefs.aspect.label)
                    .font(Theme.mono(12, .semibold))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.dim, lineWidth: 1))
            }
            Button { prefs.showGrid.toggle() } label: {
                Image(systemName: "grid").foregroundStyle(prefs.showGrid ? Theme.amber : Theme.label)
                    .rotationEffect(turn)
            }
            Button {
                model.timerSeconds = model.timerSeconds == 0 ? 3 : model.timerSeconds == 3 ? 10 : 0
                Feedback.selection()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "timer")
                    if model.timerSeconds > 0 { Text("\(model.timerSeconds)").font(Theme.mono(11, .bold)) }
                }
                .foregroundStyle(model.timerSeconds > 0 ? Theme.amber : Theme.label)
                .rotationEffect(turn)
            }
            .accessibilityLabel(model.timerSeconds == 0 ? "Self-timer off" : "Self-timer \(model.timerSeconds) seconds")
            Spacer()
            Text(String(format: "№%03d", model.roll.items.count))
                .lineLimit(1).fixedSize()
                .rotationEffect(turn)
                .font(Theme.mono(13, .semibold))
                .foregroundStyle(Theme.amber)
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.5, bounce: 0.3), value: model.roll.items.count)
            Spacer()
            if model.camera.depthSupported || model.camera.isSimulated {
                Button { model.togglePortrait(); Feedback.selection() } label: {
                    Image(systemName: model.portrait ? "person.crop.circle.fill" : "person.crop.circle")
                        .foregroundStyle(model.portrait ? Theme.amber : Theme.label)
                        .rotationEffect(turn)
                }
                .accessibilityLabel(model.portrait ? "Portrait on" : "Portrait off")
            }
            if model.camera.hasFrontCamera {
                Button { Task { await model.camera.flip() } } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera").rotationEffect(turn)
                }
                .accessibilityLabel("Switch camera")
            }
            Button { showSettings = true } label: { Image(systemName: "gearshape").rotationEffect(turn) }
        }
        .animation(.snappy, value: turn)
        .font(.system(size: 17))
        .foregroundStyle(Theme.label)
        .buttonStyle(.plain)
    }
}
