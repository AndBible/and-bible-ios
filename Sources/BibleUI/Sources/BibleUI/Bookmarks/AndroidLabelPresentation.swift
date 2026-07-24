// AndroidLabelPresentation.swift -- Canonical Android label presentation policy

import BibleCore
import Foundation

/**
 Owns Android's reserved-label naming and Study Pad label eligibility rules.

 Android stores system labels under stable internal names and resolves their user-visible strings at
 presentation time. Keeping that mapping here prevents Study Pads, bookmarks, label management, and
 future selectors from independently leaking storage identifiers such as `__AI_LABEL__`.

 Inputs: persisted `Label` values

 Outputs: localized display names and Android-compatible selector/export label collections

 Side effects: none

 Failure modes: unknown reserved names remain visible as their persisted value so data is never
 silently hidden
 */
enum AndroidLabelPresentation {
    /**
     Resolves Android's localized display name for one persisted label.

     - Parameter label: Persisted user or system label.
     - Returns: Localized reserved-label title or the exact user label name.
     - Side effects: none.
     - Failure modes: none.
     */
    static func displayName(for label: BibleCore.Label) -> String {
        switch label.name {
        case BibleCore.Label.speakLabelName:
            return String(localized: "speak")
        case BibleCore.Label.unlabeledName:
            return String(localized: "label_unlabelled", defaultValue: "Unlabelled")
        case BibleCore.Label.paragraphBreakLabelName:
            return String(localized: "add_paragraph_break", defaultValue: "Paragraph break")
        case BibleCore.Label.aiLabelName:
            return String(localized: "ai_label", defaultValue: "AI")
        default:
            return label.name
        }
    }

    /**
     Returns Android's normal Study Pad selector rows.

     Android starts from `assignableLabels` and removes only the Unlabelled system label. Speak,
     Paragraph break, AI, and user-created labels remain selectable.

     - Parameter labels: Complete persisted label collection.
     - Returns: Eligible labels sorted by Android-visible name.
     - Side effects: none.
     - Failure modes: none.
     */
    static func studyPadSelectorLabels(from labels: [BibleCore.Label]) -> [BibleCore.Label] {
        labels
            .filter { $0.name != BibleCore.Label.unlabeledName }
            .sorted { lhs, rhs in
                let comparison = displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs))
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    /**
     Returns Android's Study Pad export choices.

     Android's export dialog uses all assignable labels, including Unlabelled. Synthetic group rows
     are not persisted on iOS, so the complete persisted collection is the matching source.

     - Parameter labels: Complete persisted label collection.
     - Returns: Labels sorted by Android-visible name.
     - Side effects: none.
     - Failure modes: none.
     */
    static func studyPadExportLabels(from labels: [BibleCore.Label]) -> [BibleCore.Label] {
        labels.sorted { lhs, rhs in
            let comparison = displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs))
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
