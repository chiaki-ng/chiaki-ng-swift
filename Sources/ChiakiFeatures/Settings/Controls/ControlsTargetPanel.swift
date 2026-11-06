import ChiakiClients
import ChiakiModels
import ComposableArchitecture
import DesignSystem
import MenuFocus
import SwiftUI

/// The bindings of whatever the Controls pane shows: the preset and what it applies to, the undo line, the
/// binding board and, while a control listens, the capture bar; then the keyboard's or the controller's own
/// settings.
struct ControlsTargetPanel: View {
    /// The controls settings feature the panel reads and edits.
    @Bindable var store: StoreOf<ControlsSettingsFeature>

    /// The focus of the preset name field.
    let nameFocus: MenuFocusState<Bool>.Binding

    /// Whether the preset name field has focus, read when the panel draws.
    let nameFocused: Bool

    @State private var keyboardTab = 0

    /// Draws the panel.
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if let change = store.change {
                ControlsChangeBanner(change: change) {
                    store.send(.undoChange(change.id))
                }
            }
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
                changed: changed
            ) { control in
                listen(for: control)
            }
            if let capture = store.capture {
                ControlsCaptureBar(
                    capture: capture,
                    controller: controllerName,
                    canListen: store.canListen,
                    tap: { code in
                        store.send(.captured(capture.id, code, ""))
                    },
                    clear: {
                        store.send(.clearBinding(
                            capture.target,
                            source: capture.source,
                            owner: store.editing
                        ))
                    },
                    cancel: {
                        store.send(.cancelCapture)
                    }
                )
            }
            extras
        }
        .padding(24)
        .settingsPanel()
        .disabled(!store.isEditable)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                description.frame(maxWidth: .infinity, alignment: .leading)
                picker.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 16) {
                description
                picker
            }
        }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(note).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: 520, alignment: .leading)
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        switch store.editing {
        case .controller(let key) where !store.state.isConnected(key):
            FocusButton("Forget this controller", systemImage: "trash") {
                store.send(.forgetController(key))
            }
            .glassControlStyle()
            .padding(.top, 4)
        case .player(let player):
            VStack(alignment: .leading, spacing: 10) {
                if player == 0 {
                    ControlsPlayerOneControllerPicker(store: store)
                }
                if store.draft.playerPreset(player) != nil {
                    FocusButton("Use each controller’s bindings") {
                        store.send(.removePlayerPreset(player))
                    }
                    .glassControlStyle()
                }
            }
            .padding(.top, 4)
        default:
            EmptyView()
        }
    }

    private var picker: some View {
        ControlsPresetPicker(
            store: store,
            preset: store.editingPreset,
            target: store.editing,
            nameFocus: nameFocus,
            nameFocused: nameFocused
        )
    }

    @ViewBuilder private var extras: some View {
        switch store.editing {
        case .keyboard:
            ControlsKeyboardMouseSection(store: store, preset: store.editingPreset, tab: $keyboardTab)
        case .controller(let key):
            if let device = store.state.device(key) {
                ControllerSettingsCard(
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
                .id(key)
            }
        case .player:
            EmptyView()
        }
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

    private var controllerName: String? {
        guard case .controller = store.editing else {
            return nil
        }
        return store.editingDevice?.name
    }

    private var title: String {
        switch store.editing {
        case .keyboard:
            "Keyboard and mouse"
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
                return "This controller isn’t connected. You can still change its bindings: choose an action, "
                    + "then tap the button you want."
            }
            guard store.draft.ownsPreset(key) else {
                return "Choose an action, then press the button you want for it. Your first change saves a "
                    + "preset just for this controller."
            }
            return "Choose an action, then press the button you want for it. A player’s own bindings take "
                + "priority over these."
        case .player(let player):
            guard store.draft.playerPreset(player) != nil else {
                return "Player \(player + 1) uses each controller’s own bindings. Your first change gives them "
                    + "bindings of their own, used whichever controller they hold."
            }
            return "These bindings follow player \(player + 1) whichever controller they hold."
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
}

/// The bar under the binding board while a control listens: what to press, Clear and Cancel, and for a
/// controller a row of its buttons to tap, which is the only way to bind one that is not connected.
private struct ControlsCaptureBar: View {
    /// The capture.
    let capture: ControlsCapture

    /// The name of the controller the button comes from, or `nil` for any connected controller.
    let controller: String?

    /// Whether a press on a real controller or key can be heard.
    let canListen: Bool

    /// Binds a tapped button.
    let tap: (Int) -> Void

    /// Removes the control's input.
    let clear: () -> Void

    /// Stops listening.
    let cancel: () -> Void

    @Environment(\.screenLayout) private var layout
    @MenuFocusState private var focus: Int?

    /// Draws the bar.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(instruction).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                FocusButton("Clear", action: clear).glassControlStyle()
                FocusButton("Cancel", action: cancel).glassControlStyle()
            }
            if capture.source == .gamepadButton {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: glyphSide), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(buttons, id: \.self) { code in
                        let glyph = ControllerGlyphs.button(
                            code,
                            family: capture.family,
                            layout: capture.layout
                        )
                        FocusButton {
                            tap(code)
                        } label: {
                            ControllerGlyphLabel(
                                glyph: glyph,
                                showsName: glyph.symbol == nil || !layout.hoverAffordances
                            )
                            .font(.title3)
                            .frame(minWidth: glyphSide, minHeight: 32)
                        }
                        .glassControlStyle()
                        .menuFocused($focus, equals: code)
                        .help(glyph.name)
                    }
                }
            }
        }
        .padding(16)
        .background(Palette.accent.opacity(0.08), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.accent.opacity(0.35))
        }
        .accessibilityElement(children: .contain)
    }

    private var glyphSide: CGFloat {
        max(44, layout.controlSize)
    }

    private var instruction: String {
        let control = capture.target.label
        switch capture.source {
        case .macKey, .mouseButton:
            return "Press the key for \(control). Escape cancels."
        case .gamepadButton:
            guard canListen else {
                return "Tap the button you want for \(control)."
            }
            guard let controller else {
                return "Press a button for \(control) on any controller, or tap one below."
            }
            return "Press a button for \(control) on \(controller), or tap one below. Hold any button to cancel."
        }
    }

    private var buttons: [Int] {
        switch capture.family {
        case .playStation:
            Array(0...15) + [20]
        case .xbox, .nintendo:
            Array(0...15)
        case .generic:
            Array(0..<ControllerGlyphs.buttonCount)
        }
    }
}

