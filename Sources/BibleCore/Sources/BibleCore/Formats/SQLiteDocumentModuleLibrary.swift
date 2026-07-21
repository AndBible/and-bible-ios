// SQLiteDocumentModuleLibrary.swift -- Android manual SQLite module discovery and catalog

import Foundation
import SwordKit

/** Describes how an Android-compatible SQLite module reached the installed library. */
public enum SQLiteDocumentModuleOrigin: Equatable, Sendable {
    /// A database discovered directly beneath Android's `mybible`, `mysword`, or `esword` root.
    case manual

    /// A MyBible repository package accompanied by iOS' `module.json` sidecar.
    case myBiblePackage
}

/** Records one rejected database without hiding other readable Android modules. */
public struct SQLiteDocumentModuleDiagnostic: Equatable, Sendable {
    /// Candidate file or sidecar that could not enter the installed catalog.
    public let sourceURL: URL

    /// Stable user-facing explanation produced by the format reader or catalog validator.
    public let message: String

    /** Creates one immutable discovery diagnostic. */
    public init(sourceURL: URL, message: String) {
        self.sourceURL = sourceURL
        self.message = message
    }
}

/**
 A validated Android MyBible, MySword, or e-Sword book exposed through one reader-facing facade.

 Android registers these SQLite backends in `Books.installed()` beside ordinary SWORD modules. The
 facade preserves that identity/category contract while keeping SQLite access outside SwordKit,
 whose dependency boundary cannot import BibleCore format readers.
 */
public final class SQLiteDocumentModule {
    /// Android-compatible installed-book metadata used by picker and About surfaces.
    public let info: ModuleInfo

    /// Immutable built-in reader whose operations own independent read-only SQLite connections.
    public let reader: any SQLiteDocumentReading

    /// Whether the payload was manually discovered or installed from a MyBible package.
    public let origin: SQLiteDocumentModuleOrigin

    /**
     Creates a module from one validated reader and optional package-owned identity.

     - Parameters:
       - reader: Open read-only format reader.
       - origin: Discovery source used by export and diagnostics.
       - identity: Optional package metadata that owns repository initials and provenance only.
     - Side effects: None; built-in readers validate the file without retaining a shared handle.
     - Failure modes: None; database readers own Android's generated metadata projection.
     */
    fileprivate init(
        reader: any SQLiteDocumentReading,
        origin: SQLiteDocumentModuleOrigin,
        identity: SQLiteDocumentPackageIdentity?
    ) {
        self.reader = reader
        self.origin = origin
        let metadata = reader.metadata
        var features: ModuleFeatures = []
        if metadata.hasStrongs {
            features.insert(.strongsNumbers)
        }
        if metadata.isStrongsDictionary {
            features.formUnion([.greekDef, .hebrewDef])
        }
        if metadata.hasWordsOfChrist {
            features.insert(.redLetterWords)
        }
        self.info = ModuleInfo(
            name: identity?.initials ?? metadata.initials,
            description: metadata.description,
            category: Self.moduleCategory(format: metadata.format, category: metadata.category),
            language: metadata.language,
            moduleDriver: Self.moduleDriver(format: metadata.format, category: metadata.category),
            version: metadata.version,
            features: features,
            isRightToLeft: metadata.direction == .rtl,
            aboutMetadata: ModuleAboutMetadata(
                versification: JSwordKJVAVersification.name,
                osisId: identity?.initials ?? metadata.initials,
                repository: identity?.repository ?? ""
            )
        )
    }

    /** Creates an ordinary manually discovered module without package-owned identity overrides. */
    convenience init(
        reader: any SQLiteDocumentReading,
        origin: SQLiteDocumentModuleOrigin
    ) {
        self.init(reader: reader, origin: origin, identity: nil)
    }

    /** Returns the source-format book number for a canonical OSIS identifier. */
    public func sourceBookNumber(forOsisId osisId: String) -> Int? {
        SQLiteDocumentBookMap.sourceNumber(
            forOsisId: osisId,
            format: reader.metadata.format
        )
    }

