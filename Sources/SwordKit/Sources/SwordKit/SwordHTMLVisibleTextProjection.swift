// SwordHTMLVisibleTextProjection.swift -- Android Html.fromHtml visible-string parity

import Foundation

/**
 Converts concatenated Android Search preview source into its post-`htmlToSpan` visible string.

 Android first concatenates JDOM content, then gives that complete value to AOSP's tolerant
 TagSoup `HTMLScanner`/`Parser` through `Html.fromHtml(..., FROM_HTML_MODE_LEGACY)`. This pure
 projection mirrors the scanner states that affect visible text, TagSoup's `makeName` repair, and
 the supported block stack without introducing a UI or attributed-string dependency.
 */
enum SwordHTMLVisibleTextProjection {
    /**
     Carries one committed start/end tag after TagSoup `Parser.makeName` repair.

     Values are produced only by the scanner helpers and consumed by the schema-backed document;
     they perform no I/O or mutation and cannot fail after construction.
     */
    private struct TagToken {
        /// Exact QName after TagSoup `Parser.makeName` repair.
        let name: String
        /// Whether this came from the scanner's end-tag state.
        let isClosing: Bool
        /// Whether the scanner committed an immediately empty start tag.
        let isSelfClosing: Bool
    }

    /**
     Carries the parser event and exclusive cursor for one source range beginning at `<`.

     Buffer-run metadata preserves the persistent AOSP scanner capacity contract across otherwise
     independent tokens. Construction is deterministic and has no side effects or failure state.
     */
    private struct ScannerToken {
        /// Visible/event effect of the consumed scanner range.
        let payload: Payload
        /// Exclusive Unicode-scalar cursor after the consumed range.
        let end: Int
        /// Non-PCDATA scanner buffer runs completed while consuming this token.
        let nonPCDATABufferRuns: [Int]

        /**
         Creates one token while retaining persistent scanner-buffer growth evidence.

         - Parameters:
           - payload: Parser/visible event produced by the consumed syntax.
           - end: Exclusive scalar cursor after the token.
           - nonPCDATABufferRuns: Completed Java UTF-16 buffer-run lengths in scanner order.
         - Side effects: None.
         - Failure modes: None; scanner helpers own range validation before initialization.
         */
        init(payload: Payload, end: Int, nonPCDATABufferRuns: [Int] = []) {
            self.payload = payload
            self.end = end
            self.nonPCDATABufferRuns = nonPCDATABufferRuns
        }

        /// Event kinds needed by Android's plain visible-string projection.
        enum Payload {
            /// A committed repaired tag event.
            case tag(TagToken)
            /// CDATA-section character data; entities stay literal in this scanner state.
            case cdata(String)
            /// A declaration, PI, comment, or uncommitted tag with no visible event.
            case ignored
        }
    }

    /// Attribute scanner states that determine which `>` actually commits a start tag.
    private enum StartTagState {
        case tagWhitespace
        case attributeName
        case equals
        case attributeValue
        case unquotedValue
        case singleQuotedValue
        case doubleQuotedValue
        case emptyTag
    }

