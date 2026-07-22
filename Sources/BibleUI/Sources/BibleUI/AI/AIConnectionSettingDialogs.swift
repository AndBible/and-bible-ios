// AIConnectionSettingDialogs.swift -- Android connection-preference dialog surfaces

import BibleCore
import Foundation
import SwiftUI

/** The two independently editable Android system-prompt overrides. */
enum AISystemPromptKind: Equatable {
    /// System prompt used by ordinary agent runs.
    case agent
    /// System prompt used by direct text transformations.
    case transformation

    /// Localized Android dialog title for this prompt.
    var title: String {
        switch self {
        case .agent:
            return String(localized: "custom_agent_system_prompt_title", defaultValue: "Agent system prompt")
        case .transformation:
            return String(
                localized: "custom_text_transform_system_prompt_title",
                defaultValue: "Text transformation system prompt"
            )
        }
    }

    /**
     Loads the bundled Android default represented by this editor.

     - Returns: Bundled prompt text, or an empty string when a required resource is unavailable.
     - Side effects: Reads the BibleUI resource bundle.
     - Failure modes: Resource failures degrade to empty editable text and never expose file details.
     */
    func defaultText() -> String {
        guard let prompts = try? AIReaderSystemPromptLoader.load() else { return "" }
        switch self {
        case .agent: return prompts.agent
        case .transformation: return prompts.transformation
        }
    }
}

/** One Android interface-locale option reused by AI response-language selection. */
struct AIResponseLanguageOption: Identifiable, Equatable {
    /// Android-compatible BCP 47 value; `nil` means app language.
    let code: String?
    /// Localized language description.
    let title: String

    /// Stable identity preserving the app-default row.
    var id: String { code ?? "__app_default" }
}

/** Android's response-language option catalog in `prefs_interface_locale_values` order. */
enum AIResponseLanguageCatalog {
    /// Sentinel used to transition from the standard chooser to free-form input.
    static let customCode = "\u{0}custom"

    /**
     Builds Android's app-default, supported-language, and Custom rows.

     - Parameter locale: Locale used to describe the current app language in the default row.
     - Returns: Ordered localized choices matching Android's language picker.
     - Side effects: Performs localization lookups only.
     - Failure modes: Missing localized names use the checked-in Android English descriptions.
     */
    static func options(locale: Locale = .current) -> [AIResponseLanguageOption] {
        let currentLanguageCode = locale.language.languageCode?.identifier ?? "en"
        let currentLanguage = locale.localizedString(forLanguageCode: currentLanguageCode) ?? currentLanguageCode
        let defaultTitle = String(
            format: String(localized: "ai_language_app_default", defaultValue: "App language (%1$@)"),
            currentLanguage
        )
        return [AIResponseLanguageOption(code: nil, title: defaultTitle)]
            + definitions.map { definition in
                let localized = String(localized: String.LocalizationValue(definition.key))
                return AIResponseLanguageOption(
                    code: definition.code,
                    title: localized == definition.key ? definition.fallback : localized
                )
            }
            + [
                AIResponseLanguageOption(
                    code: customCode,
                    title: String(localized: "ai_language_custom", defaultValue: "Custom…")
                ),
            ]
    }

    /// Android locale values and labels, excluding its empty default entry.
    private static let definitions: [(code: String, key: String, fallback: String)] = [
        ("af", "lang_afrikaans", "Afrikaans"), ("ar", "lang_arabic", "Arabic"),
        ("bg", "lang_bulgarian", "Bulgarian"), ("bn", "lang_bengali", "Bengali"),
        ("my", "lang_burmese", "Burmese"), ("ca", "lang_catalan", "Catalan"),
        ("cs", "lang_czech", "Czech"), ("da", "lang_danish", "Danish"),
        ("de", "lang_german", "German"), ("en", "lang_english", "English"),
        ("eo", "lang_esperanto", "Esperanto"), ("es", "lang_spanish", "Spanish"),
        ("et", "lang_estonian", "Estonian"), ("fil", "lang_filipino", "Filipino"),
        ("fi", "lang_finnish", "Finnish"), ("fr", "lang_french", "French"),
        ("iw", "lang_hebrew", "Hebrew"), ("hi", "lang_hindi", "Hindi"),
        ("hr", "lang_croatian", "Croatian"), ("hu", "lang_hungarian", "Hungarian"),
        ("in", "lang_indonesian", "Indonesian"), ("it", "lang_italian", "Italian"),
        ("ja", "lang_japanese", "Japanese"), ("kk", "lang_kazakh", "Kazakh"),
        ("ko", "lang_korean", "Korean"), ("lt", "lang_lithuanian", "Lithuanian"),
        ("ms", "lang_malay", "Malay"), ("nb", "lang_norwegian_bokmal", "Norwegian Bokmal"),
        ("ne", "lang_nepali", "Nepali"), ("nl", "lang_dutch", "Dutch"),
        ("pl", "lang_polish", "Polish"), ("pt", "lang_portuguese", "Portuguese"),
        ("pt-BR", "lang_portuguese_brazil", "Portuguese (Brazil)"),
        ("ro", "lang_romanian", "Romanian"), ("ru", "lang_russian", "Russian"),
        ("sk", "lang_slovak", "Slovak"), ("sl", "lang_slovenian", "Slovenian"),
        ("sr", "lang_serbian", "Serbian"), ("sr-Latn", "lang_serbian_latin", "Serbian (Latin)"),
        ("sw", "lang_swahili", "Swahili"), ("ta", "lang_tamil", "Tamil"),
        ("te", "lang_telugu", "Telugu"), ("th", "lang_thai", "Thai"),
        ("tr", "lang_turkish", "Turkish"), ("uk", "lang_ukrainian", "Ukrainian"),
        ("ur", "lang_urdu", "Urdu"), ("uz", "lang_uzbek", "Uzbek"),
        ("vi", "lang_vietnamese", "Vietnamese"), ("yue", "lang_cantonese", "Cantonese"),
        ("zh-Hant-TW", "lang_chinese_traditional", "Chinese (Traditional)"),
        ("zh-Hans-CN", "lang_chinese_simplified", "Chinese (Simplified)"),
    ]
}