    /** Returns the canonical OSIS identifier for one source-format book number. */
    public func osisId(forSourceBookNumber number: Int) -> String? {
        SQLiteDocumentBookMap.osisId(
            forSourceNumber: number,
            format: reader.metadata.format
        )
    }

    /**
     Resolves one Bible or commentary verse by canonical OSIS coordinates.

     - Returns: Existing raw/OSIS content, or `nil` for an unmapped or absent verse.
     - Side effects: Executes one read-only SQLite query.
     - Throws: Reader query failures.
     */
    public func verseContent(osisId: String, chapter: Int, verse: Int) throws
        -> SQLiteDocumentContent? {
        guard let book = sourceBookNumber(forOsisId: osisId) else { return nil }
        return try reader.content(for: .verse(book: book, chapter: chapter, verse: verse))
    }

    /**
     Reads every present verse in one Bible chapter without inventing gaps.

     - Returns: Source rows ordered by verse number.
     - Side effects: Executes one read-only chapter query on an operation-owned connection.
     - Throws: Key enumeration or content-query failures.
     */
    public func chapterContent(osisId: String, chapter: Int) throws
        -> [(verse: Int, text: String)] {
        guard info.category == .bible,
              let book = sourceBookNumber(forOsisId: osisId) else { return [] }
        return try reader.chapterContent(book: book, chapter: chapter)
    }

    /** Returns exact dictionary topics in Android database order. */
    public func dictionaryKeys() throws -> [String] {
        guard info.category == .dictionary else { return [] }
        return try keys().compactMap { key in
            guard case .dictionary(let value) = key else { return nil }
            return value
        }
    }

    /** Resolves one exact dictionary topic without case folding. */
    public func dictionaryContent(for key: String) throws -> SQLiteDocumentContent? {
        guard info.category == .dictionary else { return nil }
        return try reader.content(for: .dictionary(key))
    }

    /**
     Builds Android's active-canon book list from 1:1/1:2 containment probes.

     `DocumentBibleBooks` exposes a canon book only when content exists at chapter 1 verse 1 or 2.
     Once visible, chooser chapter counts come from the static KJVA versification, so malformed extra
     source chapters cannot expand or invalidate navigation.

     - Returns: Visible books in static KJVA order with static KJVA chapter counts.
     - Side effects: Streams the reader's Android-compatible containment query.
     - Throws: Reader query, cancellation, coercion, CursorWindow, or consumer failures.
     */
    public func bookList() throws -> [BookInfo] {
        guard info.category == .bible || info.category == .commentary else { return [] }
        var visibleOsisIds = Set<String>()
        try reader.forEachNavigationBookNumber { sourceBook in
            guard let osisId = osisId(forSourceBookNumber: sourceBook) else { return }
            visibleOsisIds.insert(osisId)
        }
        return JSwordKJVAVersification.books.compactMap { summary in
            guard visibleOsisIds.contains(summary.osisId) else { return nil }
            return BookInfo(
                name: summary.longName,
                osisId: summary.osisId,
                abbreviation: summary.shortName,
                chapterCount: summary.chapterCount,
                testament: summary.isNewTestament ? 2 : 1
            )
        }
    }

    /**
     Returns the module's current key set without retaining transient outcomes.

     - Returns: The source-order keys previously validated by the format reader.
     - Side effects: Executes one independent read-only SQLite enumeration on every call.
     - Throws: Re-throws the current reader failure. Cancellation and transient I/O failures are
       never cached, so an uncancelled retry can recover immediately.
     */
    private func keys() throws -> [SQLiteDocumentKey] {
        try reader.keys()
    }

    /** Maps BibleCore's durable document category into SwordKit inventory metadata. */
    private static func moduleCategory(
        format: SQLiteDocumentFormat,
        category: DocumentCategory
    ) -> ModuleCategory {
        if format == .mySword, category == .generalBook {
            return .unknown
        }
        switch category {
        case .bible: return .bible
        case .commentary: return .commentary
        case .dictionary: return .dictionary
        case .generalBook, .epub: return .generalBook
        case .map: return .map
        case .dailyDevotion: return .dailyDevotion
        }
    }