    /**
     Projects one complete HTML-like preview source into Android-visible plain text.

     - Parameter source: Raw JDOM child-content concatenation after note/reference exclusion.
     - Returns: Text after one pinned AOSP entity pass, tolerant tag repair/removal, UTF-16
       whitespace collapse, `br`, `img`, CDATA, and legacy block-stack behavior.
     - Side effects: Loads the pinned TagSoup entity table on first use and allocates bounded text.
     - Failure modes: A lone/space-followed `<` remains text; scanner-committed malformed markup is
       dropped or repaired, and all open supported blocks are synthetically closed at EOF.
    */
    static func project(_ source: String) -> String {
        let scannerSource = SwordTagSoupEntityDecoder.normalizeRawScannerText(source)
        let input = Array(scannerSource.unicodeScalars)
        let start = input.first?.value == 0xFEFF ? 1 : 0
        var document = SwordTagSoupVisibleDocument()
        var scannerBuffer = SwordTagSoupEntityDecoder.ScannerBufferState()
        var textStart = start
        var cursor = start

        while cursor < input.count {
            guard input[cursor].value == 0x3C,
                  let token = scannerToken(in: input, startingAt: cursor) else {
                cursor += 1
                continue
            }

            appendText(input[textStart..<cursor], bufferState: &scannerBuffer, to: &document)
            for run in token.nonPCDATABufferRuns {
                scannerBuffer.observeNonPCDATARun(utf16Count: run)
            }
            switch token.payload {
            case .tag(let tag):
                if tag.isClosing {
                    document.endTag(repairedName: tag.name)
                } else if let cdataName = document.startTag(
                    repairedName: tag.name,
                    isSelfClosing: tag.isSelfClosing
                ) {
                    let raw = rawElementContent(
                        in: input,
                        from: token.end,
                        closingName: cdataName
                    )
                    for event in SwordTagSoupEntityDecoder.normalizeRawScannerTextEvents(
                        raw.content,
                        bufferState: &scannerBuffer
                    ) {
                        document.appendCharacters(event)
                    }
                    if let closingName = raw.closingName {
                        document.endTag(repairedName: closingName)
                    }
                    cursor = raw.end
                    textStart = cursor
                    continue
                }
            case .cdata(let text):
                for event in SwordTagSoupEntityDecoder.normalizeRawScannerTextEvents(
                    text,
                    bufferState: &scannerBuffer
                ) {
                    document.appendCharacters(event)
                }
            case .ignored:
                break
            }
            cursor = token.end
            textStart = cursor
        }
        appendText(input[textStart..<input.count], bufferState: &scannerBuffer, to: &document)
        document.finish()
        return document.output
    }

    /**
     Decodes one ordinary PCDATA scalar slice and emits its Android character callbacks.

     - Parameters:
       - source: Scalar range between committed markup tokens.
       - bufferState: Persistent scanner buffer shared by the complete source document.
       - document: Schema-backed visible document receiving decoded callbacks.
     - Side effects: Mutates buffer capacity/size and visible document output in source order.
     - Failure modes: Empty ranges are ignored; invalid entities remain literal through decoder
       policy rather than aborting projection.
     */
    private static func appendText(
        _ source: ArraySlice<UnicodeScalar>,
        bufferState: inout SwordTagSoupEntityDecoder.ScannerBufferState,
        to document: inout SwordTagSoupVisibleDocument
    ) {
        guard !source.isEmpty else { return }
        for event in SwordTagSoupEntityDecoder.decodePCDATAEvents(
            string(from: source),
            bufferState: &bufferState
        ) {
            document.appendCharacters(event)
        }
    }

    /**
     Consumes one AOSP-visible scanner construct beginning at `<`.

     The subset is state-shaped rather than validity-shaped: incomplete GI/declaration/comment/PI
     input is consumed at EOF, end tags commit at EOF, whitespace immediately after `<` returns to
     PCDATA, and exact uppercase CDATA sections emit raw character data.

     - Parameters:
       - source: Complete normalized scanner source.
       - opening: Index of the `<` that entered TagSoup's tag state.
     - Returns: Consumed token and persistent buffer runs, or nil only for a literal `<` path.
     - Side effects: None.
     - Failure modes: Malformed constructs are converted to the scanner's ignored/committed EOF
       events; this helper never throws.
     */
    private static func scannerToken(
        in source: [UnicodeScalar],
        startingAt opening: Int
    ) -> ScannerToken? {
        let afterOpening = opening + 1
        guard afterOpening < source.count else { return nil }
        let first = source[afterOpening].value
        if isScannerSpace(source[afterOpening]) {
            return nil
        }
        if first == 0x21 {
            return declarationToken(in: source, afterBang: afterOpening + 1)
        }
        if first == 0x3F {
            let end = firstIndex(of: [0x3E], in: source, from: afterOpening + 1)
                .map { $0 + 1 } ?? source.count
            return ScannerToken(
                payload: .ignored,
                end: end,
                nonPCDATABufferRuns: processingInstructionBufferRuns(
                    in: source,
                    from: afterOpening + 1,
                    to: end
                )
            )
        }
        if first == 0x2F {
            return endTagToken(in: source, nameStart: afterOpening + 1)
        }
        return startTagToken(in: source, nameStart: afterOpening)
    }

