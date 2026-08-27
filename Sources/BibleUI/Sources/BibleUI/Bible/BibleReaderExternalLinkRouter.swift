import Foundation
import BibleCore

/**
 One ordered definition child collected from an Android-compatible reader link.

 Android builds a `BibleLink` list before choosing its single-link or `openMulti` execution path.
 Keeping the definition kind attached to each value lets iOS preserve that list's fragment order
 instead of regrouping every Strong's definition ahead of every morphology definition.
 */
enum BibleReaderDefinitionItem: Equatable {
    /// Resolve one Greek or Hebrew Strong's value.
    case strong(String)
    /// Resolve one Robinson morphology value.
    case robinson(String)
}

/**
 Classifies Android-compatible reader links into typed native reader routes.

 Android separates pseudo-link classification from execution: `BibleJavascriptInterface` and
 `BibleView` convert `ab-w`, `osis`, `multi`, MyBible, MySword, Strong's, morphology, EPUB,
 Downloads, My Notes, and StudyPad links into application routes, and `LinkControl` performs the
 document/window work. This type owns the same pure classification step for iOS so
 `BibleReaderController` only performs pane-specific side effects.
 */
struct BibleReaderExternalLinkRouter {
    /**
     Typed destination for an external-style reader link.

     Associated values carry only already-decoded routing data. The enum performs no SWORD access,
     bridge emission, navigation, persistence, or platform URL opening.
     */
    enum Route: Equatable {
        /// Open one Strong's or morphology definition link.
        case definition(items: [BibleReaderDefinitionItem])
        /// Open Android's `ab-w` multi-link document even when every child lookup misses.
        case multiDefinition(items: [BibleReaderDefinitionItem])
        /// Show all occurrences for a normalized Strong's key.
        case findAllOccurrences(String)
        /// Open the native error-report target.
        case errorReport
        /// Navigate inside an EPUB module.
        case epubReference(book: String, toKey: String, toId: String)
        /// Open Downloads, optionally filtered by module initials.
        case downloads(searchText: String?)
        /// Open My Notes at an ordinal whose source domain is explicitly identified.
        case myNotes(v11n: String, ordinal: Int)
        /// Open StudyPad for a label and optional bookmark entry.
        case studyPad(labelId: UUID, bookmarkId: UUID?)
        /// Resolve one or more OSIS query values in their declared source domain.
        case osisReferences(
            values: [String],
            v11n: String,
            documentInitials: String?,
            forceDocument: Bool
        )
        /// Resolve one or more multi-link OSIS values in their declared source domain.
        case multiReferences(values: [String], v11n: String)
        /// Navigate a SWORD reference stripped from a `sword://` pseudo-link.
        case swordReference(String)
        /// Navigate an OSIS-style reference produced by MyBible/MySword links.
        case osisNavigation(String)
        /// Open an ordinary platform URL.
        case platformURL(URL)
    }

    /**
     Converts a raw bridge link string into a typed route.

     - Parameter link: Raw link emitted by Vue or module HTML.
     - Returns: A route when the link is recognized or a valid platform URL, otherwise `nil`.
     - Side effects: None.
     - Failure modes: Malformed pseudo-links return `nil`, matching Android's "do nothing" path for
       incomplete app links. Unknown but valid URLs route to platform URL handling.
     */
    func route(for link: String) -> Route? {
        if link.hasPrefix("ab-w://") {
            return definitionRoute(fromAbWordLink: link)
        }
        if link.hasPrefix("strongs://") {
            return standaloneStrongsRoute(from: link)
        }
        if link.hasPrefix("morphology://") {
            return standaloneMorphologyRoute(from: link)
        }
        if link.hasPrefix("ab-find-all://") {
            return findAllRoute(from: link)
        }
        if link.hasPrefix("ab-error://") {
            return .errorReport
        }
        if link.hasPrefix("epub-ref://") {
            return epubRoute(from: link)
        }
        if link.hasPrefix("download://") {
            return .downloads(searchText: BibleReaderBridgeEventRouter.downloadSearchText(from: link))
        }
        if link.hasPrefix("my-notes://") {
            return myNotesRoute(from: link)
        }
        if link.hasPrefix("journal://") {
            return studyPadRoute(from: link)
        }
        if link.hasPrefix("osis://") {
            return osisRoute(from: link)
        }
        if link.hasPrefix("multi://") {
            return multiRoute(from: link)
        }
        if link.hasPrefix("sword://") {
            return swordRoute(from: link)
        }
        if link.hasPrefix("B:") {
            return myBibleRoute(from: link)
        }
        if link.hasPrefix("S:") {
            let strongRef = String(link.dropFirst(2))
            return strongRef.isEmpty ? nil : .definition(items: [.strong(strongRef)])
        }
        if link.hasPrefix("#b") {
            return mySwordBibleRoute(from: link)
        }
        if link.hasPrefix("#s") || link.hasPrefix("#d") {
            let strongRef = String(link.dropFirst(2))
            return strongRef.isEmpty ? nil : .definition(items: [.strong(strongRef)])
        }
        return URL(string: link).map(Route.platformURL)
    }