    /** Returns Android's registered custom `BookType` name for this format/category. */
    private static func moduleDriver(
        format: SQLiteDocumentFormat,
        category: DocumentCategory
    ) -> String {
        switch (format, category) {
        case (.myBible, .bible): return "MyBibleBible"
        case (.myBible, .commentary): return "MyBibleCommentary"
        case (.myBible, .dictionary): return "MyBibleDictionary"
        case (.mySword, .bible): return "MySwordBible"
        case (.mySword, .commentary): return "MySwordCommentary"
        case (.mySword, .dictionary): return "MySwordDictionary"
        case (.mySword, .generalBook): return "zText"
        case (.eSword, .bible): return "ESwordBible"
        default: return ""
        }
    }
}

/**
 Immutable discovery snapshot for Android-compatible SQLite modules beneath one module root.

 Discovery order matches Android startup: MyBible, then MySword, then e-Sword. Ordinary installed
 SWORD books remain outside this value and should be merged first so Android's existing-initials
 rule gives them precedence over manually discovered duplicates.
 */
public struct SQLiteDocumentModuleLibrary {
    /// Generous bound for iOS' small package-identity sidecar before JSON materialization.
    static let maximumPackageSidecarByteCount = 64 * 1_024

    /// Readable modules after JSword initials/full-name duplicate registration.
    public let modules: [SQLiteDocumentModule]

    /// Rejected payloads retained for diagnostics without hiding valid siblings.
    public let diagnostics: [SQLiteDocumentModuleDiagnostic]

    /**
     Discovers every supported SQLite module below an Android-compatible module root.

     - Parameter moduleRootURL: Root containing `mybible`, `mysword`, and `esword` directories.
     - Side effects: Enumerates files and opens validated SQLite readers read-only.
     - Failure modes: Individual malformed files become diagnostics. Missing family directories
       produce empty results rather than failing the whole installed-book registry.
     */
    public init(moduleRootURL: URL) {
        let root = moduleRootURL.standardizedFileURL
        var discovered: [SQLiteDocumentModule] = []
        var rejected: [SQLiteDocumentModuleDiagnostic] = []
        var packageRootPaths = Set<String>()

        let myBibleRoot = root.appendingPathComponent("mybible", isDirectory: true)
        for packageRoot in SQLiteDocumentDiscovery.directDirectories(in: myBibleRoot) {
            let sidecarURL = packageRoot.appendingPathComponent("module.json")
            guard SQLiteDocumentDiscovery.isContainedReadableRegularFile(
                sidecarURL,
                beneath: packageRoot
            ) else { continue }
            do {
                let module = try Self.loadMyBiblePackage(
                    directoryURL: packageRoot,
                    sidecarURL: sidecarURL
                )
                discovered.append(module)
                packageRootPaths.insert(
                    packageRoot.resolvingSymlinksInPath().standardizedFileURL.path
                )
            } catch {
                rejected.append(Self.diagnostic(url: sidecarURL, error: error))
            }
        }

        for url in MyBibleReader.discover(in: myBibleRoot)
            where !Self.isContained(url, inAnyResolvedRoot: packageRootPaths) {
            Self.load(url: url, reader: MyBibleReader.init(fileURL:), into: &discovered, rejected: &rejected)
        }
        let mySwordRoot = root.appendingPathComponent("mysword", isDirectory: true)
        for url in MySwordReader.discover(in: mySwordRoot) {
            Self.load(url: url, reader: MySwordReader.init(fileURL:), into: &discovered, rejected: &rejected)
        }
        let eSwordRoot = root.appendingPathComponent("esword", isDirectory: true)
        for url in ESwordReader.discover(in: eSwordRoot) {
            Self.load(url: url, reader: ESwordReader.init(fileURL:), into: &discovered, rejected: &rejected)
        }

        let registration = Self.register(discovered)
        self.modules = registration.modules
        self.diagnostics = rejected + registration.diagnostics
    }