    /**
     Consumes an AOSP schema `F_CDATA` element body until its exact case-insensitive end tag.

     Nonmatching end tags are reconstructed from the scanner's whitespace-free GI buffer and stay
     raw character data; entities are intentionally not decoded. The returned end follows a
     matching close or EOF.

     - Parameters:
       - source: Normalized complete scanner source.
       - start: First scalar after the committed CDATA element start tag.
       - closingName: Canonical schema QName whose matching end exits CDATA.
     - Returns: Literal content, exclusive cursor, and matched repaired close name when present.
     - Side effects: None.
     - Failure modes: EOF returns the scanner-preserved content and no closing name.
     */
    private static func rawElementContent(
        in source: [UnicodeScalar],
        from start: Int,
        closingName: String
    ) -> (content: String, end: Int, closingName: String?) {
        var output = ""
        var contentStart = start
        var cursor = start
        while cursor < source.count {
            guard source[cursor].value == 0x3C else {
                cursor += 1
                continue
            }
            guard cursor + 1 < source.count else {
                output += string(from: source[contentStart..<cursor])
                return (output, source.count, nil)
            }
            guard source[cursor + 1].value == 0x2F else {
                cursor += 2
                continue
            }
            var close = cursor + 2
            var name: [UnicodeScalar] = []
            while close < source.count, source[close].value != 0x3E {
                if !isScannerSpace(source[close]) {
                    name.append(source[close])
                }
                close += 1
            }
            output += string(from: source[contentStart..<cursor])
            let bufferedName = string(from: name[...])
            let end = close < source.count ? close + 1 : source.count
            if SwordJavaTextCompatibility.cdataEndTagEquals(bufferedName, closingName) {
                return (
                    output,
                    end,
                    makeName(name[...])
                )
            }
            output += "</\(bufferedName)>"
            cursor = end
            contentStart = end
        }
        output += string(from: source[contentStart..<source.count])
        return (output, source.count, nil)
    }

    /**
     Consumes a declaration, comment, or exact CDATA-section scanner path.

     - Parameters:
       - source: Complete normalized scalar source.
       - afterBang: First scalar after the `<!` introducer.
     - Returns: Ignored declaration/comment event or raw CDATA payload plus its exclusive cursor and
       non-PCDATA buffer-growth runs.
     - Side effects: None.
     - Failure modes: Unterminated constructs consume through EOF, matching scanner actions.
     */
    private static func declarationToken(
        in source: [UnicodeScalar],
        afterBang: Int
    ) -> ScannerToken {
        if hasPrefix([0x5B, 0x43, 0x44, 0x41, 0x54, 0x41, 0x5B], in: source, at: afterBang) {
            let contentStart = afterBang + 7
            if let closing = firstIndex(of: [0x5D, 0x5D, 0x3E], in: source, from: contentStart) {
                return ScannerToken(
                    payload: .cdata(string(from: source[contentStart..<closing])),
                    end: closing + 3,
                    nonPCDATABufferRuns: [utf16Count(source[contentStart..<(closing + 2)])]
                )
            }
            return ScannerToken(
                payload: .ignored,
                end: source.count,
                nonPCDATABufferRuns: [utf16Count(source[contentStart..<source.count])]
            )
        }
        if afterBang < source.count, source[afterBang].value == 0x2D {
            let end = firstIndex(of: [0x2D, 0x2D, 0x3E], in: source, from: afterBang + 1)
                .map { $0 + 3 } ?? source.count
            let contentStart = min(afterBang + 2, end)
            let contentEnd = end >= 3 ? end - 3 : contentStart
            return ScannerToken(
                payload: .ignored,
                end: end,
                nonPCDATABufferRuns: [utf16Count(source[contentStart..<max(contentStart, contentEnd)])]
            )
        }
        let end = firstIndex(of: [0x3E], in: source, from: afterBang)
            .map { $0 + 1 } ?? source.count
        let contentEnd = end > afterBang && source[end - 1].value == 0x3E ? end - 1 : end
        return ScannerToken(
            payload: .ignored,
            end: end,
            nonPCDATABufferRuns: [utf16Count(source[afterBang..<contentEnd])]
        )
    }

