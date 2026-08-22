// BibleReaderInstalledModuleLookup.swift -- Shared Android module ownership precedence

import BibleCore
import SwordKit

/**
 Resolves one installed module using JSword's global book-name precedence.

 Native SWORD and Android SQLite books share one global registry on Android. Reader switching,
 startup eligibility, and backend de-duplication must therefore agree about which installed book
 owns a requested initials or full-name token. Centralizing the comparison prevents one surface
 from exposing a SQLite row that another surface will resolve back to a native module.
 */
enum BibleReaderInstalledModuleLookup {
    /**
     Finds the globally owned module for one requested name.

     - Parameters:
       - requestedName: Initials or full module name supplied by discovery, UI, or persistence.
       - modules: Installed metadata in manager registration order.
     - Returns: First exact initials match, last exact full-name match, then first Java-style
       case-insensitive initials or full-name match; otherwise nil.
     - Side effects: None.
     - Failure modes: Empty inputs and unmatched tokens return nil. Unicode normalization and
       locale-sensitive folding are intentionally not performed because Java `String.equals` and
       `String.equalsIgnoreCase` do neither.
     */
    static func module(
        named requestedName: String,
        in modules: [ModuleInfo]
    ) -> ModuleInfo? {
        modules.first {
            javaStringEquals($0.name, requestedName)
        } ?? modules.last {
            javaStringEquals($0.description, requestedName)
        } ?? {
            let identity = SQLiteDocumentIdentity(requestedName)
            return modules.first {
                SQLiteDocumentIdentity($0.name) == identity
                    || SQLiteDocumentIdentity($0.description) == identity
            }
        }()
    }

    /**
     Compares exact Java `String.equals` identities without Unicode normalization.

     - Parameters:
       - lhs: First Swift string projected as UTF-16 code units.
       - rhs: Second Swift string projected as UTF-16 code units.
     - Returns: True only when both UTF-16 sequences are identical.
     - Side effects: None.
     - Failure modes: None; empty strings compare equal only to another empty string.
     */
    private static func javaStringEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }
}
