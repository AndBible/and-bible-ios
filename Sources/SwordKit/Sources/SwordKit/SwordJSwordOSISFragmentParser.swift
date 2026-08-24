// SwordJSwordOSISFragmentParser.swift -- Pinned JSword OSIS source compatibility

import Foundation

/**
 Exposes pinned JSword's source-level OSIS repair as a backend-neutral string contract.

 SWORD stores some historical modules with entry-local markup that is not independently balanced,
 including `NETtext` chapter-section openers in verse zero and terminal closes in the last verse.
 Android runs every entry through `OSISFilter` before `SwordBook.addOSIS`; reader, Search, and other
 iOS consumers must share that same boundary instead of passing malformed source to Vue or inventing
 a rendered-text fallback.
 */
public enum SwordJSwordOSISSourceCompatibility {
    /**
     Repairs and serializes one raw OSIS entry through the pinned JSword filter ladder.

     - Parameters:
       - sourceXML: Exact source-level OSIS entry returned by a native or SQLite backend.
       - moduleInitials: Exact installed initials controlling JSword's module-specific repair.
     - Returns: Structurally valid child XML in original node order, or an empty string when every
       pinned repair stage rejects the entry.
     - Side effects: Performs bounded in-memory XML parsing with external entities disabled.
     - Failure modes: Never throws and never substitutes stripped/rendered text; irreparable source
       returns an empty string exactly like JSword's empty fallback paragraph content.
     */
    public static func repairedSourceXML(
        _ sourceXML: String,
        moduleInitials: String? = nil
    ) -> String {
        SwordJSwordOSISFragmentParser.parse(
            sourceXML,
            moduleInitials: moduleInitials
        ).children.map { $0.serializedXML() }.joined()
    }
}

/**
 Parses source-level OSIS and ThML fragments with the repair ladders used by AndBible's pinned JSword.

 `OSISFilter` first applies its exact MapM structural workaround, parses the fragment, then retries
 after `XMLUtil.cleanAllEntities`, `XMLUtil.recloseTags`, and finally `XMLUtil.cleanAllTags`.
 `THMLFilter` instead cleans entities first, then retries invalid-character, HTML-void-tag, and
 destructive tag repairs before its tag-to-OSIS projection. Keeping both policies beside the shared
 XML tree parser gives native SWORD and SQLite Search sources one structural compatibility boundary.
 No stage renders HTML or substitutes stripped text.
 */
enum SwordJSwordOSISFragmentParser {
    /// Synthetic fragment root used by pinned JSword's `OSISFilter.parse` method.
    private static let fragmentRootName = "xxx"

    /// XML's pinned JSword `goodEntities`; notably, `apos` is intentionally absent.
    private static let goodEntityNames: Set<String> = ["quot", "amp", "lt", "gt"]

    /// Pinned JSword replacements outside the contiguous Latin-1 entity range.
    private static let additionalEntityReplacements: [String: String] = [
        "euro": "\u{20AC}",
        "lsquo": "\u{2018}",
        "rsquo": "\u{2019}",
    ]

    /// HTML 4 Latin-1 entity names in Unicode scalar order U+00A0...U+00FF.
    private static let latin1EntityNames = """
        nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr
        deg plusmn sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest
        Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml
        ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig
        agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml
        eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml
        """
        .split(whereSeparator: \Character.isWhitespace)
        .map(String.init)

    /// Complete pinned JSword `badEntities` replacement map.
    private static let entityReplacements: [String: String] = {
        var replacements = additionalEntityReplacements
        for (offset, name) in latin1EntityNames.enumerated() {
            if let scalar = UnicodeScalar(0x00A0 + offset) {
                replacements[name] = String(scalar)
            }
        }
        return replacements
    }()