/** Android single-choice dialog for the AI response language. */
struct AIResponseLanguageDialog: View {
    /// Current persisted language value, where `nil` inherits the app language.
    let currentCode: String?
    /// Commits a standard or app-default choice.
    let onSelect: (String?) -> Void
    /// Opens Android's secondary custom-language editor.
    let onCustom: () -> Void
    /// Dismisses without mutation.
    let onCancel: () -> Void

    var body: some View {
        AIAndroidDialogSurface(
            title: String(localized: "ai_language_title", defaultValue: "AI response language")
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AIResponseLanguageCatalog.options()) { option in
                        Button {
                            if option.code == AIResponseLanguageCatalog.customCode {
                                onCustom()
                            } else {
                                onSelect(option.code)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isSelected(option) ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(Color.accentColor)
                                Text(option.title)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 460)
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
        }
        .accessibilityIdentifier("aiResponseLanguageDialog")
    }

    /** Returns whether one standard option represents the current stored value. */
    private func isSelected(_ option: AIResponseLanguageOption) -> Bool {
        if option.code == AIResponseLanguageCatalog.customCode {
            guard let currentCode else { return false }
            return !AIResponseLanguageCatalog.options().contains { $0.code == currentCode }
        }
        return option.code == currentCode
    }
}

/** Android free-form response-language dialog reached through Custom. */
struct AICustomLanguageDialog: View {
    /// Draft language name or BCP 47 code.
    @State private var value: String

    /// Current custom value, if any.
    let currentValue: String?
    /// Commits trimmed text or app-language inheritance when blank.
    let onSave: (String?) -> Void
    /// Dismisses without mutation.
    let onCancel: () -> Void

    /** Creates a custom-language editor seeded from the current explicit value. */
    init(currentValue: String?, onSave: @escaping (String?) -> Void, onCancel: @escaping () -> Void) {
        self.currentValue = currentValue
        self.onSave = onSave
        self.onCancel = onCancel
        _value = State(initialValue: currentValue ?? "")
    }

    var body: some View {
        AIAndroidDialogSurface(
            title: String(localized: "ai_language_title", defaultValue: "AI response language")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "ai_language_custom_hint", defaultValue: "Enter language name or code"))
                TextField(
                    String(localized: "ai_language_custom_example", defaultValue: "e.g. suomi, Tagalog, en"),
                    text: $value
                )
                .textFieldStyle(.plain)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Divider() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            AIAndroidDialogAction(
                title: String(localized: "okay", defaultValue: "OK"),
                action: {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(trimmed.isEmpty ? nil : trimmed)
                }
            )
        }
        .accessibilityIdentifier("aiCustomLanguageDialog")
    }
}

/** Android single-choice dialog for the global agent permission mode. */
struct AIPermissionModeDialog: View {
    /// Current global permission mode.
    let currentMode: AIPermissionMode
    /// Commits the selected mode and dismisses.
    let onSelect: (AIPermissionMode) -> Void
    /// Dismisses without mutation.
    let onCancel: () -> Void

    var body: some View {
        AIAndroidDialogSurface(
            title: String(localized: "prompt_permission_mode", defaultValue: "Permission mode")
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AIPermissionMode.allCases, id: \.self) { mode in
                    Button {
                        onSelect(mode)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mode == currentMode ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(Color.accentColor)
                            Text(AIPermissionPresentation.title(for: mode))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
        }
        .accessibilityIdentifier("aiPermissionModeDialog")
    }
}

/** Android numeric preference editor with unrestricted integer input. */
struct AINumericSettingDialog: View {
    /// Text-field draft so arbitrary nonnegative Android values remain representable.
    @State private var value: String

