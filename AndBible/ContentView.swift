// ContentView.swift — Root navigation container

import SwiftUI
import SwiftData
import BibleUI
import BibleCore

/**
 Root content view for the app's reader-first shell.

 The Android-parity reader drawer is the supported top-level navigation surface.
 */
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var nightMode = false
    @State private var nightModeMode = AppPreferenceRegistry.stringDefault(for: .nightModePref3) ?? NightModeSetting.system.rawValue

    var body: some View {
        NavigationStack {
            BibleReaderView()
        }
        .preferredColorScheme(preferredColorSchemeOverride)
        .onAppear {
            reloadNightModePreferences()
        }
        .onChange(of: colorScheme) { _, _ in
            reloadNightModePreferences()
        }
    }

    private var preferredColorSchemeOverride: ColorScheme? {
        switch NightModeSettingsResolver.effectiveMode(from: nightModeMode) {
        case .system:
            return nil
        case .automatic, .manual:
            return nightMode ? .dark : .light
        }
    }

    private func reloadNightModePreferences() {
        let store = SettingsStore(modelContext: modelContext)
        nightModeMode = store.getString(.nightModePref3)
        let manualNightMode = store.getBool("night_mode")
        nightMode = NightModeSettingsResolver.isNightMode(
            rawValue: nightModeMode,
            manualNightMode: manualNightMode,
            systemIsDark: colorScheme == .dark
        )
    }
}
