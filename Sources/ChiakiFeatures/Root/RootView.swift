import ChiakiClients
import ChiakiModels
import ComposableArchitecture
import DesignSystem
import MenuFocus
import PlatformUI
import SwiftUI

/// The application's view: one screen for ``RootFeature/State/route`` with ``RootFeature/State/destination``
/// presented over it.
public struct RootView: View {
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage = AppLanguage.system.rawValue
    /// The root.
    let store: StoreOf<RootFeature>

    @Environment(\.menuNavigator) private var navigator
    @Environment(\.controllerNavigation) private var controllerNavigation
    @Environment(\.screenLayout) private var layout
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var topControlsLayout = TopControlsLayout()
    @State private var hostWindow: PlatformWindow?

    /// Creates the application's view.
    ///
    /// - Parameter store: The root.
    public init(store: StoreOf<RootFeature>) {
        self.store = store
    }

    private var animation: Animation? {
        AppMotion.animation(reduced: reduceMotion)
    }

    private var settings: StoreOf<SettingsFeature> {
        store.scope(state: \.settings, action: \.settings)
    }

    /// The view.
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                screen(size: geometry.size)
            }
            .disabled(editorPresented)
            .overlay {
                if let editor = store.scope(
                    state: \.destination?.consoleEditor,
                    action: \.destination.consoleEditor
                ) {
                    ConsoleEditorModal(store: editor, size: geometry.size)
                        .transition(AppMotion.transition(reduced: reduceMotion))
                }
            }
            .overlay {
                if let signIn = store.scope(state: \.route.signIn, action: \.route.signIn) {
                    AccountSignInPanel(store: signIn, size: geometry.size)
                }
            }
            .animation(animation, value: store.route)
            .animation(animation, value: editorPresented)
            .overlay(alignment: .topTrailing) {
                if store.settings.logSettings.showLiveLogButton {
                    LiveLogControl(
                        store: store.scope(state: \.liveLog, action: \.liveLog),
                        failure: playbackFailure,
                        size: geometry.size,
                        trailingInset: liveLogTrailingInset,
                        inStream: store.route.is(\.stream),
                        allowsQuit: showsQuitControl,
                        showsButton: liveLogButtonVisible
                    )
                }
            }
            .overlay(
                alignment: RootCornerLogo.besideRail(library: store.route == .library, railEdge: railEdge)
                    ? .topLeading
                    : .bottomTrailing
            ) {
                if showsCornerLogo {
                    RootCornerLogo(
                        library: store.route == .library,
                        railEdge: railEdge,
                        height: geometry.size.height,
                        version: AppVersion.display()
                    )
                }
            }
        }
        .modifier(SettingsPanelPresentation(showsQuit: showsQuitControl, root: store))
        .modifier(AppAlertPresentation(
            alert: alert,
            systemImage: AppIcon.quit.rawValue,
            send: alertChosen
        ))
        .appConfirmation(confirmation?.request, confirm: confirm, cancel: cancel)
        .environment(\.liveLogButtonShown, store.settings.logSettings.showLiveLogButton)
        .environment(\.quitControlShown, showsQuitControl)
        .environment(\.libraryRailEdge, railEdge)
        .environment(\.locale, Locale(identifier: (AppLanguage(rawValue: appLanguage) ?? .system).localeIdentifier))
        .environment(\.streamerMode, store.settings.logSettings.streamerMode)
        .environment(\.topControlsLayout, topControlsLayout)
        .environment(\.streamMenuShortcut, store.settings.controls.configuration.streamMenuShortcut)
        .environment(\.requestQuit, RequestQuitAction { origin in
            store.send(.view(.quitRequested(origin)))
        })
        .modifier(StreamChromePresentation(
            store: store.scope(state: \.streamChrome, action: \.streamChrome),
            live: store.streamPlaying
        ))
        .ambientMotion(streaming: store.streamPlaying)
        .menuFocusSection()
        .onChange(of: store.route) { _, current in
            routeChanged(to: current)
        }
        .onChange(of: store.settings.controls.configuration, initial: true) { _, configuration in
            controllerNavigation?.applyControls(configuration)
        }
        .ignoresSafeArea(.container, edges: [.top, .horizontal])
        #if os(iOS) && DEBUG
            .modifier(VirtualGamepadPreview())
        #endif
            .background(WindowAccessor { hostWindow = $0 })
            .task {
                store.send(.view(.appeared))
            }
            .task(id: RootFeature.alertsWatch(in: store.state)) {
                await store.send(.library(.alerts(.watch(RootFeature.alertsWatch(in: store.state).profile))))
                    .finish()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    store.send(.view(.sceneActivated))
                } else {
                    store.send(.view(.sceneDeactivated))
                }
            }
            .onDisappear {
                store.send(.view(.disappeared))
            }
            .environment(\.virtualGamepad, store.scope(state: \.virtualGamepad, action: \.virtualGamepad))
        #if os(iOS)
            .mobileTextEntryStage()
        #endif
    }

    @ViewBuilder private func screen(size: CGSize) -> some View {
        switch store.route {
        case .stream:
            ZStack {
                StreamView(store: store.scope(state: \.stream, action: \.stream)) {
                    ConsoleStartingView(store: store)
                }
                if store.stream.status == .idle, store.state.loadingStage != nil {
                    ConsoleStartingView(store: store)
                }
            }
            .ignoresSafeArea(.container)
            .modifier(StreamSystemChrome())
            .transition(AppMotion.transition(reduced: reduceMotion))
        case .kakusanGuest:
            AmbientBackground(quiet: false, paused: false)
                .ignoresSafeArea()
            if let guest = store.scope(state: \.route.kakusanGuest, action: \.route.kakusanGuest) {
                KakusanGuestView(store: guest)
                    .transition(AppMotion.transition(reduced: reduceMotion))
            }
        case .library:
            AmbientBackground(quiet: true, paused: false)
                .ignoresSafeArea()
            RootLibraryScreen(store: store, size: size)
                .transition(AppMotion.transition(reduced: reduceMotion))
        case .launching, .welcome, .signIn, .accountIDEntry, .addConsole, .pairing:
            AmbientBackground(quiet: store.route.is(\.addConsole), paused: false)
                .ignoresSafeArea()
            EntryScreen(store: store, height: size.height)
        }
    }

    private var alert: AlertState<RootFeature.Destination.Alert>? {
        if case .alert(let alert) = store.destination {
            return alert
        }
        return nil
    }

    private var editorPresented: Bool {
        if case .consoleEditor = store.destination {
            return true
        }
        return false
    }

    private var railEdge: LibraryRailEdge {
        store.settings.interface.draft.railEdge
    }

    private var showsQuitControl: Bool {
        #if os(macOS)
            store.route == .library
        #else
            false
        #endif
    }

    private var showsCornerLogo: Bool {
        guard !layout.isCompact else {
            return false
        }
        switch store.route {
        case .stream, .kakusanGuest:
            return false
        case .library:
            return railEdge == .left || railEdge == .top
        case .launching, .welcome, .signIn, .accountIDEntry, .addConsole, .pairing:
            return true
        }
    }

    private var liveLogButtonVisible: Bool {
        if store.streamPlaying {
            return false
        }
        return store.route != .library || layout.isCompact
    }

    private var liveLogTrailingInset: CGFloat {
        if !layout.isCompact, topControlsLayout.settingsHost == .libraryBar {
            return 0
        }
        return showsQuitControl
            ? 114
            : 58
    }

    private var playbackFailure: String? {
        store.stream.failureMessage
    }

    private var confirmation: RootConfirmation? {
        let editor: ConsoleEditFlow? =
            if case .consoleEditor(let editor) = store.destination {
                editor.flow
            } else {
                nil
            }
        return RootConfirmation.current(
            accounts: store.accounts.operation,
            editor: editor,
            autoConnect: store.autoConnection.machine
        )
    }

    private func confirm() {
        if let action = confirmation?.confirmAction {
            store.send(action)
        }
    }

    private func cancel() {
        if let action = confirmation?.cancelAction {
            store.send(action)
        }
    }

    private func alertChosen(_ action: RootFeature.Destination.Alert?) {
        guard let action else {
            store.send(.destination(.dismiss))
            return
        }
        store.send(.destination(.presented(.alert(action))))
        guard action == .stay(.button) else {
            return
        }
        let window = hostWindow
        Task { @MainActor in
            for _ in 0..<4 {
                await Task.yield()
            }
            NotificationCenter.default.post(name: .focusQuitControl, object: window)
        }
    }

    private func routeChanged(to current: RootFeature.Route.State) {
        if current == .stream, store.stream.kind == .cloud, let window = WindowFocus.keyWindow {
            navigator?.resignFocus(in: window)
        }
    }
}

