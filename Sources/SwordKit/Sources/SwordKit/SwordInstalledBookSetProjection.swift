// SwordInstalledBookSetProjection.swift — Pinned JSword BookSet equality and ordering

import Foundation

/**
 Replays pinned JSword installed-book HashSet/TreeSet comparison fields without backend access.

 Category ordinals match pinned `BookCategory`. Abbreviations use Java case-insensitive comparison,
 while initials and full names use raw unsigned UTF-16 `String.compareTo` order. A later comparator-
 equal registration replaces the earlier owner, matching `Books.addBook`.

 - Side effects: Loads the pinned Android case-fold table when abbreviation comparison is needed.
 - Failure modes: None; every category/string combination has a deterministic total ordering.
 */
enum SwordInstalledBookSetProjection {
    /**
     Compares two ownership-proven native registrations in JSword TreeSet order.

     - Parameters:
       - lhs: First native registration.
       - rhs: Second native registration.
     - Returns: Negative, zero, or positive category/abbreviation/initials/name comparison.
     - Side effects: May load the pinned Java case-fold table.
     - Failure modes: None.
     */
    static func compareNative(
        _ lhs: NativeModuleRegistration,
        _ rhs: NativeModuleRegistration
    ) -> Int {
        let categoryOrder = categoryOrdinal(lhs.info.category) - categoryOrdinal(rhs.info.category)
        if categoryOrder != 0 { return categoryOrder }
        let abbreviationOrder = SwordJavaStringIdentity.compareIgnoreCase(
            lhs.abbreviation,
            rhs.abbreviation
        )
        if abbreviationOrder != 0 { return abbreviationOrder }
        let initialsOrder = compareJavaString(lhs.info.name, rhs.info.name)
        if initialsOrder != 0 { return initialsOrder }
        return compareJavaString(lhs.fullName, rhs.fullName)
    }

    /**
     Replays comparator-equal replacement for a captured installed add sequence.

     - Parameter registrations: Native and custom books in Android add order.
     - Returns: Surviving rows in TreeSet order with later comparator-equal ownership.
     - Side effects: May load the pinned case-fold table.
     - Failure modes: None; an empty sequence returns an empty projection.
     - Complexity: O(N log N).
     */
    static func registrationsInInstalledOrder(
        _ registrations: [InstalledModuleRegistration]
    ) -> [InstalledModuleRegistration] {
        var surviving: [InstalledBookSetIdentity: InstalledModuleRegistration] = [:]
        for registration in registrations {
            surviving[identity(for: registration)] = registration
        }
        return surviving.values.sorted { compare($0, $1) < 0 }
    }

    /**
     Builds the exact hash identity for a zero-valued installed-book comparison.

     - Parameter registration: Installed row whose comparator fields form the identity.
     - Returns: Category, Java-case abbreviation, raw initials, and raw full-name identity.
     - Side effects: May load the pinned Java case-fold table.
     - Failure modes: None.
     */
    static func identity(
        for registration: InstalledModuleRegistration
    ) -> InstalledBookSetIdentity {
        InstalledBookSetIdentity(
            categoryOrdinal: categoryOrdinal(registration.info.category),
            abbreviation: SwordJavaStringIdentity(registration.abbreviation),
            initials: SwordJavaExactStringIdentity(registration.info.name),
            fullName: SwordJavaExactStringIdentity(registration.fullName)
        )
    }

    /**
     Orders two installed registrations through pinned JSword comparator fields.

     - Parameters:
       - lhs: First installed registration.
       - rhs: Second installed registration.
     - Returns: Negative, zero, or positive category/abbreviation/initials/name comparison.
     - Side effects: May load the pinned Java case-fold table.
     - Failure modes: None.
     */
    static func compare(
        _ lhs: InstalledModuleRegistration,
        _ rhs: InstalledModuleRegistration
    ) -> Int {
        let categoryOrder = categoryOrdinal(lhs.info.category) - categoryOrdinal(rhs.info.category)
        if categoryOrder != 0 { return categoryOrder }
        let abbreviationOrder = SwordJavaStringIdentity.compareIgnoreCase(
            lhs.abbreviation,
            rhs.abbreviation
        )
        if abbreviationOrder != 0 { return abbreviationOrder }
        let initialsOrder = compareJavaString(lhs.info.name, rhs.info.name)
        if initialsOrder != 0 { return initialsOrder }
        return compareJavaString(lhs.fullName, rhs.fullName)
    }

    /**
     Returns pinned JSword `BookCategory.ordinal()` for one projected module category.

     - Parameter category: iOS category mapped to current JSword enum order.
     - Returns: Stable integer ordinal used as the comparator's first field.
     - Side effects: None.
     - Failure modes: None; the switch is exhaustive.
     */
    static func categoryOrdinal(_ category: ModuleCategory) -> Int {
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
     Compares exact strings by Java unsigned UTF-16 `String.compareTo` semantics.

     - Parameters:
       - lhs: First exact Java string.
       - rhs: Second exact Java string.
     - Returns: First code-unit difference or UTF-16 length difference.
     - Side effects: None.
     - Failure modes: None.
     */
    static func compareJavaString(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.utf16
        let right = rhs.utf16
        for (leftUnit, rightUnit) in zip(left, right) where leftUnit != rightUnit {
            return Int(leftUnit) - Int(rightUnit)
        }
        return left.count - right.count
    }
}