    /**
     Consumes the scanner's GI and attribute states for one start tag.

     - Parameters:
       - source: Complete normalized scalar source.
       - nameStart: First GI scalar after `<`.
     - Returns: Committed repaired tag or ignored malformed token, exclusive cursor, and completed
       scanner buffer runs.
     - Side effects: None.
     - Failure modes: An incomplete bare GI is ignored at EOF; committed attribute states retain
       their TagSoup start/self-close behavior.
     */
    private static func startTagToken(
        in source: [UnicodeScalar],
        nameStart: Int
    ) -> ScannerToken {
        var cursor = nameStart
        while cursor < source.count,
              source[cursor].value != 0x2F,
              source[cursor].value != 0x3E,
              !isScannerSpace(source[cursor]) {
            cursor += 1
        }
        let nameBufferCount = utf16Count(source[nameStart..<cursor])
        guard cursor < source.count else {
            return ScannerToken(
                payload: .ignored,
                end: source.count,
                nonPCDATABufferRuns: [nameBufferCount]
            )
        }

        let name = makeName(source[nameStart..<cursor])
        if source[cursor].value == 0x3E {
            return ScannerToken(
                payload: .tag(TagToken(name: name, isClosing: false, isSelfClosing: false)),
                end: cursor + 1,
                nonPCDATABufferRuns: [nameBufferCount]
            )
        }

        if source[cursor].value == 0x2F {
            let afterSlash = cursor + 1
            if afterSlash < source.count, source[afterSlash].value == 0x3E {
                return ScannerToken(
                    payload: .tag(TagToken(name: name, isClosing: false, isSelfClosing: true)),
                    end: afterSlash + 1,
                    nonPCDATABufferRuns: [nameBufferCount]
                )
            }
            let remainder = startTagEnd(
                in: source,
                from: cursor + 1,
                initialState: .emptyTag,
                initialBufferedUTF16Count: nameBufferCount
            )
            return ScannerToken(
                payload: .ignored,
                end: remainder.end,
                nonPCDATABufferRuns: remainder.nonPCDATABufferRuns
            )
        }

        let remainder = startTagEnd(
            in: source,
            from: cursor + 1,
            initialState: .tagWhitespace
        )
        return ScannerToken(
            payload: .tag(TagToken(
                name: name,
                isClosing: false,
                isSelfClosing: remainder.isSelfClosing
            )),
            end: remainder.end,
            nonPCDATABufferRuns: [nameBufferCount] + remainder.nonPCDATABufferRuns
        )
    }

    /**
     Consumes the scanner's end-tag state, which commits even at EOF.

     - Parameters:
       - source: Complete normalized scalar source.
       - nameStart: First scalar after `</`.
     - Returns: Repaired close token, preserving a zero-length GI for current-element close.
     - Side effects: None.
     - Failure modes: EOF commits the accumulated buffer rather than throwing.
     */
    private static func endTagToken(
        in source: [UnicodeScalar],
        nameStart: Int
    ) -> ScannerToken {
        var nameScalars: [UnicodeScalar] = []
        var cursor = nameStart
        while cursor < source.count, source[cursor].value != 0x3E {
            if !isScannerSpace(source[cursor]) {
                nameScalars.append(source[cursor])
            }
            cursor += 1
        }
        let end = cursor < source.count ? cursor + 1 : source.count
        return ScannerToken(
            payload: .tag(TagToken(
                name: nameScalars.isEmpty ? "" : makeName(nameScalars[...]),
                isClosing: true,
                isSelfClosing: false
            )),
            end: end,
            nonPCDATABufferRuns: [utf16Count(nameScalars[...])]
        )
    }

