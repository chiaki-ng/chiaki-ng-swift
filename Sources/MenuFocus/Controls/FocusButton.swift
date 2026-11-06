import CoreGraphics
import DesignSystem
import SwiftUI

/// The app's standard button: a SwiftUI `Button` that is also a controller focus stop.
///
/// It grows and tints while hovered or focused (``InteractiveGrowth``), activates on Return and Space, and
/// sends arrow presses to ``SwiftUICore/EnvironmentValues/menuMove`` or the key view order
/// (``MenuButtonFocus``). Bind it to a focus state with ``SwiftUICore/View/menuFocused(_:equals:)``. Use a plain
/// SwiftUI `Button` with `.focusable(false)` only for pointer-only affordances that duplicate something
/// focus can already reach.
public struct FocusButton<Label: View>: View {
    private let role: ButtonRole?
    private let action: () -> Void
    private let label: () -> Label

    /// Creates a button with a custom label.
    ///
    /// - Parameters:
    ///   - role: The button's role, such as destructive.
    ///   - action: Runs when the button is activated.
    ///   - label: The button's label.
    public init(
        role: ButtonRole? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.role = role
        self.action = action
        self.label = label
    }

    /// The SwiftUI button with the focus behaviour applied.
    public var body: some View {
        Button(role: role, action: action) {
            label()
                .contentShape(.rect)
        }
        .interactiveGrowth()
        .modifier(MenuButtonFocus(activate: action))
    }
}

extension FocusButton where Label == Text {
    /// Creates a button with a localized text label.
    ///
    /// - Parameters:
    ///   - titleKey: The label's localization key.
    ///   - role: The button's role.
    ///   - action: Runs when the button is activated.
    public init(_ titleKey: LocalizedStringKey, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) {
            Text(titleKey, bundle: .main)
        }
    }

    /// Creates a button with a text label.
    ///
    /// - Parameters:
    ///   - title: The label.
    ///   - role: The button's role.
    ///   - action: Runs when the button is activated.
    public init<S: StringProtocol>(_ title: S, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) {
            Text(verbatim: chiakiLocalized(String(title)))
        }
    }
}

extension FocusButton where Label == SwiftUI.Label<Text, Image> {
    /// Creates a button with a localized title and an SF Symbol.
    ///
    /// - Parameters:
    ///   - titleKey: The title's localization key.
    ///   - systemImage: The SF Symbol name.
    ///   - role: The button's role.
    ///   - action: Runs when the button is activated.
    public init(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.init(role: role, action: action) {
            SwiftUI.Label {
                Text(titleKey, bundle: .main)
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }

    /// Creates a button with a title and an SF Symbol.
    ///
    /// - Parameters:
    ///   - title: The title.
    ///   - systemImage: The SF Symbol name.
    ///   - role: The button's role.
    ///   - action: Runs when the button is activated.
    public init<S: StringProtocol>(
        _ title: S,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.init(role: role, action: action) {
            SwiftUI.Label {
                Text(verbatim: chiakiLocalized(String(title)))
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }
}

/// The hover, focus and press response of a control: it grows slightly, brightens, tints in the accent
/// colour and rises above its neighbours.
///
/// Focus is shown only in controller mode. Growth is capped by ``GrowthLimit`` so large controls do not
/// balloon, and is skipped under Reduce Motion, inside tight tracks (``SwiftUICore/View/focusWithoutGrowth()``)
/// and where the control draws its own highlight. On iOS a finger resting on the control presses it in.
/// Apply it with ``SwiftUICore/View/interactiveGrowth()``.
public struct InteractiveGrowth: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.menuItemFocused) private var menuItemFocused
    @Environment(\.inputMode) private var inputMode
    @Environment(\.focusGlowDrawnOutside) private var drawnOutside
    @Environment(\.focusGrowthSuppressed) private var growthSuppressed
    @Environment(\.menuNavigator) private var navigator
    @State private var hovering = false

    /// Creates the modifier.
    public init() {
    }

    private var focusShown: Bool {
        inputMode.shows(isFocused || menuItemFocused)
    }

    /// Applies the growth, brightness, tint and stacking for the control's state.
    ///
    /// - Parameter content: The control.
    /// - Returns: The control responding to hover, focus and touch.
    public func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .brightness(brightness)
            .modifier(ButtonFocusTint(opacity: tintOpacity))
            .visualEffect { [scale, touch, reduceMotion] content, proxy in
                let pressed = touch.map(proxy.frame(in: .global).contains) ?? false
                return content
                    .scaleEffect(GrowthLimit.scale(scale, for: proxy.size, pressed: pressed && !reduceMotion))
                    .brightness(GrowthLimit.brightness(pressed: pressed))
            }
            .zIndex(zIndex)
            .animation(animation, value: touch)
            .animation(animation, value: highlighted)
            .animation(animation, value: focusShown)
            .onHover { value in
                hovering = value
            }
    }

    private var touch: CGPoint? {
        #if os(iOS)
            guard isEnabled else {
                return nil
            }
            return navigator?.touchPress.location
        #else
            return nil
        #endif
    }

    private var scale: CGFloat {
        guard isEnabled, highlighted, !reduceMotion, !drawnOutside, !growthSuppressed else {
            return 1
        }
        if focusShown {
            return 1.055
        }
        return 1.035
    }

    private var brightness: Double {
        guard isEnabled, highlighted, !drawnOutside else {
            return 0
        }
        if focusShown {
            return reduceMotion
                ? 0.09
                : 0.075
        }
        if reduceMotion {
            return 0.055
        }
        return 0.025
    }

    private var zIndex: Double {
        if isEnabled, highlighted {
            return 1
        }
        return 0
    }

    private var tintOpacity: Double {
        guard isEnabled else {
            return 0
        }
        if focusShown {
            return 0.16
        }
        return hovering
            ? 0.09
            : 0
    }

    private var animation: Animation? {
        if reduceMotion {
            return .easeOut(duration: 0.1)
        }
        return .spring(duration: 0.2, bounce: 0.18)
    }

    private var highlighted: Bool {
        hovering || focusShown
    }
}

extension View {
    /// Makes the view grow, brighten and show the focus outline while hovered or focused.
    ///
    /// - Returns: The view with ``InteractiveGrowth`` applied.
    public func interactiveGrowth() -> some View {
        modifier(InteractiveGrowth())
    }
}

/// The limits on how much a hovered, focused or pressed control changes size and brightness.
public enum GrowthLimit {
    /// The most points a control may grow along its longer side.
    public static let maximumGrowth: CGFloat = 14