/// The one confirmation card the root shows over its screens, chosen by priority.
///
/// An account deletion waiting for confirmation comes first, then the console editor's deletion question or
/// failure, then the automatic connection's progress or failure.
public enum RootConfirmation: Equatable {
    /// An account deletion waits for confirmation.
    case deleteAccount

    /// The console editor asks to confirm a deletion or reports a failure.
    case consoleEditor(ConsoleEditFlow)

    /// The automatic connection runs or failed.
    case autoConnect(AutoConnect)

    /// The confirmation for the root's state.
    ///
    /// - Parameters:
    ///   - accounts: The running or last account operation.
    ///   - editor: The console editor's flow, while it is presented.
    ///   - autoConnect: The automatic connection.
    /// - Returns: The confirmation, or `nil` when there is none.
    public static func current(
        accounts: AccountsOperation,
        editor: ConsoleEditFlow?,
        autoConnect: AutoConnect
    ) -> RootConfirmation? {
        if case .confirmingDeletion = accounts {
            return .deleteAccount
        }
        switch editor {
        case .confirmingDeletion, .failed:
            return editor.map(RootConfirmation.consoleEditor)
        case .closed, .loading, .editing, .saving, .deleting, nil:
            break
        }
        return AutoConnectPresentation.confirmation(for: autoConnect) == nil
            ? nil
            : .autoConnect(autoConnect)
    }