    /**
     Runs AOSP's start-tag attribute states through a commit terminator or EOF.

     Quotes open a quoted state only as the first nonspace character after `=`, while quotes inside
     an already-started unquoted value remain ordinary characters.

     - Parameters:
       - source: Complete normalized scalar source.
       - start: First scalar after the GI terminator already consumed by the caller.
       - initialState: TagSoup attribute state selected by whitespace or slash.
       - initialBufferedUTF16Count: GI units retained across a malformed slash transition; ordinary
         whitespace paths start from zero because `A_GI` already emitted and cleared them.
     - Returns: Exclusive cursor, self-closing commitment, and completed non-PCDATA buffer runs.
     - Side effects: None.
     - Failure modes: EOF commits the state-specific non-self-closing result without throwing.
     */
    private static func startTagEnd(
        in source: [UnicodeScalar],
        from start: Int,
        initialState: StartTagState,
        initialBufferedUTF16Count: Int = 0
    ) -> (end: Int, isSelfClosing: Bool, nonPCDATABufferRuns: [Int]) {
        var state = initialState
        var cursor = start
        var bufferedUTF16Count = initialBufferedUTF16Count
        var completedRuns: [Int] = []

        /**
         Commits the captured non-PCDATA buffer before the scanner changes states.

         - Returns: Nothing.
         - Side effects: Appends a positive `bufferedUTF16Count` to `completedRuns`, then resets the
           captured count to zero; an empty buffer only resets the count.
         - Failure modes: None; the captured integer state is mutated deterministically.
         */
        func completedBufferRun() {
            if bufferedUTF16Count > 0 { completedRuns.append(bufferedUTF16Count) }
            bufferedUTF16Count = 0
        }
        while cursor < source.count {
            let value = source[cursor].value
            let unitCount = value > 0xFFFF ? 2 : 1
            switch state {
            case .tagWhitespace:
                if value == 0x2F {
                    state = .emptyTag
                } else if value == 0x3E {
                    completedBufferRun()
                    return (cursor + 1, false, completedRuns)
                } else if !isScannerSpace(source[cursor]) {
                    state = .attributeName
                    bufferedUTF16Count += unitCount
                }
            case .attributeName:
                if value == 0x2F {
                    completedBufferRun()
                    state = .emptyTag
                } else if value == 0x3D {
                    completedBufferRun()
                    state = .attributeValue
                } else if value == 0x3E {
                    completedBufferRun()
                    return (cursor + 1, false, completedRuns)
                } else if isScannerSpace(source[cursor]) {
                    completedBufferRun()
                    state = .equals
                } else {
                    bufferedUTF16Count += unitCount
                }
            case .equals:
                if value == 0x3D {
                    state = .attributeValue
                } else if value == 0x3E {
                    completedBufferRun()
                    return (cursor + 1, false, completedRuns)
                } else if !isScannerSpace(source[cursor]) {
                    state = .attributeName
                    bufferedUTF16Count += unitCount
                }
            case .attributeValue:
                if value == 0x22 {
                    state = .doubleQuotedValue
                } else if value == 0x27 {
                    state = .singleQuotedValue
                } else if value == 0x3E {
                    completedBufferRun()
                    return (cursor + 1, false, completedRuns)
                } else if !isScannerSpace(source[cursor]) {
                    state = .unquotedValue
                    bufferedUTF16Count += unitCount
                }
            case .unquotedValue:
                if value == 0x3E {
                    completedBufferRun()
                    return (cursor + 1, false, completedRuns)
                } else if isScannerSpace(source[cursor]) {
                    completedBufferRun()
                    state = .tagWhitespace
                } else {
                    bufferedUTF16Count += unitCount
                }
            case .singleQuotedValue:
                if value == 0x27 {
                    completedBufferRun()
                    state = .tagWhitespace
                } else {
                    bufferedUTF16Count += unitCount
                }
            case .doubleQuotedValue:
                if value == 0x22 {
                    completedBufferRun()
                    state = .tagWhitespace
                } else {
                    bufferedUTF16Count += unitCount
                }
            case .emptyTag:
                if value == 0x3E {
                    completedBufferRun()
                    return (cursor + 1, true, completedRuns)
                } else if isScannerSpace(source[cursor]) {
                    state = .tagWhitespace
                } else {
                    state = .attributeName
                    bufferedUTF16Count += unitCount
                }
            }
            cursor += 1
        }
        completedBufferRun()
        return (source.count, false, completedRuns)
    }

    /**
     Ports TagSoup `Parser.makeName` for the known-tag recognition boundary.

     - Parameter source: Raw UTF-16-compatible GI scalars accumulated by the scanner.
     - Returns: Repaired nonempty QName with invalid units removed and legal leading characters
       synthesized exactly as TagSoup does.
     - Side effects: Loads pinned Android character predicates on first use.
     - Failure modes: Empty/all-invalid names become `_`; supplementary scalars are discarded
       because Java sees surrogate units that are not letters or digits.
     */
    private static func makeName(_ source: ArraySlice<UnicodeScalar>) -> String {
        var output = ""
        var seenColon = false
        var start = true
        for scalar in source {
            if (SwordJavaTextCompatibility.isLetterOrDigit(scalar)
                    && !SwordJavaTextCompatibility.isDigit(scalar)) || scalar.value == 0x5F {
                start = false
                output.unicodeScalars.append(scalar)
            } else if SwordJavaTextCompatibility.isDigit(scalar)
                        || scalar.value == 0x2D || scalar.value == 0x2E {
                if start { output.append("_") }
                start = false
                output.unicodeScalars.append(scalar)
            } else if scalar.value == 0x3A, !seenColon {
                seenColon = true
                if start { output.append("_") }
                start = true
                output.append(":")
            }
        }
        if output.isEmpty || output.utf16.last == 0x3A {
            output.append("_")
        }
        return output
    }