    /// The scale of a control held down by a finger.
    public static let pressedScale: CGFloat = 0.955

    /// The extra brightness of a control held down by a finger.
    public static let pressedBrightness = 0.07

    /// The scale to draw a control at.
    ///
    /// - Parameters:
    ///   - scale: The requested growth.
    ///   - size: The control's size.
    ///   - pressed: Whether a finger is holding the control down.
    /// - Returns: ``pressedScale`` while pressed, otherwise the growth capped by ``scale(_:for:)``.
    public static func scale(_ scale: CGFloat, for size: CGSize, pressed: Bool) -> CGFloat {
        if pressed {
            return pressedScale
        }
        return Self.scale(scale, for: size)
    }

    /// The extra brightness of a pressed control.
    ///
    /// - Parameter pressed: Whether a finger is holding the control down.
    /// - Returns: ``pressedBrightness`` while pressed, otherwise zero.
    public static func brightness(pressed: Bool) -> Double {
        pressed
            ? pressedBrightness
            : 0
    }

    /// Caps a growth so the control's longer side grows by at most ``maximumGrowth`` points.
    ///
    /// - Parameters:
    ///   - scale: The requested growth.
    ///   - size: The control's size.
    /// - Returns: The capped scale; shrinking scales pass through unchanged.
    public static func scale(_ scale: CGFloat, for size: CGSize) -> CGFloat {
        let extent = max(size.width, size.height)
        guard scale > 1, extent > 0 else {
            return scale
        }
        return min(scale, 1 + maximumGrowth / extent)
    }
}

/// Tints a control for hover and focus in the shape the control declares.
///
/// A control whose highlight is ``FocusHighlightShape/contained`` hands the tint down to the inner view
/// that applies ``ContainedFocusGlow``; any other control draws ``FocusGlow`` around itself.
private struct ButtonFocusTint: ViewModifier {
    /// The tint's opacity: zero at rest, more while hovered, most while focused.
    let opacity: Double
    @Environment(\.resolvedFocusHighlightShape) private var shape
    @Environment(\.controlSize) private var controlSize

    /// Draws or hands down the tint.
    ///
    /// - Parameter content: The control.
    /// - Returns: The tinted control.
    func body(content: Content) -> some View {
        if shape == .contained {
            content.environment(\.containedFocusGlowOpacity, opacity)
        } else {
            content.modifier(FocusGlow(shape: shape.resolved(for: controlSize), opacity: opacity))
        }
    }
}

/// Makes a button a controller focus stop: focusable, activated by Return and Space, and moved by arrows.
///
/// Arrow presses go to ``SwiftUICore/EnvironmentValues/menuMove`` when a view set one, otherwise to the next or
/// previous control in key view order. Under ``SwiftUICore/EnvironmentValues/settingsMenuFocus`` the button
/// also tracks its own focus so the highlight shows without a bound focus value.
public struct MenuButtonFocus: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.menuMove) private var menuMove
    @Environment(\.settingsMenuFocus) private var settingsMenuFocus
    @Environment(\.menuNavigator) private var navigator
    @MenuFocusState private var focused: Bool
    private let activate: () -> Void

    /// Creates the modifier.
    ///
    /// - Parameter activate: Runs when the button is activated from the keyboard or controller.
    public init(activate: @escaping () -> Void) {
        self.activate = activate
    }

    /// Adds focusability and the key handlers.
    ///
    /// - Parameter content: The button.
    /// - Returns: The button as a focus stop.
    public func body(content: Content) -> some View {
        let button = content
            .menuFocusable(enabled)
            .focusEffectDisabled()
            .onMenuKeyPress(keys: [.return, .space], phases: .down) { _ in
                guard enabled else {
                    return .ignored
                }
                activate()
                return .handled
            }
            .onMenuKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: .down) { press in
                guard enabled, let direction = MenuMoveDirection(press.key) else {
                    return .ignored
                }
                if let menuMove {
                    menuMove(direction)
                } else {
                    navigator?.move(backward: direction.isBackward)
                }
                return .handled
            }
        if settingsMenuFocus {
            button
                .menuFocusBinding($focused)
                .environment(\.menuItemFocused, focused)
        } else {
            button
        }
    }
}