    /// Localized dialog title.
    let title: String
    /// Android explanatory message.
    let message: String
    /// Android fallback when the entry is not an integer.
    let invalidFallback: Int
    /// Lowest value accepted by this setting.
    let minimum: Int
    /// Commits the normalized value.
    let onSave: (Int) -> Void
    /// Dismisses without mutation.
    let onCancel: () -> Void

    /** Creates an uncapped numeric editor initialized from persisted state. */
    init(
        title: String,
        message: String,
        currentValue: Int,
        invalidFallback: Int,
        minimum: Int,
        onSave: @escaping (Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.invalidFallback = invalidFallback
        self.minimum = minimum
        self.onSave = onSave
        self.onCancel = onCancel
        _value = State(initialValue: String(currentValue))
    }

    var body: some View {
        AIAndroidDialogSurface(title: title) {
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("", text: $value)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.plain)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Divider() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            AIAndroidDialogAction(
                title: String(localized: "okay", defaultValue: "OK"),
                action: { onSave(max(Int(value) ?? invalidFallback, minimum)) }
            )
        }
        .accessibilityIdentifier("aiNumericSettingDialog")
    }
}

/** Android multiline editor for one independent system-prompt override. */
struct AISystemPromptDialog: View {
    /// Editable effective prompt, including bundled default text when no override exists.
    @State private var value: String

    /// Which persisted prompt is being edited.
    let kind: AISystemPromptKind
    /// Commits an override or `nil` inheritance.
    let onSave: (String?) -> Void
    /// Dismisses without mutation.
    let onCancel: () -> Void

    /// Bundled default used for reset and nil-preserving comparison.
    private let defaultValue: String

    /** Creates an editor that displays Android's bundled default instead of a blank inherited value. */
    init(
        kind: AISystemPromptKind,
        currentValue: String?,
        onSave: @escaping (String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.kind = kind
        self.onSave = onSave
        self.onCancel = onCancel
        let defaultValue = kind.defaultText()
        self.defaultValue = defaultValue
        _value = State(initialValue: currentValue ?? defaultValue)
    }

    var body: some View {
        AIAndroidDialogSurface(title: kind.title) {
            TextEditor(text: $value)
                .font(.body)
                .frame(minHeight: 230, maxHeight: 430)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        } actions: {
            AIAndroidDialogAction(
                title: String(localized: "reset_to_default", defaultValue: "Reset to default"),
                action: { onSave(nil) }
            )
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            AIAndroidDialogAction(
                title: String(localized: "okay", defaultValue: "OK"),
                action: {
                    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(normalized.isEmpty || value == defaultValue ? nil : value)
                }
            )
        }
        .accessibilityIdentifier("aiSystemPromptDialog")
    }
}

/** Android raw-log retention dialog with arbitrary positive days or disabled retention. */
struct AIRawLogRetentionDialog: View {
    /// Number-of-days draft.
    @State private var days: String
    /// Whether automatic deletion is disabled.
    @State private var keepsAllLogs: Bool

    /// Commits nullable Android retention days.
    let onSave: (Int?) -> Void
    /// Dismisses without mutation.
    let onCancel: () -> Void

    /** Creates a retention editor from Android's nullable-days representation. */
    init(currentDays: Int?, onSave: @escaping (Int?) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        _days = State(initialValue: currentDays.map(String.init) ?? "")
        _keepsAllLogs = State(initialValue: currentDays == nil)
    }

    var body: some View {
        AIAndroidDialogSurface(
            title: String(localized: "raw_log_retention_title", defaultValue: "Auto-delete old logs")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("30", text: $days)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .disabled(keepsAllLogs)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Divider() }
                Toggle(
                    String(localized: "raw_log_retention_summary_disabled", defaultValue: "Disabled (keep all)"),
                    isOn: $keepsAllLogs
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            AIAndroidDialogAction(
                title: String(localized: "okay", defaultValue: "OK"),
                action: { onSave(keepsAllLogs ? nil : max(Int(days) ?? 30, 1)) }
            )
        }
        .accessibilityIdentifier("aiRawLogRetentionDialog")
    }
}

/** Android confirmation dialog shown before cumulative token usage is cleared. */
struct AIResetUsageDialog: View {
    /// Confirms the destructive usage reset.
    let onConfirm: () -> Void
    /// Dismisses without mutation.
    let onCancel: () -> Void

    var body: some View {
        AIAndroidDialogSurface(
            title: String(localized: "llm_reset_usage_confirm_title", defaultValue: "Reset usage data?")
        ) {
            Text(
                String(
                    localized: "llm_reset_usage_confirm_message",
                    defaultValue: "This will clear all cumulative usage data."
                )
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            AIAndroidDialogAction(
                title: String(localized: "okay", defaultValue: "OK"),
                isDestructive: true,
                action: onConfirm
            )
        }
        .accessibilityIdentifier("aiResetUsageDialog")
    }
}
