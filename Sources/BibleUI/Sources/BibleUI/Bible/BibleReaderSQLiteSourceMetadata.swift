// BibleReaderSQLiteSourceMetadata.swift -- Shared SQLite reader source presentation metadata

import BibleCore
import Foundation

/**
 Immutable source metadata shared by SQLite rendering, speech, and visible-text paths.

 Values come from validated installed and reader metadata rather than filename guesses. Every
 supported Android SQLite family uses JSword's exact KJVA coordinate domain. Construction performs
 no reader call, so the value can cross tasks after the module handle publishes its snapshots.
 */
struct BibleReaderSQLiteSourceMetadata: Equatable, Sendable {
    /// Canonical installed initials used by picker, payload, and checkpoint identities.
    let initials: String

    /// User-visible source name with deterministic validated-metadata fallback.
    let name: String

    /// Compact source label used by document headers and bookmark metadata.
    let abbreviation: String

    /// Source language token used by payload and speech routing.
    let language: String

    /// CSS-compatible source direction, either `ltr` or `rtl`.
    let direction: String

    /// Whether source markup advertises Strong's tokens.
    let hasStrongs: Bool

    /// Exact JSword versification name owning all source verse coordinates.
    let versification: String

    /**
     Creates source metadata from one immutable module handle without querying content.

     - Parameter module: Validated handle providing immutable installed and format metadata.
     - Side effects: Trims presentation strings and applies deterministic display fallbacks only.
     - Failure modes: Empty language falls back to English; empty title/description/abbreviation
       fall back through validated metadata to exact initials.
     - Important: No SQLite reader operation occurs during construction.
     */
    init(module: BibleReaderSQLiteModuleHandle) {
        let description = module.info.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = module.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let abbreviation = module.metadata.abbreviation.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let installedLanguage = module.info.language.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let readerLanguage = module.metadata.language.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        initials = module.info.name
        name = description.isEmpty ? (title.isEmpty ? module.info.name : title) : description
        self.abbreviation = abbreviation.isEmpty ? module.info.name : abbreviation
        language = installedLanguage.isEmpty
            ? (readerLanguage.isEmpty ? "en" : readerLanguage)
            : installedLanguage
        direction = module.metadata.direction == .rtl ? "rtl" : "ltr"
        hasStrongs = module.metadata.hasStrongs
        versification = JSwordKJVAVersification.name
    }
}