    /**
     Creates a registry from a known discovery sequence without consulting filesystem order.

     This internal boundary lets oracle tests pin JSword registration and lookup precedence against
     an explicit Android order while production discovery continues to supply native traversal order.

     - Parameter discoveredModules: Candidate modules in Android registration order.
     - Side effects: None.
     - Failure modes: Duplicate candidate initials become diagnostics instead of throwing.
     */
    init(discoveredModules: [SQLiteDocumentModule]) {
        let registration = Self.register(discoveredModules)
        self.modules = registration.modules
        self.diagnostics = registration.diagnostics
    }

    /** Returns a module using JSword initials/name exact-then-case-insensitive precedence. */
    public func module(named name: String) -> SQLiteDocumentModule? {
        Self.lookup(name, in: modules)
    }

    /** Returns modules in one installed-book category. */
    public func modules(category: ModuleCategory) -> [SQLiteDocumentModule] {
        modules.filter { $0.info.category == category }
    }

    /** Loads one ordinary reader and captures format errors as diagnostics. */
    private static func load<Reader: SQLiteDocumentReading>(
        url: URL,
        reader: (URL) throws -> Reader,
        into modules: inout [SQLiteDocumentModule],
        rejected: inout [SQLiteDocumentModuleDiagnostic]
    ) {
        do {
            modules.append(SQLiteDocumentModule(reader: try reader(url), origin: .manual))
        } catch {
            rejected.append(diagnostic(url: url, error: error))
        }
    }

    /** Opens the exact sidecar-owned MyBible payload while retaining database-derived metadata. */
    private static func loadMyBiblePackage(
        directoryURL: URL,
        sidecarURL: URL
    ) throws -> SQLiteDocumentModule {
        let sidecarData = try readPackageSidecar(sidecarURL)
        let sidecar = try JSONDecoder().decode(SQLiteDocumentPackageSidecar.self, from: sidecarData)
        let expectedPayloadName = sidecar.packageFileName.map {
            ($0 as NSString).deletingPathExtension
        } ?? "module.SQLite3"
        guard !expectedPayloadName.isEmpty,
              (expectedPayloadName as NSString).lastPathComponent == expectedPayloadName else {
            throw SQLiteDocumentModuleLibraryError.missingPackagePayload(
                sidecar.name,
                expectedPayloadName
            )
        }
        let payload = directoryURL.appendingPathComponent(expectedPayloadName, isDirectory: false)
        guard SQLiteDocumentDiscovery.isContainedReadableRegularFile(
            payload,
            beneath: directoryURL
        ) else {
            throw SQLiteDocumentModuleLibraryError.missingPackagePayload(
                sidecar.name,
                expectedPayloadName
            )
        }
        let reader = try MyBibleReader(packagePayloadURL: payload)
        return SQLiteDocumentModule(
            reader: reader,
            origin: .myBiblePackage,
            identity: SQLiteDocumentPackageIdentity(
                initials: sidecar.name,
                repository: sidecar.sourceName
            )
        )
    }

    /** Applies JSword's duplicate-admission lookup to candidates in discovery order. */
    private static func register(
        _ discovered: [SQLiteDocumentModule]
    ) -> (modules: [SQLiteDocumentModule], diagnostics: [SQLiteDocumentModuleDiagnostic]) {
        var accepted: [SQLiteDocumentModule] = []
        var duplicates: [SQLiteDocumentModuleDiagnostic] = []
        for module in discovered {
            guard lookup(module.info.name, in: accepted) == nil else {
                duplicates.append(SQLiteDocumentModuleDiagnostic(
                    sourceURL: module.reader.metadata.sourceURL,
                    message: "Duplicate installed module lookup identity \(module.info.name)."
                ))
                continue
            }
            accepted.append(module)
        }
        return (accepted, duplicates)
    }

