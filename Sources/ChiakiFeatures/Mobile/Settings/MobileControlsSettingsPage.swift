import ChiakiClients
import ChiakiModels
import ComposableArchitecture
import DesignSystem
import MenuFocus
import PlatformUI
import SwiftUI

/// The touch Controls settings page: every remembered controller and players 1 to 4, the bindings of the one
/// chosen on the binding board, then that controller's own settings and the shared shortcuts and lights.
///
/// Every change is saved as it is made and the latest can be undone.
struct MobileControlsSettingsPage: View {
    /// The settings feature that owns the controls settings.
    let settings: StoreOf<SettingsFeature>

    /// Creates the page.
    ///
    /// - Parameter settings: The settings feature that owns the controls settings.
    init(settings: StoreOf<SettingsFeature>) {
        self.settings = settings
    }

    var body: some View {
        MobileControlsForm(store: settings.scope(state: \.controls, action: \.controls))
    }
}

/// The groups of the Controls page, bound to the controls settings feature.
private struct MobileControlsForm: View {
    /// The controller layer that captures a button for a binding.
    @Environment(\.controllerNavigation) var controllerNavigation

    /// The controls settings feature the page reads and edits.
    @Bindable var store: StoreOf<ControlsSettingsFeature>

    @State private var buttonCaptureID: UUID?
    @State private var keyboardTab = 0
    @State private var mappingTab = MobileControlsMappingTab.buttons
    @Environment(\.screenLayout) private var layout
    @Environment(\.touchKeyboard) private var touchKeyboard

    private static let buttonChoices = Array(0...20)

    var body: some View {
        Group {
            if store.showsMapping {
                mapping
            } else {
                MobileSettingsForm {
                    players
                    controllers
                    shared
                } trailing: {
                    selection
                }
            }
        }
        .background(KeyBindingCapture(capture: keyCapture) { id, code, label in
            store.send(.captured(id, code, label))
        } cancel: {
            store.send(.cancelCapture)
        })
        .task {
            let clock = ContinuousClock()
            while !Task.isCancelled {
                store.send(.refreshDevices)
                try? await clock.sleep(for: .seconds(1))
            }
        }
        .onChange(of: buttonCapture?.id, initial: true) { _, _ in
            updateButtonCapture()
        }
        .onChange(of: store.canListen) { _, _ in
            updateButtonCapture()
        }
        .onChange(of: store.showsMapping) { _, _ in
            mappingTab = .buttons
        }
        .onAppear {
            store.send(.appeared)
            #if !os(macOS)
                if store.editing == .keyboard {
                    store.send(.show(.player(0)))
                }
            #endif
        }
        .onDisappear {
            endButtonCapture()
            store.send(.stop)
        }
    }

    private var players: some View {
        MobileSettingsGroup(
            "Players",
            footer: "Touch controls and the on-screen touchpad belong to player 1, and the console sends "
                + "haptics only to player 1’s controller."
        ) {
            ForEach(0..<ControlsConfiguration.playerCount, id: \.self) { player in
                MobileControlsTargetRow(
                    title: "Player \(player + 1)",
                    detail: playerLines(player).joined(separator: "\n"),
                    selected: store.editing == .player(player),
                    tag: player == 0 && playsWithTouch
                        ? "Touch"
                        : nil
                ) {
                    MobileControlsPlayerBadge(player: player)
                } choose: {
                    store.send(.show(.player(player)))
                }
            }
        }
    }

    @ViewBuilder private var controllers: some View {
        if !devices.isEmpty {
            MobileSettingsGroup("Controllers") {
                ForEach(devices, id: \.preferenceKey) { device in
                    deviceRow(device)
                }
            }
        }
    }

    @ViewBuilder private var selection: some View {
        if let change = store.change {
            MobileSettingsGroup {
                changeRow(change)
            }
            .disabled(!store.isEditable)
        }
        switch store.editing {
        case .keyboard:
            bindingsGroup(title: "Keyboard and Mouse")
            MobileSettingsGroup("Keyboard and Mouse") {
                ControlsKeyboardMouseSection(store: store, preset: store.editingPreset, tab: $keyboardTab)
                    .padding(16)
            }
            .disabled(!store.isEditable)
        case .player(let player) where player == 0:
            playerOne
            bindingsGroup(title: "Bindings")
        case .player(let player):
            bindingsGroup(
                title: "Player \(player + 1)",
                lead: "Player \(player + 1) joins by pressing the PS button on a controller during a stream."
            )
        case .controller(let key):
            bindingsGroup(title: targetTitle)
            if let device = store.state.device(key) {
                MobileControllerSettings(
                    device: device,
                    preferences: store.draft.controllers[key] ?? .init(),
                    preset: store.editingPreset,
                    update: { value in
                        store.send(.setControllerPreferences(key, value))
                    },
                    test: { strength in
                        store.send(.testRumble(device.id, strength))
                    },
                    connected: store.state.isConnected(key),
                    lightbar: store.draft.lightbar
                )
                .disabled(!store.isEditable)
                .id(key)
            }
        }
    }

