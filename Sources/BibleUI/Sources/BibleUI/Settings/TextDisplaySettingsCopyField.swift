// TextDisplaySettingsCopyField.swift -- Android-style selective text-settings copy support

import Foundation
import BibleCore

/**
 One selectable text-display setting group from Android's copy-settings dialog.

 Android exposes `WorkspaceEntities.TextDisplaySettings.Types` and copies only the checked fields.
 iOS mirrors that behavior for the text-display fields it supports, including grouped colors and
 margins, while leaving unsupported Android-only fields out of the UI instead of inventing storage.
 */
enum TextDisplaySettingsCopyField: String, CaseIterable, Identifiable {
    case fontSize
    case fontFamily
    case colors
    case marginSize
    case justifyText
    case hyphenation
    case topMargin
    case lineSpacing
    case strongsMode
    case showMorphology
    case showFootNotes
    case showFootNotesInline
    case expandXrefs
    case showXrefs
    case showRedLetters
    case showSectionTitles
    case showVerseNumbers
    case showVersePerLine
    case showBookmarks
    case bookmarksHideLabels
    case showMyNotes
    case showPageNumber
    case infiniteScroll
    case nonStrongsWordItalic
    case showMarkAsReadButton
    case showTitleScrollButton
    case showMemorizationIndicators
    case showAiDocMarkers
    case pageScrollAmount
    case showOrdinals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fontSize:
            return localized("font_size", default: "Font size")
        case .fontFamily:
            return localized("font", default: "Font")
        case .colors:
            return localized("prefs_text_colors_menutitle", default: "Color settings")
        case .marginSize:
            return localized("margin_size", default: "Margin size")
        case .justifyText:
            return localized("justify_text", default: "Justify text")
        case .hyphenation:
            return localized("hyphenation", default: "Hyphenation")
        case .topMargin:
            return localized("top_margin", default: "Top margin")
        case .lineSpacing:
            return localized("line_spacing", default: "Line spacing")
        case .strongsMode:
            return localized("prefs_show_strongs_title", default: "Strong's numbers")
        case .showMorphology:
            return localized("morphology", default: "Morphology")
        case .showFootNotes:
            return localized("footnotes", default: "Footnotes")
        case .showFootNotesInline:
            return localized("footnotes_inline", default: "Inline footnotes")
        case .expandXrefs:
            return localized("expand_cross_references", default: "Expand cross references")
        case .showXrefs:
            return localized("cross_references", default: "Cross references")
        case .showRedLetters:
            return localized("red_letters", default: "Red letters")
        case .showSectionTitles:
            return localized("prefs_section_title_title", default: "Section titles")
        case .showVerseNumbers:
            return localized("prefs_show_verseno_title", default: "Chapter & verse numbers")
        case .showVersePerLine:
            return localized("verse_per_line", default: "Verse per line")
        case .showBookmarks:
            return localized("show_bookmarks", default: "Show bookmarks")
        case .bookmarksHideLabels:
            return localized("hide_labels", default: "Hide labels")
        case .showMyNotes:
            return localized("my_notes", default: "My notes")
        case .showPageNumber:
            return localized("page_number", default: "Page number")
        case .infiniteScroll:
            return localized("infinite_scroll", default: "Infinite scroll")
        case .nonStrongsWordItalic:
            return localized("non_strongs_word_italic", default: "Italicize added words")
        case .showMarkAsReadButton:
            return localized("mark_as_read_button", default: "Mark as read button")
        case .showTitleScrollButton:
            return localized("title_scroll_button", default: "Title scroll button")
        case .showMemorizationIndicators:
            return localized("memorization_indicators", default: "Memorization indicators")
        case .showAiDocMarkers:
            return localized("ai_document_markers", default: "AI document markers")
        case .pageScrollAmount:
            return localized("page_scroll_amount", default: "Page scroll amount")
        case .showOrdinals:
            return localized("ordinals", default: "Ordinals")
        }
    }

    func copyValue(from source: TextDisplaySettings, to target: inout TextDisplaySettings) {
        switch self {
        case .fontSize:
            target.fontSize = source.fontSize
        case .fontFamily:
            target.fontFamily = source.fontFamily
        case .colors:
            target.dayTextColor = source.dayTextColor
            target.dayBackground = source.dayBackground
            target.dayNoise = source.dayNoise
            target.nightTextColor = source.nightTextColor
            target.nightBackground = source.nightBackground
            target.nightNoise = source.nightNoise
        case .marginSize:
            target.marginLeft = source.marginLeft
            target.marginRight = source.marginRight
            target.maxWidth = source.maxWidth
        case .justifyText:
            target.justifyText = source.justifyText
        case .hyphenation:
            target.hyphenation = source.hyphenation
        case .topMargin:
            target.topMargin = source.topMargin
        case .lineSpacing:
            target.lineSpacing = source.lineSpacing
        case .strongsMode:
            target.strongsMode = source.strongsMode
        case .showMorphology:
            target.showMorphology = source.showMorphology
        case .showFootNotes:
            target.showFootNotes = source.showFootNotes
        case .showFootNotesInline:
            target.showFootNotesInline = source.showFootNotesInline
        case .expandXrefs:
            target.expandXrefs = source.expandXrefs
        case .showXrefs:
            target.showXrefs = source.showXrefs
        case .showRedLetters:
            target.showRedLetters = source.showRedLetters
        case .showSectionTitles:
            target.showSectionTitles = source.showSectionTitles
        case .showVerseNumbers:
            target.showVerseNumbers = source.showVerseNumbers
        case .showVersePerLine:
            target.showVersePerLine = source.showVersePerLine
        case .showBookmarks:
            target.showBookmarks = source.showBookmarks
        case .bookmarksHideLabels:
            target.bookmarksHideLabels = source.bookmarksHideLabels
        case .showMyNotes:
            target.showMyNotes = source.showMyNotes
        case .showPageNumber:
            target.showPageNumber = source.showPageNumber
        case .infiniteScroll:
            target.infiniteScroll = source.infiniteScroll
        case .nonStrongsWordItalic:
            target.nonStrongsWordItalic = source.nonStrongsWordItalic
        case .showMarkAsReadButton:
            target.showMarkAsReadButton = source.showMarkAsReadButton
        case .showTitleScrollButton:
            target.showTitleScrollButton = source.showTitleScrollButton
        case .showMemorizationIndicators:
            target.showMemorizationIndicators = source.showMemorizationIndicators
        case .showAiDocMarkers:
            target.showAiDocMarkers = source.showAiDocMarkers
        case .pageScrollAmount:
            target.pageScrollAmount = source.pageScrollAmount
        case .showOrdinals:
            target.showOrdinals = source.showOrdinals
        }
    }

    private func localized(_ key: String, default defaultValue: String) -> String {
        let value = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? defaultValue : value
    }
}

extension TextDisplaySettings {
    /**
     Returns a value where selected fields have been copied from another settings value.

     - Parameters:
       - source: Raw source settings, normally a window's page-manager overrides.
       - fields: Android-style field groups selected by the user.
     - Returns: A copy with only the selected fields changed.
     - Side effects: None.
     */
    func copyingSelectedFields(
        from source: TextDisplaySettings,
        fields: Set<TextDisplaySettingsCopyField>
    ) -> TextDisplaySettings {
        var target = self
        for field in TextDisplaySettingsCopyField.allCases where fields.contains(field) {
            field.copyValue(from: source, to: &target)
        }
        return target
    }
}