    /**
     Mirrors `Books.getBook`: exact initials, exact full name, then insertion-order case folding.

     Java maps overwrite duplicate full names, so exact full-name lookup selects the last registered
     owner. The final scan uses Java's UTF-16 `equalsIgnoreCase` identity and selects the first book
     whose initials or full name match.
     */
    private static func lookup(
        _ name: String,
        in modules: [SQLiteDocumentModule]
    ) -> SQLiteDocumentModule? {
        if let module = modules.first(where: { javaStringEquals($0.info.name, name) }) {
            return module
        }
        if let module = modules.last(where: { javaStringEquals($0.info.description, name) }) {
            return module
        }
        let identity = SQLiteDocumentIdentity(name)
        return modules.first {
            SQLiteDocumentIdentity($0.info.name) == identity
                || SQLiteDocumentIdentity($0.info.description) == identity
        }
    }

    /** Compares Java `String.equals` values by exact UTF-16 code units without normalization. */
    private static func javaStringEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    /** Reads one stat-validated package sidecar without permitting unbounded allocation. */
    private static func readPackageSidecar(_ sidecarURL: URL) throws -> Data {
        let values = try sidecarURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let byteCount = values.fileSize else {
            throw SQLiteDocumentModuleLibraryError.unreadablePackageSidecar(
                sidecarURL.lastPathComponent
            )
        }
        guard byteCount <= maximumPackageSidecarByteCount else {
            throw SQLiteDocumentModuleLibraryError.packageSidecarTooLarge(
                sidecarURL.lastPathComponent,
                byteCount
            )
        }

        let handle = try FileHandle(forReadingFrom: sidecarURL)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(min(byteCount, maximumPackageSidecarByteCount))
        while data.count <= maximumPackageSidecarByteCount {
            let remaining = maximumPackageSidecarByteCount + 1 - data.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumPackageSidecarByteCount else {
            throw SQLiteDocumentModuleLibraryError.packageSidecarTooLarge(
                sidecarURL.lastPathComponent,
                data.count
            )
        }
        return data
    }

    /** Returns whether a candidate's resolved path lies inside any accepted package root. */
    private static func isContained(_ url: URL, inAnyResolvedRoot roots: Set<String>) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : "\(root)/")
        }
    }

    /** Maps arbitrary reader/decoding errors into one stable diagnostic value. */
    private static func diagnostic(url: URL, error: Error) -> SQLiteDocumentModuleDiagnostic {
        SQLiteDocumentModuleDiagnostic(
            sourceURL: url,
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
    }
}

/** Sidecar-owned package identity that Android cannot derive from the extracted database. */
private struct SQLiteDocumentPackageIdentity {
    let initials: String
    let repository: String
}

/** Minimal decoding mirror of SwordKit's persisted MyBible package sidecar. */
private struct SQLiteDocumentPackageSidecar: Decodable {
    let name: String
    let description: String
    let category: String
    let language: String
    let version: String
    let sourceName: String
    let packageFileName: String?
}

/** Typed discovery failures retained as per-file diagnostics. */
private enum SQLiteDocumentModuleLibraryError: LocalizedError {
    case missingPackagePayload(String, String)
    case unreadablePackageSidecar(String)
    case packageSidecarTooLarge(String, Int)

    var errorDescription: String? {
        switch self {
        case .missingPackagePayload(let name, let payloadName):
            return "MyBible package \(name) has no readable \(payloadName) payload."
        case .unreadablePackageSidecar(let name):
            return "MyBible package sidecar \(name) is not a readable regular file."
        case .packageSidecarTooLarge(let name, let byteCount):
            return "MyBible package sidecar \(name) is \(byteCount) bytes; the maximum is \(SQLiteDocumentModuleLibrary.maximumPackageSidecarByteCount)."
        }
    }
}

