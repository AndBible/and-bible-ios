// AndroidScriptureBookScope.swift -- Shared Android scripture membership

import Foundation

/**
 Matches Android `Scripture.isScripture` against JSword's KJV 66-book canon.

 Android uses this predicate to keep traversal and chooser actions inside either canonical
 Scripture or non-scripture material. Membership is intentionally independent of testament and
 the active module's broader KJVA book inventory.
 */
public enum AndroidScriptureBookScope {
    /**
     Checks whether one OSIS book identifier belongs to Android's scripture set.

     - Parameter osisBookId: Canonical OSIS identifier.
     - Returns: `true` only for a real book in JSword's KJV versification.
     - Side effects: None.
     - Failure modes: Aliases and unknown identifiers are treated as non-scripture, matching
       Android's `SystemKJV.containsBook` boundary.
     */
    public static func isScripture(osisBookId: String) -> Bool {
        scriptureBookIds.contains(osisBookId)
    }

    /// Canonical OSIS identifiers returned by JSword's KJV book iterator.
    private static let scriptureBookIds: Set<String> = [
        "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth", "1Sam", "2Sam",
        "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh", "Esth", "Job", "Ps", "Prov",
        "Eccl", "Song", "Isa", "Jer", "Lam", "Ezek", "Dan", "Hos", "Joel", "Amos",
        "Obad", "Jonah", "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal", "Matt",
        "Mark", "Luke", "John", "Acts", "Rom", "1Cor", "2Cor", "Gal", "Eph", "Phil",
        "Col", "1Thess", "2Thess", "1Tim", "2Tim", "Titus", "Phlm", "Heb", "Jas",
        "1Pet", "2Pet", "1John", "2John", "3John", "Jude", "Rev",
    ]
}