/// The line that says what the latest binding change did, with a button that undoes it.
private struct ControlsChangeBanner: View {
    /// The change.
    let change: ControlsChange

    /// Undoes it.
    let undo: () -> Void

    /// Draws the banner.
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.sentence(for: change))
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            FocusButton("Undo", action: undo)
                .glassControlStyle()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    /// Words a change in one or two sentences, naming any control that swapped inputs and any preset it
    /// created.
    ///
    /// - Parameter change: The change.
    /// - Returns: The sentences.
    static func sentence(for change: ControlsChange) -> String {
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
            base = "\(name(binding)) moved from \(displaced.label). \(displaced.label) now uses \(name(exchanged))."
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

/// The Controls tab's preset picker, with duplicating, renaming, resetting and deleting the shown preset.
private struct ControlsPresetPicker: View {
    /// The controls settings feature the picker reads and edits.
    let store: StoreOf<ControlsSettingsFeature>

    /// The preset the tab shows.
    let preset: InputPreset

    /// Whose preset is shown: the keyboard's, a controller's or a player's.
    let target: ControlsEditTarget

    /// The focus of the preset name field.
    let nameFocus: MenuFocusState<Bool>.Binding

    /// Whether the preset name field has focus, read when the tab draws.
    let nameFocused: Bool

    /// The picker, the Duplicate button and the preset's management controls.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Preset")
                Picker("Preset", selection: selection) {
                    ForEach(store.draft.presets) {
                        Text(chiakiLocalizedPresetName($0.name)).tag($0.id)
                    }
                }
                .labelsHidden()
                .nativeFocusHighlight()
                FocusButton("Duplicate", systemImage: "square.on.square") {
                    store.send(.duplicatePreset(preset.id, for: target))
                }
                .glassControlStyle()
                .disabled(store.draft.presets.count >= ControlsConfiguration.presetLimit)
            }
            DisclosureGroup("Manage preset") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Preset name", text: name)
                        .textFieldStyle(.plain).padding(10)
                        .menuFocusBinding(nameFocus)
                        .controllerKeyboard(
                            title: "Preset name",
                            text: name,
                            isFocused: nameFocused
                        )
                        .glassPanel(.small)
                    FocusButton("Reset bindings") {
                        store.send(.resetPresetBindings(preset.id))
                    }
                    FocusButton("Delete preset", role: .destructive) {
                        store.send(.deletePreset(preset.id))
                    }
                    .disabled(store.draft.presets.count == 1)
                }
                .padding(.top, 10)
                .glassControlStyle()
            }
            .disclosureGroupStyle(PictureDisclosureStyle())
            .font(.callout).foregroundStyle(.secondary)
        }
        .disabled(!store.isEditable)
    }

    private var selection: Binding<UUID> {
        Binding(
            get: {
                preset.id
            },
            set: { id in
                store.send(.selectPreset(id, for: target))
            }
        )
    }

    private var name: Binding<String> {
        Binding(
            get: {
                preset.name
            },
            set: { name in
                store.send(.renamePreset(preset.id, name))
            }
        )
    }
}