/** Android's format-specific integer-to-BibleBook mappings expressed as canonical OSIS ids. */
private enum SQLiteDocumentBookMap {
    private static let protestantBooks = [
        "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth", "1Sam", "2Sam",
        "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh", "Esth", "Job", "Ps", "Prov",
        "Eccl", "Song", "Isa", "Jer", "Lam", "Ezek", "Dan", "Hos", "Joel", "Amos",
        "Obad", "Jonah", "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal", "Matt",
        "Mark", "Luke", "John", "Acts", "Rom", "1Cor", "2Cor", "Gal", "Eph", "Phil",
        "Col", "1Thess", "2Thess", "1Tim", "2Tim", "Titus", "Phlm", "Heb", "Jas", "1Pet",
        "2Pet", "1John", "2John", "3John", "Jude", "Rev",
    ]

    private static let myBible: [Int: String] = [
        10: "Gen", 20: "Exod", 30: "Lev", 40: "Num", 50: "Deut", 60: "Josh",
        70: "Judg", 80: "Ruth", 90: "1Sam", 100: "2Sam", 110: "1Kgs", 120: "2Kgs",
        130: "1Chr", 140: "2Chr", 150: "Ezra", 160: "Neh", 170: "Tob", 180: "Jdt",
        190: "Esth", 192: "AddEsth", 220: "Job", 230: "Ps", 240: "Prov", 250: "Eccl",
        260: "Song", 270: "Wis", 280: "Sir", 290: "Isa", 300: "Jer", 305: "PrAzar",
        310: "Lam", 315: "EpJer", 320: "Bar", 325: "Sus", 330: "Ezek", 340: "Dan",
        345: "AddDan", 350: "Hos", 360: "Joel", 370: "Amos", 380: "Obad", 390: "Jonah",
        400: "Mic", 410: "Nah", 420: "Hab", 430: "Zeph", 440: "Hag", 450: "Zech",
        460: "Mal", 462: "1Macc", 464: "2Macc", 466: "3Macc", 467: "4Macc",
        468: "2Esd", 470: "Matt", 480: "Mark", 490: "Luke", 500: "John", 510: "Acts",
        520: "Rom", 530: "1Cor", 540: "2Cor", 550: "Gal", 560: "Eph", 570: "Phil",
        580: "Col", 590: "1Thess", 600: "2Thess", 610: "1Tim", 620: "2Tim",
        630: "Titus", 640: "Phlm", 650: "Heb", 660: "Jas", 670: "1Pet", 680: "2Pet",
        690: "1John", 700: "2John", 710: "3John", 720: "Jude", 730: "Rev",
        780: "EpLao", 811: "1En",
    ]

    private static let mySword = Dictionary(
        uniqueKeysWithValues: protestantBooks.enumerated().map { ($0.offset + 1, $0.element) }
    )

    private static let eSword: [Int: String] = {
        var result = mySword
        result.merge([
            67: "Tob", 68: "Jdt", 69: "Wis", 70: "Sir", 71: "Bar", 72: "1Macc",
            73: "2Macc", 74: "1Esd", 75: "2Esd", 78: "PrMan",
        ]) { current, _ in current }
        return result
    }()

    static func osisId(forSourceNumber number: Int, format: SQLiteDocumentFormat) -> String? {
        map(for: format)[number]
    }

    static func sourceNumber(forOsisId osisId: String, format: SQLiteDocumentFormat) -> Int? {
        map(for: format).first { $0.value == osisId }?.key
    }

    private static func map(for format: SQLiteDocumentFormat) -> [Int: String] {
        switch format {
        case .myBible: return myBible
        case .mySword: return mySword
        case .eSword: return eSword
        }
    }
}

private extension DocumentCategory {
    /** Decodes one SwordKit category raw value into a SQLite reader category. */
    init?(moduleCategory: String) {
        switch ModuleCategory(typeString: moduleCategory) {
        case .bible: self = .bible
        case .commentary: self = .commentary
        case .dictionary: self = .dictionary
        default: return nil
        }
    }
}
