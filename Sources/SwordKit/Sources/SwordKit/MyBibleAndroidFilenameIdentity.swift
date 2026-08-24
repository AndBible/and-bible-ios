// MyBibleAndroidFilenameIdentity.swift -- Android MyBible filename projection

import Foundation

/**
 Projects one MyBible filename through Android's current filename-owned identity contract.

 Android's MyBible installer derives remote initials and abbreviation from
 `File(file_name).nameWithoutExtension`, then replaces characters through the historical
 `[^a-zA-z0-9]` expression. Installed payload projection uses the same basename operations on the
 opened SQLite filename. Keeping that behavior in one immutable value prevents catalog and
 installed-package identity from drifting again.

 Construction performs no file access and cannot fail. Values preserve Java-visible spelling; no
 normalization, locale folding, or trimming is applied.
 */
struct MyBibleAndroidFilenameIdentity: Equatable, Sendable {
    /// Exact final path component with only its last extension removed.
    let nameWithoutExtension: String

    /// Android module initials, including the `MyBible-` family prefix.
    let initials: String

    /// Exact basename segment before the first dot used as Android's visible abbreviation.
    let abbreviation: String

    /**
     Creates Android's filename-owned MyBible identity.

     - Parameter fileName: Manifest path or installed payload filename evaluated with Android's
       slash-separated `File.name` behavior.
     - Returns: A complete immutable identity through the initialized value.
     - Side effects: None.
     - Failure modes: None; empty and leading-dot filenames intentionally produce empty components
       exactly as Android does.
     */
    init(fileName: String) {
        let leafName = Self.androidFileName(fileName)
        let baseName = Self.removingLastExtension(leafName)
        nameWithoutExtension = baseName
        initials = "MyBible-" + Self.sanitizeModuleName(baseName)
        abbreviation = Self.abbreviation(from: baseName)
    }

    /**
     Infers Android's remote MyBible category from one manifest filename.

     - Parameter fileName: Exact manifest `file_name`, including any directory prefix.
     - Returns: Commentary for the exact lowercase `.commentaries` marker, dictionary for the exact
       lowercase `.dictionaries` marker, and Bible otherwise.
     - Side effects: None.
     - Failure modes: None; missing and differently cased markers deliberately fall back to Bible.
     */
    static func category(forPackageFileName fileName: String) -> ModuleCategory {
        if fileName.contains(".commentaries") {
            return .commentary
        }
        if fileName.contains(".dictionaries") {
            return .dictionary
        }
        return .bible
    }

    /**
     Applies Android's historical MyBible `[^a-zA-z0-9]` replacement.

     Java's `A-z` range spans ASCII values 65 through 122, preserving `[\\]^_\`` in addition to
     letters and digits.

     - Parameter value: Exact basename before the `MyBible-` prefix is added.
     - Returns: ASCII digits and code points `A...z` unchanged; every other Unicode scalar becomes
       one underscore.
     - Side effects: None.
     - Failure modes: None; every Swift string has a finite Unicode-scalar projection.
     */
    static func sanitizeModuleName(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            let code = scalar.value
            let accepted = (48...57).contains(code) || (65...122).contains(code)
            return accepted ? String(scalar) : "_"
        }.joined()
    }

    /**
     Reproduces the retired iOS remote identity only to locate its one-way migration source.

     Builds before Android parity removed only the archive extension through `NSString`, selected
     the final path component, trimmed an empty basename to `module`, and preserved every Unicode
     scalar accepted by Foundation's `alphanumerics` set. The result must never be used for catalog,
     lookup, or new publication identity.

     - Parameter fileName: Exact manifest package filename stored in the installed sidecar.
     - Returns: The single pre-parity iOS directory name eligible for proven atomic removal.
     - Side effects: None.
     - Failure modes: None; the retired empty-name fallback is reproduced only for migration.
     */
    static func obsoletePreParityIOSDirectoryName(forPackageFileName fileName: String) -> String {
        let baseName = ((fileName as NSString).deletingPathExtension as NSString).lastPathComponent
        let value = baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "module"
            : baseName
        let allowed = CharacterSet.alphanumerics
        let sanitized = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return "MyBible-" + sanitized
    }

    /**
     Selects Android/Linux `File.name` without treating a backslash as a path separator.

     - Parameter fileName: Exact manifest or payload filename.
     - Returns: Text after the last forward slash, or the unchanged input when no slash exists.
     - Side effects: None.
     - Failure modes: None; a trailing slash produces an empty filename.
     */
    private static func androidFileName(_ fileName: String) -> String {
        guard let slash = fileName.lastIndex(of: "/") else { return fileName }
        return String(fileName[fileName.index(after: slash)...])
    }

    /**
     Mirrors Kotlin's `nameWithoutExtension` operation.

     - Parameter fileName: One slash-free filename.
     - Returns: Text before the final dot, or the unchanged filename when no dot exists.
     - Side effects: None.
     - Failure modes: None; a leading dot yields an empty value.
     */
    private static func removingLastExtension(_ fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: ".") else { return fileName }
        return String(fileName[..<dot])
    }

    /**
     Derives Android's visible MyBible abbreviation.

     - Parameter baseName: Filename after removing only its final extension.
     - Returns: Exact text before the first dot, including an empty value for a leading dot.
     - Side effects: None.
     - Failure modes: None; basenames without a dot are returned unchanged.
     */
    private static func abbreviation(from baseName: String) -> String {
        guard let dot = baseName.firstIndex(of: ".") else { return baseName }
        return String(baseName[..<dot])
    }
}
