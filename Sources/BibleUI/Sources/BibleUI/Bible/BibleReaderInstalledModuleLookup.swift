// BibleReaderInstalledModuleLookup.swift -- Shared Android BookSet ownership projection

import BibleCore
import SwordKit

/**
 One installed-book registration carrying the fields used by JSword's `BookSet` contract.

 The value is deliberately generic so native modules, SQLite handles, and metadata-only callers
 can share one exact projection without erasing backend ownership. Inputs must already reflect
 Java config parsing: `fullName` is the parsed book name and `abbreviation` is the parsed
 abbreviation with the initials fallback applied.
 */
struct BibleReaderInstalledBookSetRegistration<Value> {
    /// Caller-owned backend handle or metadata retained through lookup and ordering.
    let value: Value

    /// Exact Java `Book.getInitials()` value used by the initials map and comparator.
    let initials: String

    /// Exact Java `Book.getName()` value used by the full-name map and comparator.
    let fullName: String

    /// Parsed `Book.getAbbreviation()` value used by the comparator's second field.
    let abbreviation: String

    /// Book category whose pinned Java enum ordinal is the comparator's first field.
    let category: ModuleCategory
}

/**
 Replays the pinned JSword `BookSet` maps and `TreeSet` over exact Android string semantics.

 JSword adds books in driver registration order, replaces a comparator-equal TreeSet member, and
 updates exact initials/name maps. `getBook` checks those exact maps before scanning the sorted set
 for the first `equalsIgnoreCase` initials or name. Centralizing all three operations prevents
 runtime, picker, speech, and startup paths from selecting different owners for one token.
 */
enum BibleReaderInstalledBookSet {
    /**
     Resolves one installed-book token through JSword's three lookup tiers.

     - Parameters:
       - name: Exact initials/full-name token or a Java case-insensitive alias.
       - registrations: Books in Android add order before TreeSet replacement.
     - Returns: Last-added surviving exact-initials owner, last-added surviving exact-name owner,
       then the first case-insensitive match in TreeSet order; otherwise nil.
     - Side effects: Loads SwordKit's pinned Android character table for case comparisons.
     - Failure modes: Empty and unmatched tokens return nil. Canonically equivalent but UTF-16-
       distinct strings remain distinct because Java performs no Unicode normalization.
     */
    static func registration<Value>(
        named name: String,
        in registrations: [BibleReaderInstalledBookSetRegistration<Value>]
    ) -> BibleReaderInstalledBookSetRegistration<Value>? {
        let surviving = registrationOrderProjection(registrations)
        return surviving.last { SwordJavaStringIdentity.equals($0.initials, name) }
            ?? surviving.last { SwordJavaStringIdentity.equals($0.fullName, name) }
            ?? treeSetOrderProjection(surviving).first {
                SwordJavaStringIdentity.equalsIgnoreCase($0.initials, name)
                    || SwordJavaStringIdentity.equalsIgnoreCase($0.fullName, name)
            }
    }

    /**
     Replays TreeSet comparator-equality replacement while preserving surviving add order.

     - Parameter registrations: Installed books in Android add order.
     - Returns: Comparator-distinct registrations in the order their surviving owners were added.
     - Side effects: Loads the pinned Android case table for abbreviation comparison.
     - Failure modes: None; an empty input returns an empty projection.
     - Note: A replacement is removed and appended, rather than overwritten in place, so the exact
       maps still observe the later registration when another same-initials row lies between them.
     */
    static func registrationOrderProjection<Value>(
        _ registrations: [BibleReaderInstalledBookSetRegistration<Value>]
    ) -> [BibleReaderInstalledBookSetRegistration<Value>] {
        var surviving: [BibleReaderInstalledBookSetRegistration<Value>] = []
        for registration in registrations {
            if let existing = surviving.firstIndex(where: {
                comparison($0, registration) == 0
            }) {
                surviving.remove(at: existing)
            }
            surviving.append(registration)
        }
        return surviving
    }

