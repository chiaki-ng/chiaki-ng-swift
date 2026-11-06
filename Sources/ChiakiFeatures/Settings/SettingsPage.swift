import ChiakiModels
import ComposableArchitecture
import DesignSystem
import MenuFocus
import SwiftUI

/// The page of one settings tab, laid out in the tab's ``SettingsLayout``.
///
/// Pages that read their data when shown load it as they appear. The Network page adds the cloud and internet
/// settings only while an account is signed in to PlayStation Network.
struct SettingsPage: View {
    /// The settings feature that owns every tab's state.
    let store: StoreOf<SettingsFeature>

    /// The tab whose page is shown.
    let route: SettingsRoute

    /// The focus of the Network page's controls, which the settings view moves by controller.
    let networkFocus: MenuFocusState<NetworkSettingsFocus?>.Binding

    private static let signInNote = "Cloud streaming, playing over the internet and their settings need "
        + "an account signed in to PlayStation Network."

    /// The tab's page.
    var body: some View {
        SettingsLayout(route) {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .controls:
            ControlsSettingsView(store: store.scope(state: \.controls, action: \.controls))
        case .picture:
            PictureSettingsContainerView(
                console: store.scope(state: \.picture, action: \.picture),
                cloud: store.scope(state: \.cloudPicture, action: \.cloudPicture),
                psnReach: store.psnReach
            )
        case .sound:
            SoundSettingsView(store: store.scope(state: \.sound, action: \.sound))
        case .interface:
            InterfaceSettingsView(store: store.scope(state: \.interface, action: \.interface))
        case .accessibility:
            PlayStationAccessibilitySettingsView(
                store: store.scope(state: \.playStationAccessibility, action: \.playStationAccessibility)
            )
        case .network:
            networkPage
        case .remotePlayers:
            KakusanSettingsView(store: store.scope(state: \.kakusan, action: \.kakusan))
                .onAppear {
                    store.send(.kakusan(.load))
                }
        case .developer:
            LoggingSettingsView(
                logging: store.scope(state: \.logging, action: \.logging),
                developer: store.scope(state: \.developer, action: \.developer)
            )
        case .entitlements:
            EntitlementsSettingsView(store: store.scope(state: \.entitlements, action: \.entitlements))
        case .caches:
            CachesSettingsView(store: store.scope(state: \.caches, action: \.caches))
                .onAppear {
                    store.send(.caches(.load))
                }
        case .requests:
            RequestsSettingsView(store: store.scope(state: \.requests, action: \.requests))
                .onAppear {
                    store.send(.requests(.appear))
                }
                .onDisappear {
                    store.send(.requests(.disappear))
                }
        case .tokens:
            TokensSettingsView(store: store.scope(state: \.tokens, action: \.tokens))
        case .about:
            AboutSettingsView(store: store.scope(state: \.about, action: \.about))
                .onAppear {
                    store.send(.about(.load))
                }
        }
    }

    private var networkPage: some View {
        VStack(alignment: .leading, spacing: 28) {
            NetworkSettingsView(store: store.scope(state: \.network, action: \.network), focus: networkFocus)
            NatTypeSettingsView(store: store.scope(state: \.natType, action: \.natType))
            if store.psnReach == .signedIn {
                #if DEBUG
                    CloudLaunchSettingsView(store: store.scope(state: \.cloudLaunch, action: \.cloudLaunch))
                #endif
                InternetConnectionSettingsView(
                    store: store.scope(state: \.internetConnection, action: \.internetConnection)
                )
            } else {
                Text(Self.signInNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ConsolePowerSettingsView(store: store.scope(state: \.consolePower, action: \.consolePower))
            PrivacySettingsView(store: store.scope(state: \.logging, action: \.logging))
        }
    }
}

/// The scrolling scaffold of one settings page: the page title, then the page's content at a readable width.
///
/// A compact screen keeps tighter margins so the page's cards get the width.
public struct SettingsLayout<Content: View>: View {
    @Environment(\.screenLayout) private var layout
    private let route: SettingsRoute
    private let content: Content

    /// Creates the page scaffold.
    ///
    /// - Parameters:
    ///   - route: The tab the page belongs to; it supplies the title unless the page draws its own.
    ///   - content: The page.
    public init(_ route: SettingsRoute, @ViewBuilder content: () -> Content) {
        self.route = route
        self.content = content()
    }

    /// The page.
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !route.drawsOwnTitle {
                    SettingsPageTitle(route.title)
                }
                content
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .appVerticalScrollStyle()
    }

    private var horizontalPadding: CGFloat {
        layout.isCompact
            ? 20
            : 32
    }

    private var verticalPadding: CGFloat {
        layout.isCompact
            ? 16
            : 24
    }
}

/// The large title at the top of a settings page.
public struct SettingsPageTitle: View {
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage = AppLanguage.system.rawValue
    @Environment(\.screenLayout) private var layout
    private let text: String

    /// Creates a title.
    ///
    /// - Parameter text: The page's name.
    public init(_ text: String) {
        self.text = text
    }

    /// The title.
    public var body: some View {
        Text(text)
            .id(appLanguage)
            .font(
                layout.isCompact
                    ? .title2.weight(.semibold)
                    : .largeTitle.weight(.semibold)
            )
    }
}