    /// The card to show.
    public var request: AppConfirmation? {
        switch self {
        case .deleteAccount:
            AppConfirmation(
                title: "Delete this account?",
                message: "This removes the account, its saved credentials, cached pictures "
                    + "and connection profiles from this device. "
                    + "Your consoles and PlayStation account are kept.",
                systemImage: AppIcon.deleteAccount.rawValue,
                confirmTitle: "Delete account",
                tone: .destructive
            )
        case .consoleEditor(let flow):
            Self.editorRequest(flow)
        case .autoConnect(let autoConnect):
            AutoConnectPresentation.confirmation(for: autoConnect)
        }
    }

    /// What the root does when the card is confirmed.
    public var confirmAction: RootFeature.Action? {
        switch self {
        case .deleteAccount:
            .accounts(.view(.confirmDeletion))
        case .consoleEditor:
            .destination(.presented(.consoleEditor(.view(.confirm))))
        case .autoConnect:
            nil
        }
    }

    /// What the root does when the card is cancelled.
    public var cancelAction: RootFeature.Action {
        switch self {
        case .deleteAccount:
            .accounts(.view(.cancelDeletion))
        case .consoleEditor:
            .destination(.presented(.consoleEditor(.view(.cancel))))
        case .autoConnect(let autoConnect):
            .autoConnect(
                autoConnect.isActive
                    ? .cancel
                    : .dismiss
            )
        }
    }

