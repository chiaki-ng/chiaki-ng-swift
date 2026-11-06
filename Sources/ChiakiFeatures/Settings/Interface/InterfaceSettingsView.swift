import ChiakiModels
import ComposableArchitecture
import DesignSystem
import MenuFocus
import SwiftUI

/// App language and library menu position settings.
public struct InterfaceSettingsView: View {
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage = AppLanguage.system.rawValue
    /// The persisted interface settings whose library menu edge is edited and saved.
    @Bindable public var store: StoreOf<PersistedSettingFeature<InterfaceSettings>>

    /// Creates an interface settings view.
    ///
    /// - Parameter store: The persisted interface settings whose library menu edge is edited and saved.
    public init(store: StoreOf<PersistedSettingFeature<InterfaceSettings>>) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(
                "App Language",
                detail: "Choose Follow System to use your device's preferred language."
            ) {
                Picker("App Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        languageLabel(language).tag(language.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
            Text("Menu position").font(.callout)
            FocusableSegments(
                options: LibraryRailEdge.allCases,
                title: Self.title,
                selection: $store.draft.railEdge
            )
            .accessibilityLabel("Menu position")
            .disabled(!store.isEditable)
            SettingsPersistenceBanner(store.setting, subject: "interface settings") {
                store.send(.retry)
            }
        }
        .onAppear {
            store.send(.appeared)
        }
    }

    /// The name of a menu edge.
    ///
    /// - Parameter edge: The edge.
    /// - Returns: Its name.
    public static func title(_ edge: LibraryRailEdge) -> String {
        switch edge {
        case .top:
            "Top"
        case .left:
            "Left"
        case .right:
            "Right"
        case .bottom:
            "Bottom"
        }
    }

    @ViewBuilder
    private func languageLabel(_ language: AppLanguage) -> some View {
        switch language {
        case .system:
            Text(LocalizedStringKey("Follow System"))
        case .english:
            Text(LocalizedStringKey("English"))
        case .simplifiedChinese:
            Text(verbatim: "简体中文")
        }
    }
}