    /**
     Parses one source fragment through the pinned JSword OSIS repair ladder.

     - Parameters:
       - source: Source-level OSIS content without a required document root.
       - moduleInitials: Exact installed initials controlling pinned module-specific repair.
     - Returns: A synthetic `xxx` root containing repaired structured nodes, or an empty root when
       every pinned repair stage still fails to parse.
     - Side effects: Performs bounded in-memory XML parses with external entities disabled.
     - Failure modes: Never throws. Irreparable input becomes an empty parsed root, matching
       `OSISFilter` returning the empty content of its fallback paragraph.
     */
    static func parse(
        _ source: String,
        moduleInitials: String? = nil
    ) -> SwordXMLNode {
        let sourceRepaired = SwordOSISFragmentProcessor.androidSourceRepair(
            source,
            moduleInitials: moduleInitials
        )
        if let parsed = try? parseRawFragment(sourceRepaired) {
            return parsed
        }

        var repaired = sourceRepaired
        let entityCleaned = cleanAllEntities(repaired)
        if entityCleaned != repaired {
            repaired = entityCleaned
            if let parsed = try? parseRawFragment(repaired) {
                return parsed
            }
        }

        if let reclosed = recloseTags(repaired), reclosed != repaired {
            repaired = reclosed
            if let parsed = try? parseRawFragment(repaired) {
                return parsed
            }
        }

        if let parsed = try? parseRawFragment(cleanAllTags(repaired)) {
            return parsed
        }
        return SwordXMLNode.element(name: fragmentRootName, attributes: [:])
    }

    /**
     Parses one raw ThML fragment through pinned JSword's `THMLFilter.cleanParse` ladder.

     Unlike OSIS repair, ThML always cleans entities before its first parse, then retries after
     replacing invalid XML characters, closing HTML void tags, and finally removing malformed
     tags. This method returns the repaired ThML tree; source-tag-to-OSIS conversion remains the
     caller's responsibility.

     - Parameter source: Decoded ThML source after SWORD option filters.
     - Returns: A synthetic `xxx` root containing structurally parseable ThML nodes, or an empty
       root when every pinned repair stage fails.
     - Side effects: Performs bounded in-memory XML parses with external entities disabled.
     - Failure modes: Never throws; irreparable content becomes an empty root like JSword's empty
       fallback paragraph content.
     */
    static func parseThML(_ source: String) -> SwordXMLNode {
        let entityCleaned = cleanAllEntities(source)
        if let parsed = try? parseRawFragment(entityCleaned) {
            return parsed
        }

        let characterCleaned = cleanAllCharacters(entityCleaned)
        if let parsed = try? parseRawFragment(characterCleaned) {
            return parsed
        }

        let emptyTagsClosed = closeEmptyTags(characterCleaned)
        if let parsed = try? parseRawFragment(emptyTagsClosed) {
            return parsed
        }

        if let parsed = try? parseRawFragment(cleanAllTags(characterCleaned)) {
            return parsed
        }
        return SwordXMLNode.element(name: fragmentRootName, attributes: [:])
    }

    /**
     Wraps and parses one fragment exactly as pinned JSword `OSISFilter.parse` does.

     - Parameter source: One raw or repaired OSIS fragment without a required document root.
     - Returns: Parsed synthetic-root tree.
     - Throws: Secure XML parse errors; the public repair ladder catches these between stages.
     - Side effects: Performs one bounded in-memory parse with external entities disabled.
     */
    private static func parseRawFragment(_ source: String) throws -> SwordXMLNode {
        try SwordXMLTreeParser.parse(
            xml: "<\(fragmentRootName)>\(source)</\(fragmentRootName)>"
        )
    }