    /**
     Reproduces Android's `ab-w://` single-versus-multi definition dispatch contract.

     - Parameter link: Absolute `ab-w://` link whose raw query children may contain `strong`,
       `robinson`, unsupported, empty, or malformed values.
     - Returns: A single-definition route for one raw query child containing a supported nonempty
       value, a multi-definition route whenever the parsed URL has more than one raw query child,
       or `nil` when a single/missing child provides no supported value. Multi routes intentionally
       retain an empty recognized-item list because Android still opens an empty Multi document.
     - Side effects: None. Supported children are projected in Android's first-seen query-name
       order and then in value order within each name; unsupported and empty values affect raw
       multi cardinality but do not become definition items.
     - Failure modes: Invalid URL component syntax returns `nil`; malformed individual values are
       omitted without reordering the remaining supported children.
     */
    private func definitionRoute(fromAbWordLink link: String) -> Route? {
        guard let components = URLComponents(string: link) else { return nil }
        let queryItems = components.queryItems ?? []
        var orderedNames: [String] = []
        for item in queryItems where !orderedNames.contains(item.name) {
            orderedNames.append(item.name)
        }

        var definitionItems: [BibleReaderDefinitionItem] = []
        for name in orderedNames {
            for item in queryItems where item.name == name {
                guard let value = item.value, !value.isEmpty else { continue }
                switch name {
                case "strong":
                    definitionItems.append(.strong(value))
                case "robinson":
                    definitionItems.append(.robinson(value))
                default:
                    break
                }
            }
        }
        if queryItems.count > 1 {
            return .multiDefinition(items: definitionItems)
        }
        guard !definitionItems.isEmpty else { return nil }
        return .definition(items: definitionItems)
    }

    /**
     Parses document-independent `strongs://` links into Android's Strong's definition route.
     */
    private func standaloneStrongsRoute(from link: String) -> Route? {
        guard let components = URLComponents(string: link) else { return nil }
        let ref = components.host ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ref.isEmpty ? nil : .definition(items: [.strong(ref)])
    }

    /**
     Parses document-independent morphology links into the Robinson morphology route iOS renders.
     */
    private func standaloneMorphologyRoute(from link: String) -> Route? {
        guard let components = URLComponents(string: link) else { return nil }
        let code = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return code.isEmpty ? nil : .definition(items: [.robinson(code)])
    }

    /**
     Parses Android's "find all occurrences" pseudo-link with its exact Strong's normalization.

     Android lowercases the emitted dictionary key, then prefixes keys that do not already begin
     with `g` or `h` using the first character of the feature type. The latter intentionally maps
     the combined `hebrew-and-greek` feature to `h`, just as `type[0]` does on Android.

     - Parameter link: Rendered `ab-find-all` URL carrying `type` and `name` query items.
     - Returns: A normalized Find All route, or nil when the name is empty or a bare value has no
       feature type from which to derive its prefix.
     - Side effects: None.
     - Failure modes: Malformed URLs, missing names, and missing prefix metadata fail closed.
     */
    private func findAllRoute(from link: String) -> Route? {
        guard let components = URLComponents(string: link) else { return nil }
        let items = components.queryItems ?? []
        let type = items.first(where: { $0.name == "type" })?.value
        var name = (items.first(where: { $0.name == "name" })?.value ?? "").lowercased()
        guard !name.isEmpty else { return nil }
        if !name.hasPrefix("g"), !name.hasPrefix("h") {
            guard let typePrefix = type?.first else { return nil }
            name = "\(typePrefix)\(name)"
        }
        return .findAllOccurrences(name)
    }

    /**
     Parses EPUB reference query parameters emitted by rendered EPUB/module links.
     */
    private func epubRoute(from link: String) -> Route? {
        guard let components = URLComponents(string: link),
              let items = components.queryItems,
              let book = items.first(where: { $0.name == "book" })?.value,
              let toKey = items.first(where: { $0.name == "toKey" })?.value,
              let toId = items.first(where: { $0.name == "toId" })?.value else {
            return nil
        }
        return .epubReference(book: book, toKey: toKey, toId: toId)
    }