    private static func editorRequest(_ flow: ConsoleEditFlow) -> AppConfirmation? {
        switch flow {
        case .confirmingDeletion:
            AppConfirmation(
                title: "Delete this console?",
                message: "This removes the console and its saved pairings for every account on this device. "
                    + "Your accounts are kept. You’ll need to pair again to play.",
                systemImage: AppIcon.deleteAccount.rawValue,
                confirmTitle: "Delete console",
                tone: .destructive
            )
        case .failed(.saveFailed, _):
            AppConfirmation(
                title: "Couldn’t update the console",
                message: "Your changes weren’t saved. Please try again.",
                cancelTitle: "OK"
            )
        case .failed(.deleteFailed, _):
            AppConfirmation(
                title: "Couldn’t delete the console",
                message: "The console wasn’t deleted. Please try again.",
                cancelTitle: "OK"
            )
        case .failed(.loadFailed, _):
            AppConfirmation(
                title: "Couldn’t open the console settings",
                message: "The saved settings for this console couldn’t be read. Please try again.",
                cancelTitle: "OK"
            )
        case .closed, .loading, .editing, .saving, .deleting:
            nil
        }
    }
}

/// The chiaki-ng mark in a corner of the home screens: beside a left library rail, or with the version in the
/// bottom-right corner.
///
/// Entering the Konami code's directions with a controller in this window spins the mark.
private struct RootCornerLogo: View {
    /// Whether the library is shown.
    let library: Bool

    /// Where the library rail sits.
    let railEdge: LibraryRailEdge

    /// The height of the window.
    let height: CGFloat

    /// The app's version.
    let version: String

    @State private var code = MenuCommandCode.konami
    @State private var spins = 0
    @State private var hostWindow: PlatformWindow?
    @Environment(\.screenLayout) private var layout

    /// The smallest window height that leaves room for the mark beside the rail.
    static let besideRailHeight: CGFloat = 680

    /// Whether the mark sits beside a left library rail.
    static func besideRail(library: Bool, railEdge: LibraryRailEdge) -> Bool {
        library && railEdge == .left
    }

    /// The view.
    var body: some View {
        mark
            .background(WindowAccessor { hostWindow = $0 })
            .onPerformedMenuCommand { event in
                guard event.targets(hostWindow, keyWindow: WindowFocus.keyWindow),
                      code.advance(event.command) else {
                    return
                }
                spins += 1
            }
    }

    @ViewBuilder private var mark: some View {
        if Self.besideRail(library: library, railEdge: railEdge) {
            if height >= Self.besideRailHeight {
                ChiakiLogo(size: 30, spins: spins)
                    .help("chiaki-ng \(version)")
                    .frame(width: LibraryRailView<EmptyView, EmptyView>.collapsedWidth(for: layout))
                    .padding(.leading, 16)
                    .padding(.top, 77)
            }
        } else {
            VStack(spacing: 9) {
                ChiakiLogo(
                    size: library
                        ? 38
                        : 48,
                    spins: spins
                )
                Text(version)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(width: 150)
            .opacity(
                library
                    ? 0.75
                    : 1
            )
            .padding(.trailing, 18 + layout.sideInset)
            .padding(.bottom, 18)
            .streamChromeCorner(.bottomTrailing)
        }
    }
}

/// The library screen of the root, with the last registration or account failure below it and the notice that
/// a console refused rest mode over it.
private struct RootLibraryScreen: View {
    /// The root.
    let store: StoreOf<RootFeature>

    /// The size of the window.
    let size: CGSize

    @Environment(\.screenLayout) private var layout
    @Environment(\.menuNavigator) private var navigator

    /// The library with the registration and account failures below it.
    var body: some View {
        if layout.touch, navigator?.inputMode.mode != .controller {
            MobileLibraryView(
                store: store.scope(state: \.library, action: \.library),
                settings: store.scope(state: \.settings, action: \.settings)
            )
        } else {
            classic
        }
    }

    private var classic: some View {
        VStack(spacing: 18) {
            LibraryView(store: store.scope(state: \.library, action: \.library))
                .environment(\.cloudLibraryHeight, max(360, size.height - 190))
            if let failure = store.registrationFailure {
                Text(RegistrationFailureMessage.text(for: failure)).font(.caption).foregroundStyle(.red)
            }
            if let failure = store.accounts.operation.failure {
                CopyableErrorMessage(message: AccountsFailureMessage.text(for: failure), font: .callout)
            }
        }
        .frame(
            maxWidth: layout.isCompact
                ? .infinity
                : 1760
        )
        .frame(maxWidth: .infinity, minHeight: max(0, size.height - 80), alignment: .top)
        .padding(
            .top,
            layout.isCompact
                ? 0
                : 16
        )
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .bottom) {
            if case .shown = store.stream.restNotice {
                RestRefusedNotice()
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
    }
}

/// What a console stream shows while it starts: the title's layered art when it launches a title, or the
/// stream's loading steps, each with a way to leave.
private struct ConsoleStartingView: View {
    /// The root.
    let store: StoreOf<RootFeature>

