// JSwordBibleBook.swift — Stable Android Bible book identity, independent of versification

/**
 Maps JSword's persisted `BibleBook.ordinal()` to OSIS identifiers.

 The order follows `jsword/.../versification/BibleBook.java` in Android. It is an identity
 domain, not a module's filtered book list or a versification's ordered chapter table.
 Introduction entries retain their enum positions; readers must separately prove that a
 complete location is addressable in the selected module before displaying it.
 */
public enum JSwordBibleBook {
    /// Android enum order, including books outside the KJVA canon.
    private static let osisIDs = [
        "Intro.Bible", "Intro.OT", "Gen", "Exod", "Lev", "Num", "Deut", "Josh",
        "Judg", "Ruth", "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr",
        "Ezra", "Neh", "Esth", "Job", "Ps", "Prov", "Eccl", "Song",
        "Isa", "Jer", "Lam", "Ezek", "Dan", "Hos", "Joel", "Amos",
        "Obad", "Jonah", "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech",
        "Mal", "Intro.NT", "Matt", "Mark", "Luke", "John", "Acts", "Rom",
        "1Cor", "2Cor", "Gal", "Eph", "Phil", "Col", "1Thess", "2Thess",
        "1Tim", "2Tim", "Titus", "Phlm", "Heb", "Jas", "1Pet", "2Pet",
        "1John", "2John", "3John", "Jude", "Rev", "Tob", "Jdt", "AddEsth",
        "Wis", "Sir", "Bar", "EpJer", "PrAzar", "Sus", "Bel", "1Macc",
        "2Macc", "3Macc", "4Macc", "PrMan", "1Esd", "2Esd", "Ps151", "Odes",
        "PssSol", "EpLao", "3Esd", "4Esd", "5Esd", "1En", "Jub", "4Bar",
        "AscenIsa", "PsJos", "AposCon", "1Clem", "2Clem", "3Cor", "EpCorPaul", "JosAsen",
        "T12Patr", "T12Patr.TAsh", "T12Patr.TBenj", "T12Patr.TDan", "T12Patr.TGad", "T12Patr.TIss", "T12Patr.TJos", "T12Patr.TJud",
        "T12Patr.TLevi", "T12Patr.TNaph", "T12Patr.TReu", "T12Patr.TSim", "T12Patr.TZeb", "2Bar", "EpBar", "Barn",
        "Herm", "Herm.Mand", "Herm.Sim", "Herm.Vis", "AddDan", "AddPs", "EsthGr",
    ]

    /// Shared reverse lookup; no chapter or verse tables are copied here.
    private static let ordinals = Dictionary(uniqueKeysWithValues:
        osisIDs.enumerated().map { ($0.element, $0.offset) }
    )

    /**
     Resolves an OSIS book identity to Android's durable enum ordinal.

     - Parameter osisID: Canonical OSIS identity, or the SWORD `WisSol` alias.
     - Returns: Stable ordinal, or nil for an unknown book.
     - Side effects: None.
     */
    public static func ordinal(forOSIS osisID: String) -> Int? {
        ordinals[osisID == "WisSol" ? "Wis" : osisID]
    }

    /**
     Resolves Android's durable enum ordinal without consulting a module's book ordering.

     - Parameter ordinal: Persisted JSword `BibleBook.ordinal()` value.
     - Returns: Canonical OSIS identity, or nil outside the enum's bounds.
     - Side effects: None.
     */
    public static func osisID(forOrdinal ordinal: Int) -> String? {
        guard osisIDs.indices.contains(ordinal) else { return nil }
        return osisIDs[ordinal]
    }
}

public extension PageManager {
    /**
     Resolves the persisted Bible book only when its identity encoding is canonical.

     - Returns: The JSword OSIS book identifier, or `nil` for a missing/invalid ordinal, an
       unmarked legacy module-list index, or an encoding written by a newer client.
     - Side Effects: None.
     - Failure Modes: Legacy and unknown encodings intentionally fail closed because resolving
       either one requires the exact source catalog that originally owned the value.
     */
    var canonicalBibleOSISBookID: String? {
        guard bibleBookEncoding == Self.jswordBibleBookEncoding,
              let bibleBibleBook else { return nil }
        return JSwordBibleBook.osisID(forOrdinal: bibleBibleBook)
    }
}