    /**
     Parses My Notes links into optional jump metadata.
     */
    private func myNotesRoute(from link: String) -> Route? {
        guard let components = URLComponents(string: link) else { return nil }
        let items = components.queryItems ?? []
        guard let v11n = items.first(where: { $0.name == "v11n" })?.value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !v11n.isEmpty,
              let ordinal = items.first(where: { $0.name == "ordinal" })?.value.flatMap(Int.init),
              ordinal > 0 else {
            return nil
        }
        return .myNotes(v11n: v11n, ordinal: ordinal)
    }

    /**
     Parses StudyPad journal links into label and optional bookmark identifiers.
     */
    private func studyPadRoute(from link: String) -> Route? {
        guard let components = URLComponents(string: link),
              let items = components.queryItems,
              let labelId = items.first(where: { $0.name == "id" })?.value,
              let labelUUID = UUID(uuidString: labelId) else {
            return nil
        }
        let entryId = items.first(where: { $0.name == "bookmarkId" })?.value
            ?? items.first(where: { $0.name == "entryId" })?.value
        return .studyPad(labelId: labelUUID, bookmarkId: entryId.flatMap(UUID.init(uuidString:)))
    }

    /**
     Parses Android `osis://` links and preserves each query value for controller-side resolution.
     */
    private func osisRoute(from link: String) -> Route? {
        guard let components = URLComponents(string: link) else { return nil }
        let items = components.queryItems ?? []
        let values = items
            .filter { $0.name == "osis" }
            .compactMap(\.value)
        guard !values.isEmpty else { return nil }
        let v11n = items.first(where: { $0.name == "v11n" })?.value
            .flatMap { $0.isEmpty ? nil : $0 } ?? JSwordKJVAVersification.name
        let documentInitials = items.first(where: { $0.name == "doc" })?.value
            .flatMap { $0.isEmpty ? nil : $0 }
        let forceDocument = androidBooleanQueryParameter(
            named: "force-doc",
            in: items,
            defaultValue: false
        )
        return .osisReferences(
            values: values,
            v11n: v11n,
            documentInitials: documentInitials,
            forceDocument: forceDocument
        )
    }

    /**
     Parses one query item with Android `Uri.getBooleanQueryParameter` semantics.

     Android treats an absent item as the caller's default, and treats only case-insensitive
     `false` or `0` as false once the item is present. Bare parameters and every other value are
     true.

     - Parameters:
       - name: Query parameter name.
       - items: Decoded URL query items.
       - defaultValue: Value returned when the parameter is absent.
     - Returns: Android-compatible Boolean value.
     - Side effects: None.
     - Failure modes: None; malformed or bare present values intentionally evaluate to true.
     */
    private func androidBooleanQueryParameter(
        named name: String,
        in items: [URLQueryItem],
        defaultValue: Bool
    ) -> Bool {
        guard let item = items.first(where: { $0.name == name }) else { return defaultValue }
        guard let value = item.value?.lowercased() else { return true }
        return value != "false" && value != "0"
    }

    /**
     Parses Android `multi://` links and preserves all OSIS query values in emitted order.
     */
    private func multiRoute(from link: String) -> Route? {
        guard let components = URLComponents(string: link) else { return nil }
        let items = components.queryItems ?? []
        let values = items
            .filter { $0.name == "osis" }
            .compactMap(\.value)
        guard !values.isEmpty else { return nil }
        let v11n = items.first(where: { $0.name == "v11n" })?.value
            .flatMap { $0.isEmpty ? nil : $0 } ?? JSwordKJVAVersification.name
        return .multiReferences(values: values, v11n: v11n)
    }

    /**
     Strips the module component from `sword://module/ref` links and returns the target reference.
     */
    private func swordRoute(from link: String) -> Route? {
        var ref = String(link.dropFirst("sword://".count))
        while ref.hasPrefix("/") { ref = String(ref.dropFirst()) }
        while ref.hasSuffix("/") { ref = String(ref.dropLast()) }
        guard !ref.isEmpty else { return nil }
        if let slashIndex = ref.firstIndex(of: "/") {
            ref = String(ref[ref.index(after: slashIndex)...])
        }
        return ref.isEmpty ? nil : .swordReference(ref)
    }