    /**
     Applies pinned JSword `XMLUtil.cleanAllEntities` semantics.

     Valid two-to-four digit numeric references and four XML entity names survive. Known Latin-1,
     euro, and single-quote entities become Unicode; unknown entities become one space; a bare or
     syntactically invalid ampersand is escaped. The omitted `apos` entity is deliberate parity.

     - Parameter source: Source fragment requiring JSword-compatible entity repair.
     - Returns: UTF-16-compatible entity-cleaned source, including pinned mutable-index advancement.
     - Side effects: Allocates and mutates one bounded UTF-16 buffer.
     - Failure modes: Unterminated ampersands are escaped and return immediately; no error is thrown.
     */
    private static func cleanAllEntities(_ source: String) -> String {
        guard source.contains("&") else { return source }
        var working = Array(source.utf16)
        var cleanFrom = 0

        while let amp = working[cleanFrom...].firstIndex(of: 0x26) {
            if let numericEnd = validNumericEntityEnd(in: working, startingAt: amp) {
                cleanFrom = numericEnd
                continue
            }

            var scan = amp + 1
            var nextCleanFrom: Int?
            while true {
                guard scan < working.count else {
                    working.replaceSubrange(amp...amp, with: Array("&amp;".utf16))
                    return String(decoding: working, as: UTF16.self)
                }

                let unit = working[scan]
                if unit == 0x3B {
                    let body = String(decoding: working[(amp + 1)..<scan], as: UTF16.self)
                    let replacement = goodEntityNames.contains(body)
                        ? Array(working[amp...scan])
                        : Array((entityReplacements[body] ?? " ").utf16)
                    working.replaceSubrange(amp...scan, with: replacement)
                    nextCleanFrom = amp + 1
                    break
                }

                if !SwordJavaTextCompatibility.isLetterOrDigit(unit) {
                    working.replaceSubrange(amp...amp, with: Array("&amp;".utf16))
                    let adjustedTerminator = scan + 4
                    nextCleanFrom = adjustedTerminator + 1
                    break
                }
                scan += 1
            }
            cleanFrom = min(nextCleanFrom ?? working.count, working.count)
        }
        return String(decoding: working, as: UTF16.self)
    }

    /**
     Applies pinned JSword `XMLUtil.cleanAllCharacters` semantics.

     - Parameter source: Entity-cleaned ThML that failed XML parsing.
     - Returns: Source with XML-invalid UTF-16 code units replaced by one ASCII space.
     - Side effects: Allocates one bounded UTF-16 buffer.
     - Failure modes: None; valid tabs, line feeds, carriage returns, BMP characters, and surrogate
       code units are retained exactly like JSword's Java-regex implementation.
     */
    private static func cleanAllCharacters(_ source: String) -> String {
        let repaired = source.utf16.map { unit -> UInt16 in
            switch unit {
            case 0x09, 0x0A, 0x0D, 0x20...0xD7FF, 0xE000...0xFFFD:
                return unit
            default:
                return 0x20
            }
        }
        return String(decoding: repaired, as: UTF16.self)
    }

