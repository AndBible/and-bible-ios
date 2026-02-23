// SettingsView.swift — App settings

import SwiftUI
import SwiftData
import BibleCore
import SwordKit
#if os(iOS)
import UIKit
#endif

/// Main settings screen for the app.
public struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var displaySettings: TextDisplaySettings
    @Binding var nightMode: Bool
    var onSettingsChanged: (() -> Void)?

    @State private var hebrewDicts: [ModuleInfo] = []
    @State private var greekDicts: [ModuleInfo] = []
    @State private var preferredHebrewDict: String = ""
    @State private var preferredGreekDict: String = ""
    @AppStorage("discrete_mode") private var discreteMode = false
    @State private var selectedLanguage: String = ""
    @State private var showRestartAlert = false

    /// Available languages with their .lproj directories in the app bundle.
    private static let availableLanguages: [(code: String, name: String)] = {
        let codes = [
            "af", "ar", "az", "bg", "bn", "cs", "de", "el", "en", "eo",
            "es", "et", "fi", "fr", "he", "hi", "hr", "hu", "id", "it",
            "kk", "ko", "lt", "ml", "my", "nb", "nl", "pl", "pt-BR", "pt",
            "ro", "ru", "sk", "sl", "sr-Latn", "sr", "sv", "ta", "te", "tr",
            "uk", "uz", "yue", "zh-Hans", "zh-Hant"
        ]
        return codes.map { code in
            let locale = Locale(identifier: code)
            // Show the language name in its own script (e.g., "Deutsch" for German)
            let nativeName = locale.localizedString(forIdentifier: code) ?? code
            return (code: code, name: nativeName)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    public init(
        displaySettings: Binding<TextDisplaySettings>,
        nightMode: Binding<Bool>,
        onSettingsChanged: (() -> Void)? = nil
    ) {
        self._displaySettings = displaySettings
        self._nightMode = nightMode
        self.onSettingsChanged = onSettingsChanged
    }

    public var body: some View {
        Form {
            Section(String(localized: "settings_display")) {
                NavigationLink(String(localized: "settings_text_display")) {
                    TextDisplaySettingsView(settings: $displaySettings, onChange: onSettingsChanged)
                }
                NavigationLink(String(localized: "settings_colors")) {
                    ColorSettingsView(settings: $displaySettings, onChange: onSettingsChanged)
                }
                Toggle(String(localized: "night_mode"), isOn: Binding(
                    get: { nightMode },
                    set: {
                        nightMode = $0
                        // Persist to SettingsStore
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool("night_mode", value: $0)
                        onSettingsChanged?()
                    }
                ))
                Toggle(String(localized: "verse_selection"), isOn: Binding(
                    get: { displaySettings.enableVerseSelection ?? true },
                    set: {
                        displaySettings.enableVerseSelection = $0
                        onSettingsChanged?()
                    }
                ))
            }

            Section(String(localized: "settings_language")) {
                Picker(String(localized: "settings_language"), selection: $selectedLanguage) {
                    Text(String(localized: "language_system_default")).tag("")
                    ForEach(Self.availableLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .onChange(of: selectedLanguage) { _, newValue in
                    if newValue.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                    }
                    UserDefaults.standard.synchronize()
                    showRestartAlert = true
                }
                Text(String(localized: "language_restart_required"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "settings_dictionaries")) {
                Picker(String(localized: "hebrew_dictionary"), selection: $preferredHebrewDict) {
                    Text(String(localized: "auto")).tag("")
                    ForEach(hebrewDicts, id: \.name) { mod in
                        Text("\(mod.name) — \(mod.description)").tag(mod.name)
                    }
                }
                .onChange(of: preferredHebrewDict) { _, newValue in
                    let store = SettingsStore(modelContext: modelContext)
                    store.setString("preferred_hebrew_dict", value: newValue)
                }

                Picker(String(localized: "greek_dictionary"), selection: $preferredGreekDict) {
                    Text(String(localized: "auto")).tag("")
                    ForEach(greekDicts, id: \.name) { mod in
                        Text("\(mod.name) — \(mod.description)").tag(mod.name)
                    }
                }
                .onChange(of: preferredGreekDict) { _, newValue in
                    let store = SettingsStore(modelContext: modelContext)
                    store.setString("preferred_greek_dict", value: newValue)
                }

                if hebrewDicts.isEmpty && greekDicts.isEmpty {
                    Text(String(localized: "no_dictionaries_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "settings_data")) {
                NavigationLink(String(localized: "downloads")) {
                    ModuleBrowserView()
                }
                NavigationLink(String(localized: "repositories")) {
                    RepositoryManagerView()
                }
                NavigationLink(String(localized: "import_export")) {
                    ImportExportView()
                }
                NavigationLink(String(localized: "labels")) {
                    LabelManagerView()
                }
            }

            Section(String(localized: "settings_security")) {
                Toggle(String(localized: "discrete_mode"), isOn: $discreteMode)
                Text(String(localized: "discrete_mode_description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "settings_about")) {
                HStack {
                    Text(String(localized: "version"))
                    Spacer()
                    Text("1.0.0")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(String(localized: "settings"))
        .alert(String(localized: "settings_language"), isPresented: $showRestartAlert) {
            Button(String(localized: "ok")) {}
        } message: {
            Text(String(localized: "language_restart_required"))
        }
        .onAppear {
            // Load installed dictionary modules
            if let mgr = SwordManager() {
                let all = mgr.installedModules()
                hebrewDicts = all.filter { $0.features.contains(.hebrewDef) }
                greekDicts = all.filter { $0.features.contains(.greekDef) }
            }
            // Load persisted preferences
            let store = SettingsStore(modelContext: modelContext)
            preferredHebrewDict = store.getString("preferred_hebrew_dict") ?? ""
            preferredGreekDict = store.getString("preferred_greek_dict") ?? ""
            // Load current language override
            if let overrideLangs = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
               let first = overrideLangs.first,
               Self.availableLanguages.contains(where: { $0.code == first }) {
                selectedLanguage = first
            } else {
                selectedLanguage = ""
            }
        }
    }
}