    /**
     Converts a MyBible `B:` Bible link into an OSIS reference using Android's book-number map.
     */
    private func myBibleRoute(from link: String) -> Route? {
        let parts = link.split(separator: " ", maxSplits: 1)
        guard parts.count >= 2 else { return nil }
        let bookPart = String(parts[0])
        guard bookPart.hasPrefix("B:"),
              let bookInt = Int(bookPart.dropFirst(2)),
              let osisId = Self.myBibleIntToOsisId[bookInt] else {
            return nil
        }
        let chapterVerse = String(parts[1]).components(separatedBy: ":")
        guard let chapterText = chapterVerse.first, let chapter = Int(chapterText) else { return nil }
        let verse = chapterVerse.count >= 2 ? Int(chapterVerse[1]) : nil
        return .osisNavigation(verse.map { "\(osisId).\(chapter).\($0)" } ?? "\(osisId).\(chapter)")
    }

    /**
     Converts a MySword `#b` Bible link into an OSIS reference using Android's book-number map.
     */
    private func mySwordBibleRoute(from link: String) -> Route? {
        let rest = String(link.dropFirst(2))
        let parts = rest.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2,
              let osisId = Self.mySwordIntToOsisId[parts[0]] else {
            return nil
        }
        let chapter = parts[1]
        let verse = parts.count >= 3 ? parts[2] : nil
        return .osisNavigation(verse.map { "\(osisId).\(chapter).\($0)" } ?? "\(osisId).\(chapter)")
    }

    /**
     MySword sequential book numbering (1-66, Protestant canon).
     Matches Android's `mySwordIntToBibleBook` map.
     */
    private static let mySwordIntToOsisId: [Int: String] = [
        1: "Gen", 2: "Exod", 3: "Lev", 4: "Num", 5: "Deut",
        6: "Josh", 7: "Judg", 8: "Ruth", 9: "1Sam", 10: "2Sam",
        11: "1Kgs", 12: "2Kgs", 13: "1Chr", 14: "2Chr",
        15: "Ezra", 16: "Neh", 17: "Esth", 18: "Job",
        19: "Ps", 20: "Prov", 21: "Eccl", 22: "Song",
        23: "Isa", 24: "Jer", 25: "Lam", 26: "Ezek", 27: "Dan",
        28: "Hos", 29: "Joel", 30: "Amos", 31: "Obad", 32: "Jonah",
        33: "Mic", 34: "Nah", 35: "Hab", 36: "Zeph",
        37: "Hag", 38: "Zech", 39: "Mal",
        40: "Matt", 41: "Mark", 42: "Luke", 43: "John",
        44: "Acts", 45: "Rom", 46: "1Cor", 47: "2Cor",
        48: "Gal", 49: "Eph", 50: "Phil", 51: "Col",
        52: "1Thess", 53: "2Thess", 54: "1Tim", 55: "2Tim",
        56: "Titus", 57: "Phlm", 58: "Heb",
        59: "Jas", 60: "1Pet", 61: "2Pet",
        62: "1John", 63: "2John", 64: "3John",
        65: "Jude", 66: "Rev",
    ]

    /**
     MyBible non-sequential book numbering, including the deuterocanonical IDs Android recognizes.
     Matches Android's `myBibleIntToBibleBook` map.
     */
    private static let myBibleIntToOsisId: [Int: String] = [
        10: "Gen", 20: "Exod", 30: "Lev", 40: "Num", 50: "Deut",
        60: "Josh", 70: "Judg", 80: "Ruth",
        90: "1Sam", 100: "2Sam", 110: "1Kgs", 120: "2Kgs",
        130: "1Chr", 140: "2Chr",
        150: "Ezra", 160: "Neh", 190: "Esth",
        220: "Job", 230: "Ps", 240: "Prov", 250: "Eccl", 260: "Song",
        290: "Isa", 300: "Jer", 310: "Lam", 320: "Bar",
        330: "Ezek", 340: "Dan",
        350: "Hos", 360: "Joel", 370: "Amos", 380: "Obad",
        390: "Jonah", 400: "Mic", 410: "Nah", 420: "Hab",
        430: "Zeph", 440: "Hag", 450: "Zech", 460: "Mal",
        470: "Matt", 480: "Mark", 490: "Luke", 500: "John",
        510: "Acts", 520: "Rom", 530: "1Cor", 540: "2Cor",
        550: "Gal", 560: "Eph", 570: "Phil", 580: "Col",
        590: "1Thess", 600: "2Thess", 610: "1Tim", 620: "2Tim",
        630: "Titus", 640: "Phlm", 650: "Heb",
        660: "Jas", 670: "1Pet", 680: "2Pet",
        690: "1John", 700: "2John", 710: "3John",
        720: "Jude", 730: "Rev",
        170: "Tob", 180: "Jdt", 270: "Wis", 280: "Sir",
        462: "1Macc", 464: "2Macc", 466: "3Macc", 467: "4Macc",
        468: "2Esd",
    ]
}