    private var playerOne: some View {
        MobileSettingsGroup("Player 1", footer: playerOneNote) {
            MobilePickerRow("Plays With", selection: $store.draft.selectedControllerKey) {
                Text("First available controller").tag(String?.none)
                Text(ControlsPlayerOneControllerPicker.withoutControllerTitle)
                    .tag(Optional(ControlsConfiguration.keyboardOnlyKey))
                ForEach(store.listedDevices.filter { !$0.isKeyboard }, id: \.preferenceKey) { device in
                    Text(device.name).tag(Optional(device.preferenceKey))
                }
            }
            #if !os(macOS)
                MobilePickerRow("Touch Controls", selection: $store.draft.virtualGamepad) {
                    Text("Automatic").tag(VirtualGamepadPresence.automatic)
                    Text("Always").tag(VirtualGamepadPresence.shown)
                    Text("Off").tag(VirtualGamepadPresence.hidden)
                }
                MobileToggleRow("On-Screen Touchpad", isOn: edited(\.onScreenTouchpad))
                MobileToggleRow(
                    "Motion Controls",
                    detail: "Turning and tilting this device moves the game’s motion controls.",
                    isOn: edited(\.deviceMotion)
                )
            #endif
        }
        .disabled(!store.isEditable)
    }

    private func bindingsGroup(title: String, lead: String? = nil) -> some View {
        MobileSettingsGroup(
            title,
            footer: [lead, note].compactMap(\.self).joined(separator: " ")
        ) {
            MobileValueRow("Button Mapping", value: chiakiLocalizedPresetName(store.editingPreset.name)) {
                store.send(.openMapping(store.editing))
            }
            MobilePickerRow("Preset", selection: presetSelection) {
                ForEach(store.draft.presets) { preset in
                    Text(chiakiLocalizedPresetName(preset.name)).tag(preset.id)
                }
            }
            if case .player(let player) = store.editing, store.draft.playerPreset(player) != nil {
                MobileButtonRow("Use Each Controller’s Bindings") {
                    store.send(.removePlayerPreset(player))
                }
            }
            if case .controller(let key) = store.editing, !store.state.isConnected(key) {
                MobileButtonRow("Forget This Controller", destructive: true) {
                    store.send(.forgetController(key))
                }
            }
        }
        .disabled(!store.isEditable)
    }

