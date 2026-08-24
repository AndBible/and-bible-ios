import Foundation

/**
 Pinned Android 37 UTF-16/string predicates shared by JSword-compatible SwordKit projections.

 BibleCore owns a separate Lucene-lowercase table for analyzer behavior, but SwordKit cannot depend
 upward on that target. This target-bundled table instead pins Android's ICU 78.3-backed Java
 `Character` behavior for module identity, JSword repair, and Android TagSoup scanning.
 */
enum SwordJavaTextCompatibility {
    /// Number of Java `char` rows in the fixed-width Android compatibility table.
    static let expectedBundledCharacterRowCount = 65_536

    /**
     Stores one UTF-16 unit's Android 37 `Character` transforms and predicates.

     Rows are immutable values decoded from the validated generated resource. They perform no work
     after construction and have no failure mode; the enclosing loader rejects the complete table
     if any integrity sentinel differs.
     */
    private struct CharacterRow {
        /// `Character.toUpperCase(source)` narrowed to the Java `char` overload.
        let uppercase: UInt16
        /// `Character.toLowerCase(Character.toUpperCase(source))` as a Java `char`.
        let lowercaseOfUppercase: UInt16
        /// `Character.toLowerCase(source)` as one Java `char`.
        let lowercase: UInt16
        /**
         Packed `isLetterOrDigit`, `isDigit`, `isWhitespace`, `Cased`, `Case_Ignorable`, and
         `isUpperCase` predicates.
         */
        let flags: UInt8
        /// `Character.digit(source, 36)`, encoded as `0xFF` for `-1`.
        let digit: UInt8
    }

    /// Validated Android 37/ICU 78.3 table cached on first compatibility operation.
    private static let characterRows: [CharacterRow] = {
        guard let url = Bundle.module.url(
                  forResource: "java-character-android37-icu78",
                  withExtension: "bin",
                  subdirectory: "compatibility"
              ),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        let bytes = [UInt8](data)
        let headerSize = 16
        let rowSize = 8
        guard bytes.count == headerSize + expectedBundledCharacterRowCount * rowSize,
              String(decoding: bytes[0..<8], as: UTF8.self) == "ANDJCHAR",
              bytes[8] == 78,
              bytes[9] == 3,
              bytes[10] == 17,
              bytes[11] == 0,
              readUInt32LE(bytes, at: 12) == UInt32(expectedBundledCharacterRowCount) else {
            return []
        }
        var result: [CharacterRow] = []
        result.reserveCapacity(expectedBundledCharacterRowCount)
        for index in 0..<expectedBundledCharacterRowCount {
            let offset = headerSize + index * rowSize
            result.append(CharacterRow(
                uppercase: readUInt16LE(bytes, at: offset),
                lowercaseOfUppercase: readUInt16LE(bytes, at: offset + 2),
                lowercase: readUInt16LE(bytes, at: offset + 4),
                flags: bytes[offset + 6],
                digit: bytes[offset + 7]
            ))
        }
        guard result[0x0130].lowercaseOfUppercase == 0x0069,
              result[0x0131].uppercase == 0x0049,
              result[0x017F].uppercase == 0x0053,
              result[0xA7C0].lowercaseOfUppercase == 0xA7C1,
              result[0xA7C1].uppercase == 0xA7C0,
              result[0x00A0].flags & 0x04 == 0,
              result[0x2003].flags & 0x04 != 0,
              result[0x03A3].flags & 0x08 != 0,
              result[0x0301].flags & 0x10 != 0,
              result[0x0041].flags & 0x20 != 0,
              result[0x0061].flags & 0x20 == 0,
              result[0x0665].digit == 5 else {
            return []
        }
        return result
    }()

    /// Test-visible integrity signal for the generated Android compatibility resource.
    static var bundledCharacterRowCount: Int {
        characterRows.count
    }