    /**
     Applies pinned JSword `XMLUtil.closeEmptyTags` to common unclosed HTML void elements.

     - Parameter source: Character-cleaned ThML that still failed XML parsing.
     - Returns: Source where lowercase `img`, `hr`, and `br` start tags become self-closing unless
       they already end in `/`.
     - Side effects: Runs one bounded regular-expression replacement in memory.
     - Failure modes: If Foundation cannot compile the pinned expression, returns the input so the
       final tag-cleaning stage still runs; no error is exposed.
     */
    private static func closeEmptyTags(_ source: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"<(img|hr|br)([^>]*)(?<!/)>"#
        ) else {
            return source
        }
        let range = NSRange(location: 0, length: (source as NSString).length)
        return expression.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "<$1$2/>"
        )
    }

    /**
     Locates the exclusive end of pinned JSword's `^&#x?\d{2,4};` numeric form.

     - Parameters:
       - source: Mutable repair buffer represented as Java UTF-16 units.
       - ampersand: Index of the candidate `&` unit.
     - Returns: Exclusive index after semicolon, or nil when syntax/count differs.
     - Side effects: None.
     - Failure modes: Out-of-range and incomplete candidates return nil.
     */
    private static func validNumericEntityEnd(
        in source: [UInt16],
        startingAt ampersand: Int
    ) -> Int? {
        var cursor = ampersand + 1
        guard cursor < source.count, source[cursor] == 0x23 else { return nil }
        cursor += 1
        if cursor < source.count, source[cursor] == 0x78 {
            cursor += 1
        }

        var digitCount = 0
        while cursor < source.count,
              digitCount < 5,
              source[cursor] >= 0x30,
              source[cursor] <= 0x39 {
            digitCount += 1
            cursor += 1
        }
        guard (2...4).contains(digitCount),
              cursor < source.count,
              source[cursor] == 0x3B else {
            return nil
        }
        return cursor + 1
    }

    /**
     Applies pinned JSword `XMLUtil.recloseTags` stack semantics.

     Terminal closing tags are removed first. Simple alphabetic tags are then balanced in LIFO
     order; mismatched nesting and incomplete tag syntax reject this repair stage. The historical
     unmatched `l`/`lg` prefix repairs are preserved.

     - Parameter source: Entity-cleaned fragment that still failed XML parsing.
     - Returns: Reclosed source, or nil when the stack cannot be repaired compatibly.
     - Side effects: Allocates bounded strings/UTF-16 buffers; no external state changes.
     - Failure modes: Mismatched closes, incomplete tags, and impossible Java-whitespace scans return
       nil so the ladder advances to destructive tag cleaning.
     */
    private static func recloseTags(_ source: String) -> String? {
        var result = source
        while result.range(
            of: #"^.*</[a-zA-Z]+>[ \t\r\n]*$"#,
            options: .regularExpression
        ) != nil {
            let units = Array(result.utf16)
            guard let lastOpen = units.lastIndex(of: 0x3C) else { break }
            result = String(decoding: units[..<lastOpen], as: UTF16.self)
        }

        var openTags: [String] = []
        var cursor = result.startIndex
        var lTagFound = false
        var lgTagFound = false
        while cursor < result.endIndex,
              let match = result.range(
                of: #"</?[a-zA-Z]+"#,
                options: .regularExpression,
                range: cursor..<result.endIndex
              ) {
            let token = String(result[match])
            if token.hasPrefix("</") {
                if openTags.isEmpty, token == "</l", !lTagFound {
                    return recloseTags("<l>" + source)
                }
                if openTags.isEmpty, token == "</lg", !lgTagFound {
                    return recloseTags("<lg>" + source)
                }
                guard let lastTag = openTags.popLast(), token == "</" + lastTag else {
                    return nil
                }
            } else {
                let units = Array(result.utf16)
                let matchEnd = match.upperBound.utf16Offset(in: result)
                guard let sourceClose = units[matchEnd...].firstIndex(of: 0x3E),
                      sourceClose > 0 else {
                    return nil
                }
                var lastContent = sourceClose - 1
                let matchStart = match.lowerBound.utf16Offset(in: result)
                while SwordJavaTextCompatibility.isWhitespace(units[lastContent]) {
                    guard lastContent > matchStart else { return nil }
                    lastContent -= 1
                }
                if units[lastContent] != 0x2F {
                    if token == "<l" { lTagFound = true }
                    if token == "<lg" { lgTagFound = true }
                    openTags.append(String(token.dropFirst()))
                }
            }
            cursor = match.upperBound
        }

        for tag in openTags.reversed() {
            result += "</\(tag)>"
        }
        return result
    }

    /**
     Applies pinned JSword `XMLUtil.cleanAllTags` destructive final repair.

     Each less-than sign through the next greater-than sign (or the compatibility word heuristic)
     becomes one space. This is structural-source repair, not a rendered/stripped-text fallback.

     - Parameter source: Entity-cleaned/reclose-rejected fragment.
     - Returns: Source with malformed tag spans replaced by one ASCII space each.
     - Side effects: Mutates one bounded UTF-16 buffer in memory.
     - Failure modes: Unterminated tags consume through the pinned final heuristic; never throws.
     */
    private static func cleanAllTags(_ source: String) -> String {
        var working = Array(source.utf16)
        while let start = working.firstIndex(of: 0x3C) {
            var end = start
            var attributeStart: Int?
            while true {
                end += 1
                if end >= working.count {
                    end -= 1
                    break
                }
                let unit = working[end]
                if unit == 0x3E {
                    break
                }
                if unit == 0x20 {
                    if let attributeStart {
                        if !working[attributeStart..<end].contains(0x3D) {
                            break
                        }
                    } else {
                        attributeStart = end
                    }
                }
            }
            working.replaceSubrange(start...end, with: [0x20])
        }
        return String(decoding: working, as: UTF16.self)
    }
}