    @Environment(\.streamStopTrace) private var stopTrace

    /// The loading screen of the stage the console stream is at.
    var body: some View {
        if let stage = store.state.loadingStage {
            let operation = stage == .waitingForVideo
                ? store.stream.progress
                : nil
            if let layers = store.state.titleLoadingArt {
                CloudLayeredLoadingView(
                    layers: layers,
                    title: store.recentlyPlayed.launch.title?.name ?? "",
                    status: stage.status,
                    operation: operation,
                    leaving: false,
                    cancel: {
                        leave(stage)
                    }
                )
                .transition(.opacity)
                .accessibilityIdentifier("console-layered-loading")
            } else {
                StreamLoadingView(
                    status: stage.status,
                    activeStep: stage.step,
                    stepCount: 4,
                    operation: operation,
                    cancel: {
                        leave(stage)
                    }
                )
            }
        } else {
            ProgressView("Connecting")
        }
    }

    private func leave(_ stage: ConsoleLoadingStage) {
        stopTrace.record(.console, stage.cancelledFrom)
        store.send(.view(.leaveStream))
    }
}

/// Shows an `AlertState` as the app's controller-friendly confirmation card instead of a system alert.
///
/// The first button with the cancel role becomes the card's cancel button and the first other button its
/// confirm button, destructive when its role is. Choosing a button sends its action; dismissing the card in
/// any other way sends `nil`.
public struct AppAlertPresentation<Action: Equatable>: ViewModifier {
    /// The alert to show, or `nil` for none.
    public let alert: AlertState<Action>?

    /// An SF Symbol shown above the title.
    public let systemImage: String?

    /// Receives the chosen button's action, or `nil` when the card was dismissed without one.
    public let send: (Action?) -> Void

    /// Creates an app alert presentation.
    ///
    /// - Parameters:
    ///   - alert: The alert to show, or `nil` for none.
    ///   - systemImage: An SF Symbol shown above the title.
    ///   - send: Receives the chosen button's action, or `nil` when the card was dismissed without one.
    public init(alert: AlertState<Action>?, systemImage: String?, send: @escaping (Action?) -> Void) {
        self.alert = alert
        self.systemImage = systemImage
        self.send = send
    }

    /// Applies the presentation.
    ///
    /// - Parameter content: The view it is applied to.
    /// - Returns: The view with the presentation applied.
    public func body(content: Content) -> some View {
        content.appConfirmation(confirmation, confirm: confirm, cancel: cancel)
    }

    private var cancelButton: ButtonState<Action>? {
        alert?.buttons.first {
            $0.role == .cancel
        }
    }

    private var confirmButton: ButtonState<Action>? {
        alert?.buttons.first {
            $0.role != .cancel
        }
    }

    private var confirmation: AppConfirmation? {
        guard let alert else {
            return nil
        }
        return AppConfirmation(
            title: String(state: alert.title),
            message: alert.message.map { String(state: $0) },
            systemImage: systemImage,
            confirmTitle: confirmButton.map { String(state: $0.label) },
            cancelTitle: cancelButton.map { String(state: $0.label) } ?? "Cancel",
            tone: confirmButton?.role == .destructive
                ? .destructive
                : .standard
        )
    }

    private func confirm() {
        guard let confirmButton else {
            send(nil)
            return
        }
        confirmButton.withAction(send)
    }

    private func cancel() {
        guard let cancelButton else {
            send(nil)
            return
        }
        cancelButton.withAction(send)
    }
}