    @ViewBuilder private var shared: some View {
        touchpadGroup
            .disabled(!store.isEditable)
        streamMenuGroup
            .disabled(!store.isEditable)
        MobileLightbarGroup(
            title: "Light Bar",
            note: "Applies to every controller that doesn’t have its own light bar setting.",
            value: store.draft.lightbar,
            inherited: nil
        ) { value in
            var draft = store.draft
            draft.lightbar = value ?? .followGame
            store.send(.edit(draft))
        }
        .disabled(!store.isEditable)
        #if os(macOS)
            MobileSettingsGroup(
                "Background",
                footer: "Controllers keep playing the stream while another app is in front. The keyboard and "
                    + "mouse only reach the stream while its window is active."
            ) {
                MobileToggleRow(
                    "Keep Controllers Working When chiaki-ng Is in the Background",
                    isOn: edited(\.backgroundInput)
                )
            }
            .disabled(!store.isEditable)
        #endif
        if let message = store.notice.message {
            Label(message, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        SettingsPersistenceBanner(store.setting, subject: "controls", reportsInvalid: false) {
            store.send(.retry)
        }
        .padding(.horizontal, 16)
    }

    private var touchpadGroup: some View {
        MobileSettingsGroup(
            "Touchpad Shortcut",
            footer: store.draft.onScreenTouchpad
                ? "Press these controller buttons together during a stream to open the on-screen touchpad."
                : "The on-screen touchpad is off for player 1, so it never appears over the stream."
        ) {
            MobileToggleRow("Controller Combo", isOn: touchpadCombo)
            if store.draft.touchpadShortcut.buttons.count >= 2 {
                MobilePickerRow("First Button", selection: touchpadButton(0)) {
                    buttonOptions
                }
                MobilePickerRow("Second Button", selection: touchpadButton(1)) {
                    buttonOptions
                }
            }
        }
        .disabled(!store.draft.onScreenTouchpad)
    }

    private var streamMenuGroup: some View {
        MobileSettingsGroup(
            "Stream Menu",
            footer: "Press these controller buttons together during a stream to open the stream menu."
        ) {
            ForEach(0..<StreamMenuShortcut.buttonLimit.upperBound, id: \.self) { slot in
                MobilePickerRow("Button \(slot + 1)", selection: streamMenuButton(slot)) {
                    if slot >= StreamMenuShortcut.buttonLimit.lowerBound {
                        Text("Not used").tag(StreamMenuShortcutCard.unused)
                    }
                    buttonOptions
                }
            }
        }
    }

    private var buttonOptions: some View {
        ForEach(Self.buttonChoices, id: \.self) { code in
            Text(BindingRow.buttonName(code)).tag(code)
        }
    }

    private func deviceRow(_ device: ControllerDevice) -> some View {
        let target = device.isKeyboard
            ? ControlsEditTarget.keyboard
            : .controller(device.preferenceKey)
        let connected = device.isKeyboard || store.state.isConnected(device.preferenceKey)
        return MobileControlsTargetRow(
            title: title(for: device),
            detail: lines(for: device, connected: connected).joined(separator: "\n"),
            selected: store.editing == target
        ) {
            deviceThumbnail(device)
                .opacity(
                    connected
                        ? 1
                        : 0.45
                )
        } choose: {
            store.send(.show(target))
        }
    }

    @ViewBuilder private func deviceThumbnail(_ device: ControllerDevice) -> some View {
        if device.isKeyboard {
            Image(systemName: "keyboard")
                .font(.title3)
                .foregroundStyle(.secondary)
        } else if let image = ControllerArtwork.of(device).image {
            Image(platformImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "gamecontroller")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func changeRow(_ change: ControlsChange) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.sentence(for: change))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo") {
                store.send(.undoChange(change.id))
            }
            .buttonStyle(.borderless)
            .tint(Palette.accent)
        }
        .mobileRowPadding()
        .accessibilityElement(children: .contain)
    }