    /**
     Projects the installed books in the order exposed by `Books.installed().books`.

     - Parameter registrations: Installed books in Android add order before replacement.
     - Returns: Comparator-distinct values sorted by category, abbreviation, initials, then name.
     - Side effects: Loads the pinned Android case table for abbreviation comparison.
     - Failure modes: None; every iOS module category has a pinned deterministic ordinal.
     */
    static func treeSetOrderProjection<Value>(
        _ registrations: [BibleReaderInstalledBookSetRegistration<Value>]
    ) -> [BibleReaderInstalledBookSetRegistration<Value>] {
        registrationOrderProjection(registrations).sorted {
            comparison($0, $1) < 0
        }
    }

    /**
     Compares two registrations with JSword's `AbstractBookMetaData.compareTo` fields.

     - Parameters:
       - lhs: First parsed BookSet registration.
       - rhs: Second parsed BookSet registration.
     - Returns: Negative, zero, or positive for category, abbreviation, initials, then name order.
     - Side effects: Loads the pinned Android case table for abbreviation comparison.
     - Failure modes: None; every module category and valid Swift UTF-16 string is deterministic.
     */
    private static func comparison<Value>(
        _ lhs: BibleReaderInstalledBookSetRegistration<Value>,
        _ rhs: BibleReaderInstalledBookSetRegistration<Value>
    ) -> Int {
        let categoryOrder = categoryOrdinal(lhs.category) - categoryOrdinal(rhs.category)
        if categoryOrder != 0 { return categoryOrder }

        let abbreviationOrder = SwordJavaStringIdentity.compareIgnoreCase(
            lhs.abbreviation,
            rhs.abbreviation
        )
        if abbreviationOrder != 0 { return abbreviationOrder }

        let initialsOrder = javaStringCompare(lhs.initials, rhs.initials)
        if initialsOrder != 0 { return initialsOrder }
        return javaStringCompare(lhs.fullName, rhs.fullName)
    }

    /**
     Maps one iOS module category to the pinned JSword `BookCategory.ordinal()`.

     - Parameter category: Installed module category participating in BookSet order.
     - Returns: Stable Android enum ordinal, including explicit unknown/addon positions.
     - Side effects: None.
     - Failure modes: None; the switch is exhaustive.
     */
    private static func categoryOrdinal(_ category: ModuleCategory) -> Int {
        switch category {
        case .bible: return 0
        case .dictionary: return 1
        case .commentary: return 2
        case .dailyDevotion: return 3
        case .glossary: return 4
        case .questionable: return 5
        case .essays: return 6
        case .images: return 7
        case .map: return 8
        case .generalBook: return 9
        case .unknown: return 10
        case .addon: return 11
        }
    }

    /**
     Compares two exact strings with Java `String.compareTo` UTF-16 semantics.

     - Parameters:
       - lhs: First exact Java string.
       - rhs: Second exact Java string.
     - Returns: First code-unit difference or UTF-16 length difference.
     - Side effects: None.
     - Failure modes: None; Swift strings always expose a valid UTF-16 view.
     */
    private static func javaStringCompare(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        for (leftUnit, rightUnit) in zip(left, right) where leftUnit != rightUnit {
            return Int(leftUnit) - Int(rightUnit)
        }
        return left.count - right.count
    }
}

/**
 Resolves metadata-only installed module lists through the shared Android BookSet projection.

 Callers without backend handles use initials as the abbreviation fallback. Runtime paths that can
 read configured abbreviations construct full `BibleReaderInstalledBookSetRegistration` values so
 their case-insensitive tier and installed ordering exactly match JSword.
 */
enum BibleReaderInstalledModuleLookup {
    /**
     Finds the globally owned module for one requested name.

     - Parameters:
       - requestedName: Initials or full module name supplied by discovery, UI, or persistence.
       - modules: Installed metadata in manager registration order.
     - Returns: The owner selected by exact maps and the shared BookSet case-insensitive scan.
     - Side effects: Loads the pinned Android case table for the final lookup tier.
     - Failure modes: Empty inputs and unmatched tokens return nil. Unicode normalization and
       locale-sensitive folding are intentionally not performed.
     */
    static func module(
        named requestedName: String,
        in modules: [ModuleInfo]
    ) -> ModuleInfo? {
        let registrations = modules.map { info in
            BibleReaderInstalledBookSetRegistration(
                value: info,
                initials: info.name,
                fullName: info.description,
                abbreviation: info.name,
                category: info.category
            )
        }
        return BibleReaderInstalledBookSet.registration(
            named: requestedName,
            in: registrations
        )?.value
    }
}
