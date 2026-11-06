import ChiakiModels
import ComposableArchitecture
import SwiftUI

/// The Interface page in the touch library: where the library menu sits.
struct MobileInterfaceSettingsPage: View {
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage = AppLanguage.system.rawValue
    @Bindable private var store: StoreOf<PersistedSettingFeature<InterfaceSettings>>

    /// Creates the page.
    ///
    /// - Parameter settings: The settings, scoped to the persisted interface settings.
    init(settings: StoreOf<SettingsFeature>) {
        store = settings.scope(state: \.interface, action: \.interface)
    }

    var body: some View {
        MobileSettingsForm {
            MobileSettingsGroup("Language", footer: "Choose Follow System to use your device's preferred language.") {
                MobilePickerRow("App Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(AppLanguage.title(language)).tag(language.rawValue)
                    }
                }
            }
            MobileSettingsGroup("Menu") {
                MobilePickerRow("Menu Position", selection: $store.draft.railEdge) {
                    ForEach(LibraryRailEdge.allCases, id: \.self) { edge in
                        Text(InterfaceSettingsView.title(edge)).tag(edge)
                    }
                }
            }
            .disabled(!store.isEditable)
            SettingsPersistenceBanner(store.setting, subject: "interface settings") {
                store.send(.retry)
            }
        }
        .onAppear {
            store.send(.appeared)
        }
    }
}