    /**
     Tests one normalized scalar against HTMLScanner's four structural whitespace characters.

     - Parameter scalar: Scanner-normalized Unicode scalar.
     - Returns: True only for ASCII space, TAB, LF, or CR.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func isScannerSpace(_ scalar: UnicodeScalar) -> Bool {
        scalar.value == 0x20 || scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
    }

    /**
     Returns the PITARGET and PI-data buffer runs completed by one processing instruction token.

     - Parameters:
       - source: Normalized scanner scalar source.
       - start: First scalar after `<?`.
       - end: Exclusive token end, including `>` when present.
     - Returns: Nonempty UTF-16 run lengths in callback order.
     - Side effects: None.
     - Failure modes: Incomplete input returns the target/data accumulated through EOF.
     */
    private static func processingInstructionBufferRuns(
        in source: [UnicodeScalar],
        from start: Int,
        to end: Int
    ) -> [Int] {
        let contentEnd = end > start && source[end - 1].value == 0x3E ? end - 1 : end
        guard start < contentEnd else { return [] }
        if let separator = source[start..<contentEnd].firstIndex(where: isScannerSpace) {
            return [
                utf16Count(source[start..<separator]),
                utf16Count(source[(separator + 1)..<contentEnd]),
            ].filter { $0 > 0 }
        }
        return [utf16Count(source[start..<contentEnd])]
    }

    /**
     Counts Java UTF-16 `char` units in one scalar slice without Swift grapheme clustering.

     - Parameter scalars: Scanner-normalized Unicode scalars.
     - Returns: One unit for BMP scalars and two for supplementary scalars.
     - Side effects: None.
     - Failure modes: None; an empty slice returns zero.
     */
    private static func utf16Count(_ scalars: ArraySlice<UnicodeScalar>) -> Int {
        scalars.reduce(into: 0) { count, scalar in
            count += scalar.value > 0xFFFF ? 2 : 1
        }
    }

    /**
     Finds one exact scalar sequence without extended-grapheme tokenization.

     - Parameters:
       - needle: Nonempty scalar values to locate.
       - source: Complete normalized scalar source.
       - start: First eligible source index.
     - Returns: First matching index, or nil for absent/out-of-range input.
     - Side effects: None.
     - Failure modes: Empty needles and insufficient remaining input return nil.
     */
    private static func firstIndex(
        of needle: [UInt32],
        in source: [UnicodeScalar],
        from start: Int
    ) -> Int? {
        guard !needle.isEmpty, start + needle.count <= source.count else { return nil }
        var cursor = start
        while cursor + needle.count <= source.count {
            if hasPrefix(needle, in: source, at: cursor) { return cursor }
            cursor += 1
        }
        return nil
    }

    /**
     Tests an exact scalar-value prefix at one source index.

     - Parameters:
       - prefix: Scalar values to compare.
       - source: Complete normalized scalar source.
       - start: Candidate prefix index.
     - Returns: True only when every value exists and matches.
     - Side effects: None.
     - Failure modes: Negative/out-of-bounds ranges return false.
     */
    private static func hasPrefix(
        _ prefix: [UInt32],
        in source: [UnicodeScalar],
        at start: Int
    ) -> Bool {
        guard start >= 0, start + prefix.count <= source.count else { return false }
        for (offset, value) in prefix.enumerated() where source[start + offset].value != value {
            return false
        }
        return true
    }

    /**
     Builds one scalar-preserving String without Swift grapheme iteration.

     - Parameter scalars: Scanner scalar slice in source order.
     - Returns: String containing the same scalar sequence.
     - Side effects: Allocates a bounded string.
     - Failure modes: None; an empty slice returns an empty string.
     */
    private static func string(from scalars: ArraySlice<UnicodeScalar>) -> String {
        var output = ""
        for scalar in scalars {
            output.unicodeScalars.append(scalar)
        }
        return output
    }
}