    private var mapping: some View {
        VStack(alignment: .leading, spacing: 12) {
            mappingHeader
            Group {
                if let capture = store.capture, capture.source == .gamepadButton, !store.canListen {
                    captureChoices(capture)
                } else {
                    switch mappingTab {
                    case .buttons:
                        board(.picture)
                    case .others:
                        ScrollView {
                            board(.others)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, MobilePageTitle.topPadding(layout) - 12)
        .padding(.bottom, max(12, layout.bottomInset))
        .disabled(!store.isEditable)
    }

    private func board(_ part: ControlsBindingBoard.Part) -> some View {
        ControlsBindingBoard(
            preset: store.editingPreset,
            source: store.editing == .keyboard
                ? .macKey
                : .gamepadButton,
            artwork: store.editing == .keyboard
                ? .dualSense
                : ControllerArtwork.of(store.editingDevice ?? store.playerDevice),
            family: store.editingFamily,
            layout: store.editingLayout,
            listening: store.capture?.target,
            changed: changed,
            select: listen(for:),
            part: part
        )
    }

    private var mappingHeader: some View {
        HStack(spacing: 12) {
            Button {
                store.send(.closeMapping)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 1) {
                Text("Button Mapping")
                    .font(.title3.bold())
                Text(mappingSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if let capture = store.capture {
                captureControls(capture)
            } else {
                mappingControls
            }
        }
    }

    @ViewBuilder private var mappingControls: some View {
        if store.editing != .keyboard {
            Picker("Controls", selection: $mappingTab) {
                Text("Buttons").tag(MobileControlsMappingTab.buttons)
                Text("More").tag(MobileControlsMappingTab.others)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        if let change = store.change {
            Button("Undo") {
                store.send(.undoChange(change.id))
            }
            .buttonStyle(.glass)
            .accessibilityHint(Self.sentence(for: change))
        }
        presetMenu
    }

    private var presetMenu: some View {
        Menu {
            Picker("Preset", selection: presetSelection) {
                ForEach(store.draft.presets) { preset in
                    Text(chiakiLocalizedPresetName(preset.name)).tag(preset.id)
                }
            }
            Divider()
            Button("Duplicate Preset", systemImage: "plus.square.on.square") {
                store.send(.duplicatePreset(store.editingPreset.id, for: store.editing))
            }
            .disabled(store.draft.presets.count >= ControlsConfiguration.presetLimit)
            if let touchKeyboard {
                Button("Rename Preset", systemImage: "pencil") {
                    touchKeyboard(TouchKeyboardRequest(
                        title: "Preset Name",
                        prompt: "Preset name",
                        text: presetName
                    ))
                }
            }
            Button("Reset Bindings", systemImage: "arrow.counterclockwise") {
                store.send(.resetPresetBindings(store.editingPreset.id))
            }
            Button("Delete Preset", systemImage: "trash", role: .destructive) {
                store.send(.deletePreset(store.editingPreset.id))
            }
            .disabled(store.draft.presets.count == 1)
        } label: {
            Label(chiakiLocalizedPresetName(store.editingPreset.name), systemImage: "chevron.up.chevron.down")
                .labelStyle(MobileControlsTrailingIconLabel())
                .lineLimit(1)
                .frame(maxWidth: 160)
        }
        .buttonStyle(.glass)
    }

    private func captureControls(_ capture: ControlsCapture) -> some View {
        HStack(spacing: 10) {
            Text(listeningPrompt(for: capture))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Button("Clear") {
                store.send(.clearBinding(capture.target, source: capture.source, owner: store.editing))
            }
            .buttonStyle(.glass)
            Button("Cancel") {
                store.send(.cancelCapture)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .foregroundStyle(.black)
        }
    }

    private func captureChoices(_ capture: ControlsCapture) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
            ForEach(captureButtons(for: capture), id: \.self) { code in
                let glyph = ControllerGlyphs.button(code, family: capture.family, layout: capture.layout)
                Button {
                    store.send(.captured(capture.id, code, ""))
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: glyph.symbol ?? "circle.dashed")
                            .font(.title3)
                            .opacity(
                                glyph.symbol == nil
                                    ? 0
                                    : 1
                            )
                        Text(glyph.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(.rect(cornerRadius: 16))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .accessibilityLabel(glyph.name)
            }
        }
    }

    private func listeningPrompt(for capture: ControlsCapture) -> String {
        guard capture.source == .gamepadButton, !store.canListen else {
            return "Press a button for \(capture.target.label)"
        }
        return "Choose a button for \(capture.target.label)"
    }

    private var mappingSubtitle: String {
        switch store.editing {
        case .keyboard:
            return "Keyboard"
        case .controller:
            return targetTitle
        case .player(let player):
            guard let device = store.playerDevice else {
                return "Player \(player + 1)"
            }
            return "Player \(player + 1) · \(device.name)"
        }
    }

    private var playsWithTouch: Bool {
        store.draft.selectedControllerKey == ControlsConfiguration.keyboardOnlyKey
    }
}

/// Which controls the touch Button Mapping screen shows: the drawing's buttons, or the sticks, touchpad halves
/// and gyro hold that have no place on it.
enum MobileControlsMappingTab: Hashable {
    /// The buttons on the drawing.
    case buttons

    /// The controls without a place on the drawing.
    case others
}

/// A label with its icon after its title, for a menu showing its current choice.
private struct MobileControlsTrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// A player's badge in the Players list: the player's number on their light colour.
private struct MobileControlsPlayerBadge: View {
    /// The player's index, 0 for player 1.
    let player: Int

    var body: some View {
        Text("P\(player + 1)")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.black.opacity(0.85))
            .frame(width: 30, height: 30)
            .background(color.gradient, in: .rect(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch player {
        case 0:
            Palette.accent
        case 1:
            .blue
        case 2:
            .green
        default:
            .pink
        }
    }
}

extension MobileControlsForm {
    private var devices: [ControllerDevice] {
        #if os(macOS)
            store.listedDevices
        #else
            store.listedDevices.filter {
                !$0.isKeyboard
            }
        #endif
    }

    private var keyCapture: ControlsCapture? {
        guard let capture = store.capture, capture.source == .macKey else {
            return nil
        }
        return capture
    }

    private var buttonCapture: ControlsCapture? {
        guard let capture = store.capture, capture.source == .gamepadButton else {
            return nil
        }
        return capture
    }

    private var presetSelection: Binding<UUID> {
        Binding(
            get: {
                store.editingPreset.id
            },
            set: { id in
                store.send(.selectPreset(id, for: store.editing))
            }
        )
    }

    private var presetName: Binding<String> {
        Binding(
            get: {
                store.editingPreset.name
            },
            set: { name in
                store.send(.renamePreset(store.editingPreset.id, name))
            }
        )
    }

    private var touchpadCombo: Binding<Bool> {
        Binding(
            get: {
                !store.draft.touchpadShortcut.buttons.isEmpty
            },
            set: { enabled in
                store.send(.setTouchpadButtons(
                    enabled
                        ? TouchpadShortcut.standard.buttons
                        : []
                ))
            }
        )
    }

    private func touchpadButton(_ slot: Int) -> Binding<Int> {
        Binding(
            get: {
                store.draft.touchpadShortcut.buttons[slot]
            },
            set: { code in
                var buttons = store.draft.touchpadShortcut.buttons
                if let existing = buttons.firstIndex(of: code), existing != slot {
                    buttons.swapAt(existing, slot)
                } else {
                    buttons[slot] = code
                }
                store.send(.setTouchpadButtons(buttons))
            }
        )
    }

    private func streamMenuButton(_ slot: Int) -> Binding<Int> {
        let buttons = store.draft.streamMenuShortcut.buttons
        return Binding(
            get: {
                buttons.indices.contains(slot)
                    ? buttons[slot]
                    : StreamMenuShortcutCard.unused
            },
            set: { code in
                let chosen = StreamMenuShortcutCard.choosing(code, slot: slot, in: buttons)
                store.send(.setStreamMenuButtons(chosen))
            }
        )
    }

    private func edited<Value>(_ key: WritableKeyPath<ControlsConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: {
                store.draft[keyPath: key]
            },
            set: { value in
                var draft = store.draft
                draft[keyPath: key] = value
                store.send(.edit(draft))
            }
        )
    }

    private var changed: Set<PlayStationControl> {
        switch store.change?.summary {
        case .assigned(let binding):
            [binding.target]
        case let .moved(binding, from, _):
            [binding.target, from]
        case .cleared(let control):
            [control]
        case .forgot, .playerPresetRemoved, nil:
            []
        }
    }

    private func listen(for control: PlayStationControl) {
        switch store.editing {
        case .keyboard:
            store.send(.capture(control))
        case .controller:
            if let device = store.editingDevice {
                store.send(.captureControllerButton(device, control))
            }
        case .player(let player):
            store.send(.capturePlayerButton(player, control))
        }
    }

    private func updateButtonCapture() {
        endButtonCapture()
        guard let capture = buttonCapture, store.canListen else {
            return
        }
        let id = capture.id
        let device: UInt32? = if case .controller(let key) = store.editing {
            store.devices.first { $0.preferenceKey == key }?.id
        } else {
            nil
        }
        buttonCaptureID = controllerNavigation?.beginButtonCapture(device: device) { outcome in
            switch outcome {
            case .assign(let code):
                store.send(.captured(id, code, ""))
            case .cancel:
                store.send(.cancelCapture)
            }
        }
    }

    private func endButtonCapture() {
        if let buttonCaptureID {
            controllerNavigation?.endButtonCapture(buttonCaptureID)
        }
        buttonCaptureID = nil
    }
}

extension MobileControlsForm {
    private var targetTitle: String {
        switch store.editing {
        case .keyboard:
            "Keyboard and Mouse"
        case .controller:
            store.editingDevice?.name ?? "Controller"
        case .player(let player):
            "Player \(player + 1)"
        }
    }

    private var note: String {
        switch store.editing {
        case .keyboard:
            return "The keyboard plays as player 1. Choose an action, then press the key you want for it."
        case .controller(let key):
            guard store.state.isConnected(key) else {
                return "This controller isn’t connected. You can still change its bindings: choose an "
                    + "action, then tap the button you want."
            }
            guard store.draft.ownsPreset(key) else {
                return "Choose an action, then press the button you want for it. Your first change saves a "
                    + "preset just for this controller."
            }
            return "Choose an action, then press the button you want for it. A player’s own bindings take "
                + "priority over these."
        case .player(let player):
            guard store.draft.playerPreset(player) != nil else {
                return "Player \(player + 1) uses each controller’s own bindings. Your first change gives "
                    + "them bindings of their own, used whichever controller they hold."
            }
            return "These bindings follow player \(player + 1) whichever controller they hold."
        }
    }

    private func title(for device: ControllerDevice) -> String {
        guard !device.isKeyboard else {
            return "Keyboard and mouse"
        }
        let nickname = store.draft.controllers[device.preferenceKey]?.nickname ?? ""
        return nickname.isEmpty
            ? device.name
            : nickname
    }

    private func lines(for device: ControllerDevice, connected: Bool) -> [String] {
        guard !device.isKeyboard else {
            return ["Plays as player 1"]
        }
        var lines: [String]
        if connected {
            lines = ["Connected", device.transport]
        } else if let seen = store.draft.remembered[device.preferenceKey]?.lastSeen {
            lines = ["Not connected", "Last seen \(seen.formatted(.relative(presentation: .named)))"]
        } else {
            lines = ["Not connected"]
        }
        if !device.individual {
            lines.append("Shared by every \(device.name)")
        }
        return lines
    }

    private func playerLines(_ player: Int) -> [String] {
        let bindings = store.draft.playerPreset(player) == nil
            ? "Each controller’s bindings"
            : "Own bindings"
        guard player == 0 else {
            return ["Joins with the PS button", bindings]
        }
        return [playerOneController, bindings]
    }

    private var playerOneNote: String {
        guard playsWithTouch else {
            return "Touch Controls: " + virtualGamepadNote
        }
        return "Player 1 plays with the touch controls even when a controller is connected. Controllers that "
            + "connect join as players 2 to 4."
    }

    private var playerOneController: String {
        guard let key = store.draft.selectedControllerKey else {
            return "First available controller"
        }
        if key == ControlsConfiguration.keyboardOnlyKey {
            return ControlsPlayerOneControllerPicker.withoutControllerTitle
        }
        return store.state.device(key)?.name ?? "First available controller"
    }

    private var virtualGamepadNote: String {
        switch store.draft.virtualGamepad {
        case .automatic:
            "Shown while no controller is connected. The controller button at the bottom of a stream still "
                + "shows or hides it until the stream ends."
        case .shown:
            "Shown on every stream, even with a controller connected."
        case .hidden:
            "Never shown. The controller button at the bottom of a stream can still bring it back until the "
                + "stream ends."
        }
    }

    private func captureButtons(for capture: ControlsCapture) -> [Int] {
        switch capture.family {
        case .playStation:
            Array(0...15) + [20]
        case .xbox, .nintendo:
            Array(0...15)
        case .generic:
            Array(0..<ControllerGlyphs.buttonCount)
        }
    }

    private static func sentence(for change: ControlsChange) -> String {
        let name = { (input: InputBinding) in
            input.source == .gamepadButton
                ? ControllerGlyphs.button(input.code, family: change.family, layout: change.layout).name
                : input.label
        }
        let base: String
        switch change.summary {
        case .assigned(let binding):
            base = "\(binding.target.label) is now on \(name(binding))."
        case let .moved(binding, displaced, exchanged?):
            base = "\(name(binding)) moved from \(displaced.label). "
                + "\(displaced.label) now uses \(name(exchanged))."
        case let .moved(binding, displaced, nil):
            base = "\(name(binding)) moved from \(displaced.label), which is now unbound."
        case .cleared(let control):
            base = "\(control.label) is unbound."
        case .forgot(let controller):
            base = controller.isEmpty
                ? "Forgot the controller."
                : "Forgot \(controller)."
        case .playerPresetRemoved(let player):
            base = "Player \(player + 1) uses each controller’s own bindings again."
        }
        guard let preset = change.createdPreset else {
            return base
        }
        return base + " Saved as “\(preset)”."
    }
}

/// One controller's own settings beside its bindings, in Calibration, Feedback, Adaptive Triggers, Light Bar
/// and Details groups.
///
/// A disconnected controller keeps its settings visible, but only its details can change until it is back.
private struct MobileControllerSettings: View {
    /// The controller whose capabilities decide which settings are offered.
    let device: ControllerDevice

    /// The controller's current preferences.
    let preferences: ControllerPreferences

    /// The preset whose gyro hold button the calibration caption names.
    let preset: InputPreset

    /// Called with the preferences after any calibration, feedback or detail changes.
    let update: (ControllerPreferences) -> Void

    /// Plays a rumble test at the given strength.
    let test: (Double) -> Void

    /// Whether the controller is connected; when not, only its details can change.
    let connected: Bool

    /// The light bar setting inherited when this controller does not choose its own.
    let lightbar: ControllerLightbar

    var body: some View {
        calibration
            .disabled(!connected)
        feedback
            .disabled(!connected)
        triggers
            .disabled(!connected)
        MobileLightbarGroup(
            title: "Light Bar",
            note: device.lights
                ? nil
                : "This controller has no light bar to set.",
            value: preferences.lightbar,
            inherited: lightbar,
            enabled: device.lights
        ) { value in
            var changed = preferences
            changed.lightbar = value
            update(changed)
        }
        .disabled(!connected)
        MobileSettingsGroup(
            "Details",
            footer: device.individual
                ? nil
                : "This controller has no unique identity. Preferences are shared with its model."
        ) {
            MobileTextEntryRow(title: "Nickname", prompt: "Nickname", text: binding(\.nickname))
        }
    }

    private var card: ControllerSettingsCard {
        ControllerSettingsCard(
            device: device,
            preferences: preferences,
            preset: preset,
            update: update,
            test: test,
            connected: connected,
            lightbar: lightbar
        )
    }

    private var calibration: some View {
        MobileSettingsGroup("Calibration", footer: card.stickGyroCaption) {
            slider("Stick Dead Zone", key: \.deadZone, range: 0...0.5, step: 0.01)
            MobileToggleRow("Invert Right Stick Vertically", isOn: binding(\.invertRightY))
            MobileToggleRow("Swap Left and Right Sticks", isOn: binding(\.swapSticks))
            if device.family == .nintendo {
                MobileToggleRow(
                    "Use Nintendo Button Labels",
                    detail: preferences.buttonLayout == .label
                        ? "A acts as Cross and B as Circle, so A confirms like on Switch. X and Y swap the "
                            + "same way."
                        : "Buttons work by position: the bottom button, B, acts as Cross and confirms.",
                    isOn: nintendoLabels
                )
            }
            MobilePickerRow("Right Stick Gyro", selection: binding(\.stickGyro)) {
                ForEach(StickGyroMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
    }

    private var feedback: some View {
        MobileSettingsGroup(
            "Feedback",
            footer: card.hapticsCaption + " Both strengths follow the vibration intensity set on the PS5. "
                + "The console sends haptics only to player 1's controller."
        ) {
            MobilePickerRow("Haptics", selection: binding(\.hapticFeedback)) {
                ForEach(HapticFeedback.allCases, id: \.self) { feedback in
                    Text(feedback.title).tag(feedback)
                }
            }
            .disabled(!device.nativeHaptics && !device.rumble)
            slider("Haptic Strength", key: \.hapticStrength, range: 0...2.4, step: 0.1)
                .disabled(!device.nativeHaptics && !device.rumble)
            slider("Rumble Strength", key: \.rumbleStrength, range: 0...1, step: 0.05)
                .disabled(!device.rumble)
            MobileButtonRow("Test Rumble") {
                test(preferences.rumbleStrength)
            }
            .disabled(!device.rumble)
        }
    }

    private var triggers: some View {
        MobileSettingsGroup(
            "Adaptive Triggers",
            footer: "Trigger strength never goes above the intensity set on the PS5."
        ) {
            MobileToggleRow("Adaptive Triggers", isOn: binding(\.adaptiveTriggersEnabled))
                .disabled(!device.adaptiveTriggers)
            MobilePickerRow("Trigger Strength", selection: binding(\.triggerStrength)) {
                ForEach(TriggerStrength.allCases, id: \.self) { strength in
                    Text(strength.title).tag(strength)
                }
            }
            .disabled(!device.adaptiveTriggers || !preferences.adaptiveTriggersEnabled)
        }
    }

    private var nintendoLabels: Binding<Bool> {
        Binding(
            get: {
                preferences.buttonLayout == .label
            },
            set: { enabled in
                var changed = preferences
                changed.buttonLayout = enabled
                    ? .label
                    : .position
                update(changed)
            }
        )
    }

    private func slider(
        _ title: String,
        key: WritableKeyPath<ControllerPreferences, Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        MobileSliderRow(
            title: title,
            valueText: preferences[keyPath: key].formatted(.percent.precision(.fractionLength(0))),
            value: binding(key),
            range: range,
            step: step
        )
    }

    private func binding<Value>(_ key: WritableKeyPath<ControllerPreferences, Value>) -> Binding<Value> {
        Binding(
            get: {
                preferences[keyPath: key]
            },
            set: { value in
                var changed = preferences
                changed[keyPath: key] = value
                update(changed)
            }
        )
    }
}

/// A Light Bar group: how a light bar is coloured, the colour swatches while a fixed colour is chosen, and a
/// footer explaining the result.
private struct MobileLightbarGroup: View {
    /// The group's title.
    let title: String

    /// A sentence put before the explanation, or `nil` for none.
    let note: String?

    /// The current setting, or `nil` when deferring to the setting for all controllers.
    let value: ControllerLightbar?

    /// The setting for all controllers; when `nil` this group is that setting, so the option to defer is
    /// hidden.
    let inherited: ControllerLightbar?

    /// Whether the controller has a light bar to set.
    var enabled = true

    /// Called with the new setting, `nil` meaning defer to all controllers.
    let update: (ControllerLightbar?) -> Void

    @State private var lastFixed: UInt32?

    var body: some View {
        MobileSettingsGroup(title, footer: footer) {
            MobilePickerRow("Colour", selection: mode) {
                ForEach(modes, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if case .fixed(let selected) = value {
                swatches(selected: selected)
            }
        }
        .disabled(!enabled)
        .onChange(of: value, initial: true) { _, current in
            if case .fixed(let rgb) = current {
                lastFixed = rgb
            }
        }
    }

    private var modes: [LightbarMode] {
        inherited == nil
            ? [.followGame, .fixed]
            : LightbarMode.allCases
    }

    private var mode: Binding<LightbarMode> {
        Binding(
            get: {
                LightbarMode(value)
            },
            set: { next in
                switch next {
                case .allControllers:
                    update(nil)
                case .followGame:
                    update(.followGame)
                case .fixed:
                    update(.fixed(rgb: lastFixed ?? fixedColor ?? ControllerLightbarSwatch.all[0].rgb))
                }
            }
        )
    }

    private var fixedColor: UInt32? {
        if case .fixed(let rgb) = value {
            return rgb
        }
        if case .fixed(let rgb) = inherited {
            return rgb
        }
        return nil
    }

    private var footer: String {
        let detail = switch value {
        case nil:
            inherited == .followGame
                ? "Uses the setting for all controllers, which follows the colour the game asks for."
                : "Uses the fixed colour set for all controllers."
        case .followGame:
            "The light bar shows the colour the game asks for, such as a player colour or health."
        case .fixed:
            "The light bar keeps this colour for the whole stream."
        }
        guard let note else {
            return detail
        }
        return note + " " + detail
    }

    private func swatches(selected: UInt32) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
            ForEach(ControllerLightbarSwatch.all) { swatch in
                Button {
                    update(.fixed(rgb: swatch.rgb))
                } label: {
                    swatchLabel(swatch, selected: swatch.rgb == selected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(
                    swatch.rgb == selected
                        ? .isSelected
                        : []
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func swatchLabel(_ swatch: ControllerLightbarSwatch, selected: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(
                        swatch.rgb == 0
                            ? Color.secondary.opacity(0.15)
                            : CouchLight.color(swatch.rgb) ?? .clear
                    )
                Circle()
                    .strokeBorder(.primary.opacity(0.2), lineWidth: 1)
                if swatch.rgb == 0 {
                    Image(systemName: "slash.circle")
                        .foregroundStyle(.secondary)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(
                            swatch.rgb == 0xffffff || swatch.rgb == 0
                                ? Color.primary
                                : Color.white
                        )
                }
            }
            .frame(width: 32, height: 32)
            Text(swatch.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
    }
}

/// A row choosing whose bindings are shown: a picture, a name, status lines and a check mark when chosen.
private struct MobileControlsTargetRow<Icon: View>: View {
    /// The name.
    let title: String

    /// The status lines under the name.
    let detail: String

    /// Whether the row's bindings are shown.
    let selected: Bool

    /// A short label at the trailing edge, or `nil` for none.
    var tag: String?

    /// The picture at the leading edge.
    @ViewBuilder let icon: Icon

    /// Shows the row's bindings.
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                icon
                    .frame(width: 44, height: 30)
                MobileRowTitle(title: title, detail: detail)
                Spacer(minLength: 8)
                if let tag {
                    Text(tag)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.accent, in: .capsule)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .mobileRowPadding()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
            selected
                ? .isSelected
                : []
        )
    }
}