    /**
     Reads one little-endian UInt16 from the already validated binary resource.

     - Parameters:
       - bytes: Complete compatibility resource bytes.
       - offset: Valid first-byte index guaranteed by the resource-size check.
     - Returns: Decoded unsigned value.
     - Side effects: None.
     - Failure modes: None under the caller's validated bounds invariant.
     */
    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    /**
     Reads one little-endian UInt32 from the already validated binary resource.

     - Parameters:
       - bytes: Complete compatibility resource bytes.
       - offset: Valid first-byte index guaranteed by the resource-size check.
     - Returns: Decoded unsigned value.
     - Side effects: None.
     - Failure modes: None under the caller's validated bounds invariant.
     */
    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(readUInt16LE(bytes, at: offset))
            | (UInt32(readUInt16LE(bytes, at: offset + 2)) << 16)
    }
    /**
     Returns Java `Character.isWhitespace(char)` behavior for one UTF-16 code unit.

     - Parameter unit: Last or first Java `char` at a parsed text-node boundary.
     - Returns: `true` for the Java whitespace categories/control set; notably `false` for NBSP,
       figure space, narrow NBSP, and surrogate code units.
     - Side effects: None.
     - Failure modes: Unpaired/supplementary surrogate units return `false`, as Java does for each
       individual high or low surrogate passed to this `char` overload.
     */
    static func isWhitespace(_ unit: UInt16) -> Bool {
        guard characterRows.count == expectedBundledCharacterRowCount else { return false }
        return characterRows[Int(unit)].flags & 0x04 != 0
    }

    /**
     Returns Android 37 `Character.isUpperCase(char)` for one UTF-16 code unit.

     - Parameter unit: Exact Java `char` immediately after a possible GBF opening angle bracket.
     - Returns: Pinned ICU uppercase-property membership, including non-ASCII BMP uppercase chars;
       surrogate units and uncased characters return false.
     - Side effects: Loads the generated compatibility table on first use.
     - Failure modes: Returns false if the resource failed integrity validation.
     */
    static func isUpperCase(_ unit: UInt16) -> Bool {
        guard characterRows.count == expectedBundledCharacterRowCount else { return false }
        return characterRows[Int(unit)].flags & 0x20 != 0
    }

    /**
     Returns Java `Character.isLetterOrDigit(char)` for one Unicode scalar scanner position.

     Supplementary scalars return false because AOSP's scanner observes their leading surrogate as
     one Java `char`. Java letters include Lu/Ll/Lt/Lm/Lo; Java digits include Nd, but not Nl/No.

     - Parameter scalar: One scanner scalar before `Parser.makeName` or entity-body classification.
     - Returns: Pinned Android predicate result for BMP input; false for supplementary input.
     - Side effects: Loads the generated table on first use.
     - Failure modes: Returns false if the resource failed validation.
     */
    static func isLetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        guard scalar.value <= 0xFFFF else { return false }
        return isLetterOrDigit(UInt16(scalar.value))
    }

    /**
     Returns Java `Character.isLetterOrDigit(char)` for one UTF-16 code unit.

     - Parameter unit: Exact Java `char` unit.
     - Returns: Pinned Android 37 predicate result.
     - Side effects: Loads the generated table on first use.
     - Failure modes: Returns false if resource integrity validation failed.
     */
    static func isLetterOrDigit(_ unit: UInt16) -> Bool {
        guard characterRows.count == expectedBundledCharacterRowCount else { return false }
        return characterRows[Int(unit)].flags & 0x01 != 0
    }

    /**
     Returns Java `Character.isDigit(char)` for one BMP scanner position.

     - Parameter scalar: Numeric-reference scalar; supplementary values terminate scanning.
     - Returns: True only for Android 37 decimal-digit Java chars.
     - Side effects: Loads the generated table on first use.
     - Failure modes: Supplementary input or resource failure returns false.
     */
    static func isDigit(_ scalar: UnicodeScalar) -> Bool {
        guard scalar.value <= 0xFFFF,
              characterRows.count == expectedBundledCharacterRowCount else {
            return false
        }
        return characterRows[Int(scalar.value)].flags & 0x02 != 0
    }

    /**
     Returns AOSP TagSoup's Java-digit-or-ASCII-A-F hexadecimal scanner predicate.

     - Parameter scalar: Candidate numeric-reference body scalar.
     - Returns: True for Java decimal digits or ASCII A-F/a-f only.
     - Side effects: May load the generated character table.
     - Failure modes: Full-width/non-ASCII hex letters and supplementary digits return false.
     */
    static func isHexDigit(_ scalar: UnicodeScalar) -> Bool {
        isDigit(scalar)
            || (scalar.value >= 0x41 && scalar.value <= 0x46)
            || (scalar.value >= 0x61 && scalar.value <= 0x66)
    }

    /**
     Returns Java `Character.digit(char, radix:)` for the entity radices TagSoup accepts.

     - Parameters:
       - scalar: One BMP scalar previously accepted by the numeric scanner.
       - radix: Decimal or hexadecimal numeric-reference radix.
     - Returns: A digit below `radix`, or nil for a non-digit in that radix.
     */
    static func digitValue(_ scalar: UnicodeScalar, radix: Int) -> Int? {
        let value: Int
        if scalar.value >= 0x30, scalar.value <= 0x39 {
            value = Int(scalar.value - 0x30)
        } else if radix == 16, scalar.value >= 0x41, scalar.value <= 0x46 {
            value = Int(scalar.value - 0x41) + 10
        } else if radix == 16, scalar.value >= 0x61, scalar.value <= 0x66 {
            value = Int(scalar.value - 0x61) + 10
        } else if isDigit(scalar) {
            let digit = characterRows[Int(scalar.value)].digit
            guard digit != 0xFF else { return nil }
            value = Int(digit)
        } else {
            return nil
        }
        return value < radix ? value : nil
    }

    /**
     Returns whether one scalar is XML formatting `S` rather than broad Unicode whitespace.

     - Parameter scalar: Top-level parsed XML text scalar.
     - Returns: True only for TAB, LF, CR, or ASCII space.
     - Side effects: None.
     - Failure modes: None; NBSP and other meaningful Java-trim-preserved spaces return false.
     */
    static func isXMLFormattingSpace(_ scalar: UnicodeScalar) -> Bool {
        scalar.value == 0x0009
            || scalar.value == 0x000A
            || scalar.value == 0x000D
            || scalar.value == 0x0020
    }

    /**
     Returns Java `String.equalsIgnoreCase` behavior for valid UTF-16 strings.

     - Parameters:
       - lhs: Repaired TagSoup local name.
       - rhs: Pinned ASCII HTML handler name.
     - Returns: True when equal under Java's per-`char`, non-expanding upper/lower comparison.
     - Side effects: None.
     - Failure modes: Supplementary pairs compare unit-by-unit, matching Java; invalid Swift source
       cannot supply unpaired surrogates.
     */
    static func equalsIgnoreCase(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        guard left.count == right.count else { return false }
        for (leftUnit, rightUnit) in zip(left, right) {
            if leftUnit != rightUnit,
               equalsIgnoreCaseFold(leftUnit) != equalsIgnoreCaseFold(rightUnit) {
                return false
            }
        }
        return true
    }

    /**
     Compares TagSoup CDATA end-tag buffers with direct Android `Character.toLowerCase(char)`.

     - Parameters:
       - lhs: Scanner end-tag GI buffer.
       - rhs: Current canonical schema QName.
     - Returns: True only when lengths match and every directly-lowercased UTF-16 unit matches.
     - Side effects: Loads the bundled Android character table on first use.
     - Failure modes: Returns exact-unit comparison behavior if the resource is unavailable.
     */
    static func cdataEndTagEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        guard left.count == right.count else { return false }
        for (leftUnit, rightUnit) in zip(left, right) {
            let leftLower = characterRows.count == expectedBundledCharacterRowCount
                ? characterRows[Int(leftUnit)].lowercase : leftUnit
            let rightLower = characterRows.count == expectedBundledCharacterRowCount
                ? characterRows[Int(rightUnit)].lowercase : rightUnit
            if leftLower != rightLower { return false }
        }
        return true
    }

    /**
     Returns Android's lowercase-of-uppercase identity representative for one Java `char`.

     - Parameter unit: Exact UTF-16 unit from a Java string identity.
     - Returns: Pinned ICU-backed non-expanding fold representative.
     - Side effects: Loads the generated table on first use.
     - Failure modes: Returns the input unit if resource validation failed; public identity creation
       prevents that fallback from authorizing module access.
     */
    static func equalsIgnoreCaseFold(_ unit: UInt16) -> UInt16 {
        guard characterRows.count == expectedBundledCharacterRowCount else { return unit }
        return characterRows[Int(unit)].lowercaseOfUppercase
    }

    /**
     Lowercases one repaired HTML name using Android 37 `Locale.ROOT` behavior relevant to schema
     lookup.

     - Parameter value: TagSoup's repaired UTF-16 QName.
     - Returns: Android's root-locale full lowercase, including unconditional U+0130 expansion and
       context-sensitive Greek final sigma.
     - Side effects: Loads the bundled compatibility table on first use.
     - Failure modes: Returns the input unchanged when the generated resource fails validation.
     */
    static func lowercasedRoot(_ value: String) -> String {
        guard characterRows.count == expectedBundledCharacterRowCount else { return value }
        let source = Array(value.utf16)
        let requiresICUFallback = source.contains(0x0130)
            || source.contains(where: { (0xD800...0xDBFF).contains($0) })
        var units: [UInt16] = []
        units.reserveCapacity(source.count)
        for (index, unit) in source.enumerated() {
            if unit == 0x0130 {
                units.append(0x0069)
                units.append(0x0307)
            } else if unit == 0x03A3,
                      isFinalSigma(at: index, in: source, usingICUFallback: requiresICUFallback) {
                units.append(0x03C2)
            } else {
                units.append(characterRows[Int(unit)].lowercase)
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /**
     Mirrors Android 37's split final-Sigma decision for root-locale lowercase.

     `CaseMapper` normally checks only adjacent UTF-16 chars. A source containing U+0130 or a high
     surrogate delegates the whole string to ICU, whose Final_Sigma context skips Case_Ignorable
     units. Keeping the branches explicit avoids host Foundation/OpenJDK word-boundary drift.

     - Parameters:
       - index: Index of U+03A3 in `source`.
       - source: Complete repaired QName UTF-16 units.
       - usingICUFallback: Whether Android delegates whole-string lowercase to ICU.
     - Returns: True when this sigma receives final-sigma lowercase.
     - Side effects: None.
     - Failure modes: None; callers validate the bundled table before reaching this helper.
     */
    private static func isFinalSigma(
        at index: Int,
        in source: [UInt16],
        usingICUFallback: Bool
    ) -> Bool {
        if !usingICUFallback {
            let hasCasedBefore = index > 0
                && characterRows[Int(source[index - 1])].flags & 0x08 != 0
            let hasCasedAfter = index + 1 < source.count
                && characterRows[Int(source[index + 1])].flags & 0x08 != 0
            return hasCasedBefore && !hasCasedAfter
        }
        return hasICUCasedUnit(before: index, in: source)
            && !hasICUCasedUnit(after: index, in: source)
    }

    /**
     Finds ICU's first non-case-ignorable unit before an index and tests whether it is cased.

     - Parameters:
       - index: Exclusive backward-search boundary.
       - source: Complete UTF-16 source.
     - Returns: Cased flag of the first relevant unit, or false when none exists.
     - Side effects: None.
     - Failure modes: None under validated-table and in-range-index invariants.
     */
    private static func hasICUCasedUnit(before index: Int, in source: [UInt16]) -> Bool {
        guard index > 0 else { return false }
        var cursor = index
        while cursor > 0 {
            cursor -= 1
            let flags = characterRows[Int(source[cursor])].flags
            if flags & 0x10 != 0 { continue }
            return flags & 0x08 != 0
        }
        return false
    }

    /**
     Finds ICU's first non-case-ignorable unit after an index and tests whether it is cased.

     - Parameters:
       - index: Exclusive forward-search boundary.
       - source: Complete UTF-16 source.
     - Returns: Cased flag of the first relevant unit, or false when none exists.
     - Side effects: None.
     - Failure modes: None under validated-table and in-range-index invariants.
     */
    private static func hasICUCasedUnit(after index: Int, in source: [UInt16]) -> Bool {
        var cursor = index + 1
        while cursor < source.count {
            let flags = characterRows[Int(source[cursor])].flags
            if flags & 0x10 == 0 { return flags & 0x08 != 0 }
            cursor += 1
        }
        return false
    }

    /**
     Trims only leading/trailing Unicode scalars at or below U+0020 like Java `String.trim()`.

     - Parameter value: Source or canonical text at a JSword compatibility boundary.
     - Returns: A copy without Java-trimmable edge controls; non-breaking spaces remain content.
     - Side effects: None.
     - Failure modes: None; an all-trimmable value becomes empty.
     */
    static func trim(_ value: String) -> String {
        let scalars = value.unicodeScalars
        var lower = scalars.startIndex
        var upper = scalars.endIndex
        while lower < upper, scalars[lower].value <= 0x0020 {
            lower = scalars.index(after: lower)
        }
        while upper > lower {
            let previous = scalars.index(before: upper)
            guard scalars[previous].value <= 0x0020 else { break }
            upper = previous
        }
        return String(scalars[lower..<upper])
    }
}
