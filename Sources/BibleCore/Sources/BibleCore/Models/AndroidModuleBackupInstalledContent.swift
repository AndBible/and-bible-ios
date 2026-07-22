// AndroidModuleBackupInstalledContent.swift - Shared Android backup selection identity

import Foundation

/**
 One installed document that Android can select for a module backup.

 The initials are the runtime identity Android registers from the installed payload, not a remote
 repository row or an iOS presentation identifier. UI selection and archive export consume this
 same value so every displayed family is exportable under exactly the identity the writer accepts.
 */
public struct AndroidModuleBackupInstalledContent: Sendable, Equatable, Identifiable {
    /// Exact Android runtime initials used for selection and export.
    public let initials: String

    /// User-visible document or resource name.
    public let displayName: String

    /// Android language code; resources without a language use an empty string.
    public let language: String

    /// Installed family whose Android registrar owns this content.
    public let family: AndroidModuleBackupContentFamily

    /// Exact module-store path whose registrar owns this identity, when one exists.
    internal let registrationRelativePath: String?

    /// Stable SwiftUI identity using Android's non-normalizing initials comparison.
    public var id: SQLiteDocumentIdentity { SQLiteDocumentIdentity(initials) }

    /**
     Creates one canonical Android module-backup catalog row.

     - Parameters:
       - initials: Exact Android runtime identity.
       - displayName: User-visible name.
       - language: Android language code or an empty string.
       - family: Registrar and archive ownership family.
       - registrationRelativePath: Exact module-store backing path used to recognize an idempotent
         restore. Presentation-only callers may omit it.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; catalog discovery validates nonempty initials.
     */
    public init(
        initials: String,
        displayName: String,
        language: String,
        family: AndroidModuleBackupContentFamily,
        registrationRelativePath: String? = nil
    ) {
        self.initials = initials
        self.displayName = displayName
        self.language = language
        self.family = family
        self.registrationRelativePath = registrationRelativePath
    }
}

/**
 Ordered identity registry matching JSword `Books.getBook` and Android custom-book admission.

 Filesystem collision validation remains a separate stricter concern. This registry deliberately
 does not normalize Unicode. Lookup checks exact initials, then exact full names, then scans both
 aliases in registration order with Java `String.equalsIgnoreCase`. Android registrars query only a
 candidate's initials before adding it, so duplicate incoming display names remain legal and become
 exact-name lookup aliases for later registrations.
 */
struct AndroidModuleBackupIdentityRegistry {
    /// Accepted rows in Android registration order; exact-name lookup uses the last matching row.
    private(set) var orderedContent: [AndroidModuleBackupInstalledContent] = []

    /**
     Claims one installed row when JSword cannot resolve the candidate initials.

     - Parameter content: Candidate row in Android registration order.
     - Returns: `true` only when no existing initials or full name resolves `content.initials`.
     - Side effects: Appends a newly claimed row to `orderedContent`.
     - Failure modes: Empty initials and duplicate JSword lookup identities return `false`.
     */
    mutating func claim(_ content: AndroidModuleBackupInstalledContent) -> Bool {
        guard !content.initials.isEmpty, self.content(matching: content.initials) == nil else {
            return false
        }
        orderedContent.append(content)
        return true
    }

    /**
     Replaces one already-registered backing row while revalidating its initials lookup.

     - Parameters:
       - content: Updated row for the same exact installed backing artifact.
       - existing: Current row being replaced.
     - Returns: `true` when no other row resolves the incoming initials.
     - Side effects: Temporarily removes and then replaces the ordered row in memory.
     - Failure modes: Returns `false` when `existing` is absent, initials are empty, or another row
       wins the incoming initials lookup. Duplicate incoming display names remain legal.
     */
    mutating func replace(
        _ content: AndroidModuleBackupInstalledContent,
        replacing existing: AndroidModuleBackupInstalledContent
    ) -> Bool {
        guard !content.initials.isEmpty,
              let orderedIndex = orderedContent.firstIndex(of: existing) else {
            return false
        }
        orderedContent.remove(at: orderedIndex)
        guard self.content(matching: content.initials) == nil else {
            orderedContent.insert(existing, at: orderedIndex)
            return false
        }
        orderedContent.insert(content, at: orderedIndex)
        return true
    }

    /**
     Resolves one value with JSword's exact-map and ordered case-insensitive precedence.

     - Parameter value: Candidate initials supplied to Android's `Books.getBook` equivalent.
     - Returns: Last exact initials owner, then last exact full-name owner, then the first row whose
       initials or full name compares equal with Java `String.equalsIgnoreCase`.
     - Side effects: None.
     - Failure modes: Empty or unmatched values return `nil`.
     */
    func content(matching value: String) -> AndroidModuleBackupInstalledContent? {
        guard !value.isEmpty else { return nil }
        if let exactInitials = orderedContent.last(where: {
            Self.javaStringEquals($0.initials, value)
        }) {
            return exactInitials
        }
        if let exactName = orderedContent.last(where: {
            Self.javaStringEquals($0.displayName, value)
        }) {
            return exactName
        }
        let identity = SQLiteDocumentIdentity(value)
        return orderedContent.first {
            SQLiteDocumentIdentity($0.initials) == identity
                || SQLiteDocumentIdentity($0.displayName) == identity
        }
    }

    /** Compares exact Java strings by UTF-16 code units without Swift canonical equivalence. */
    private static func javaStringEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }
}
