// EpubCSSProcessor.swift -- EPUB stylesheet sanitization and resource URL resolution

import Foundation

/**
 Sanitizes EPUB CSS for the shared reader and rewrites package-relative resource URLs.

 Android removes EPUB color/background/body/line-height overrides so workspace display settings
 remain authoritative. This processor applies the same policy with a small stateful CSS scanner
 that respects strings, comments, parentheses, and nested at-rules; it does not use XML or CSS
 regular-expression replacement.
 */
enum EpubCSSProcessor {
    /// Declaration names removed to preserve reader-controlled colors and line spacing.
    private static let blockedProperties: Set<String> = [
        "background",
        "background-color",
        "background-image",
        "color",
        "line-height"
    ]

    /**
     Processes one linked EPUB stylesheet.

     - Parameters:
       - css: Decoded stylesheet source.
       - styleSheetPath: Canonical package path used as the base for `url(...)` references.
       - packageRootURL: Extracted EPUB package root.
       - resourceIdentity: Android initials and immutable generation embedded in resource URLs.
     - Returns: Sanitized CSS preserving rule order and nonblocked declarations.
     - Side effects: None.
     - Failure modes: Malformed trailing CSS is retained as inert text where possible; invalid,
       external, or escaping resource targets are replaced with empty URLs.
     */
    static func process(
        _ css: String,
        styleSheetPath: String,
        packageRootURL: URL,
        resourceIdentity: EpubResourceIdentity
    ) -> String {
        let resolver = EpubPackagePathResolver(packageRootURL: packageRootURL)
        let rewrittenSource = rewriteQuotedImports(
            rewriteURLImports(
                css,
                styleSheetPath: styleSheetPath,
                resolver: resolver,
                resourceIdentity: resourceIdentity
            ),
            styleSheetPath: styleSheetPath,
            resolver: resolver,
            resourceIdentity: resourceIdentity
        )
        return processRules(
            rewrittenSource,
            styleSheetPath: styleSheetPath,
            resolver: resolver,
            resourceIdentity: resourceIdentity
        )
    }

    /**
     Sanitizes one XHTML `style` attribute with the linked-stylesheet declaration policy.

     - Parameters:
       - css: Declaration-list value from an imported element.
       - sourcePath: Canonical XHTML path used as the base for local resources.
       - packageRootURL: Extracted EPUB package root.
       - resourceIdentity: Android initials and immutable generation embedded in resource URLs.
     - Returns: Filtered declaration list with local URLs rewritten to the contained resource route.
     - Side effects: None.
     - Failure modes: Malformed declarations are retained as inert text, while external resource
       URLs are replaced with empty URLs so imported markup cannot trigger network requests.
     */
    static func processInlineDeclarations(
        _ css: String,
        sourcePath: String,
        packageRootURL: URL,
        resourceIdentity: EpubResourceIdentity
    ) -> String {
        processDeclarations(
            css,
            styleSheetPath: sourcePath,
            resolver: EpubPackagePathResolver(packageRootURL: packageRootURL),
            resourceIdentity: resourceIdentity
        )
    }

    /// Rewrites CSS's quoted `@import "path"` form without interpreting quoted declarations.
    private static func rewriteQuotedImports(
        _ css: String,
        styleSheetPath: String,
        resolver: EpubPackagePathResolver,
        resourceIdentity: EpubResourceIdentity
    ) -> String {
        var output = ""
        var index = css.startIndex
        while index < css.endIndex {
            let next = css.index(after: index)
            if css[index] == "/", next < css.endIndex, css[next] == "*" {
                let end = endOfComment(in: css, from: index)
                output += String(css[index..<end])
                index = end
                continue
            }
            if css[index] == "\"" || css[index] == "'" {
                guard let end = endOfQuotedString(in: css, from: index) else {
                    output += String(css[index...])
                    break
                }
                output += String(css[index..<end])
                index = end
                continue
            }
            guard matchesToken("@import", in: css, at: index) else {
                output.append(css[index])
                index = next
                continue
            }

            let importEnd = css.index(index, offsetBy: "@import".count)
            output += String(css[index..<importEnd])
            var valueStart = importEnd
            while valueStart < css.endIndex, css[valueStart].isWhitespace {
                output.append(css[valueStart])
                valueStart = css.index(after: valueStart)
            }
            guard valueStart < css.endIndex,
                  css[valueStart] == "\"" || css[valueStart] == "'" else {
                index = valueStart
                continue
            }
            let pathStart = css.index(after: valueStart)
            guard let stringEnd = endOfQuotedString(in: css, from: valueStart) else {
                output += String(css[valueStart...])
                break
            }
            let pathEnd = css.index(before: stringEnd)
            let rawPath = String(css[pathStart..<pathEnd])
            if let resolved = try? resolver.resolve(rawPath, relativeTo: styleSheetPath) {
                let resourceURL = EpubResourceLocator.resourceURLString(
                    identity: resourceIdentity,
                    canonicalPath: resolved.path,
                    fragment: resolved.fragment
                )
                output += "url(\"\(resourceURL)\")"
            } else {
                output += "url(\"\")"
            }
            index = stringEnd
        }
        return output
    }

    /**
     Rewrites CSS's `@import url(...)` form without touching declaration-level URL functions.

     Running this before quoted-import rewriting and rule processing ensures every source token is
     resolved exactly once. Local imports use the contained EPUB resource route; external,
     malformed, and escaping imports become empty URLs and cannot trigger browser network access.

     - Parameters:
       - css: Original stylesheet source.
       - styleSheetPath: Canonical package path used as the import base.
       - resolver: Resolver constrained to the active EPUB package.
       - resourceIdentity: Android initials and immutable generation embedded in the route.
     - Returns: Source with only syntactic `@import url(...)` targets rewritten.
     - Side effects: None.
     - Failure modes: Unterminated comments, strings, or URL functions are retained as trailing text.
     */
    private static func rewriteURLImports(
        _ css: String,
        styleSheetPath: String,
        resolver: EpubPackagePathResolver,
        resourceIdentity: EpubResourceIdentity
    ) -> String {
        var output = ""
        var index = css.startIndex
        while index < css.endIndex {
            let next = css.index(after: index)
            if css[index] == "/", next < css.endIndex, css[next] == "*" {
                let end = endOfComment(in: css, from: index)
                output += String(css[index..<end])
                index = end
                continue
            }
            if css[index] == "\"" || css[index] == "'" {
                guard let end = endOfQuotedString(in: css, from: index) else {
                    output += String(css[index...])
                    break
                }
                output += String(css[index..<end])
                index = end
                continue
            }
            guard matchesToken("@import", in: css, at: index) else {
                output.append(css[index])
                index = next
                continue
            }

            let importEnd = css.index(index, offsetBy: "@import".count)
            output += String(css[index..<importEnd])
            var valueStart = importEnd
            while valueStart < css.endIndex, css[valueStart].isWhitespace {
                output.append(css[valueStart])
                valueStart = css.index(after: valueStart)
            }
            guard matchesToken("url(", in: css, at: valueStart) else {
                index = valueStart
                continue
            }

            let targetStart = css.index(valueStart, offsetBy: "url(".count)
            guard let close = findClosingParenthesis(in: css, from: targetStart) else {
                output += String(css[valueStart...])
                break
            }
            let raw = css[targetStart..<close].trimmingCharacters(in: .whitespacesAndNewlines)
            let target: String
            if raw.count >= 2,
               let first = raw.first,
               let last = raw.last,
               (first == "\"" || first == "'"), first == last {
                target = String(raw.dropFirst().dropLast())
            } else {
                target = raw
            }
            if let resolved = try? resolver.resolve(target, relativeTo: styleSheetPath) {
                let resourceURL = EpubResourceLocator.resourceURLString(
                    identity: resourceIdentity,
                    canonicalPath: resolved.path,
                    fragment: resolved.fragment
                )
                output += "url(\"\(resourceURL)\")"
            } else {
                output += "url(\"\")"
            }
            index = css.index(after: close)
        }
        return output
    }

    /// Parses top-level rules and recursively processes grouping at-rules.
    private static func processRules(
        _ css: String,
        styleSheetPath: String,
        resolver: EpubPackagePathResolver,
        resourceIdentity: EpubResourceIdentity
    ) -> String {
        var output = ""
        var cursor = css.startIndex
        while cursor < css.endIndex {
            guard let openBrace = findUnquoted("{", in: css, from: cursor) else {
                output += String(css[cursor...])
                break
            }
            guard let closeBrace = matchingBrace(in: css, openBrace: openBrace) else {
                output += String(css[cursor...])
                break
            }
            let prelude = String(css[cursor..<openBrace])
            let bodyStart = css.index(after: openBrace)
            let body = String(css[bodyStart..<closeBrace])
            let normalizedPrelude = prelude.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if isBodyOnlySelector(normalizedPrelude) {
                // Android drops the EPUB body rule so the reader owns page layout and colors.
            } else if isGroupingAtRule(normalizedPrelude) {
                output += prelude + "{" + processRules(
                    body,
                    styleSheetPath: styleSheetPath,
                    resolver: resolver,
                    resourceIdentity: resourceIdentity
                ) + "}"
            } else {
                output += prelude + "{" + processDeclarations(
                    body,
                    styleSheetPath: styleSheetPath,
                    resolver: resolver,
                    resourceIdentity: resourceIdentity
                ) + "}"
            }
            cursor = css.index(after: closeBrace)
        }
        return output
    }

    /// Returns whether a selector list contains only `body` selectors and pseudo-classes.
    private static func isBodyOnlySelector(_ prelude: String) -> Bool {
        guard !prelude.hasPrefix("@") else { return false }
        let selectors = prelude.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !selectors.isEmpty else { return false }
        return selectors.allSatisfy { selector in
            selector == "body" || selector.hasPrefix("body:") || selector.hasPrefix("html body")
        }
    }

    /// Returns whether an at-rule body contains nested rules instead of declarations.
    private static func isGroupingAtRule(_ prelude: String) -> Bool {
        ["@media", "@supports", "@layer", "@container", "@document", "@keyframes", "@-webkit-keyframes"]
            .contains { prelude.hasPrefix($0) }
    }

    /// Splits a declaration block at top-level semicolons and filters blocked properties.
    private static func processDeclarations(
        _ body: String,
        styleSheetPath: String,
        resolver: EpubPackagePathResolver,
        resourceIdentity: EpubResourceIdentity
    ) -> String {
        topLevelSegments(in: body, separator: ";").compactMap { segment -> String? in
            guard let colon = findUnquoted(":", in: segment, from: segment.startIndex) else {
                return segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : segment
            }
            let property = segment[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !blockedProperties.contains(property) else { return nil }
            let valueStart = segment.index(after: colon)
            let value = String(segment[valueStart...])
            let rewritten = rewriteURLs(
                in: value,
                styleSheetPath: styleSheetPath,
                resolver: resolver,
                resourceIdentity: resourceIdentity
            )
            return String(segment[..<valueStart]) + rewritten
        }.joined(separator: ";")
    }

    /// Rewrites local `url(...)` values while respecting quoted data and external schemes.
    private static func rewriteURLs(
        in value: String,
        styleSheetPath: String,
        resolver: EpubPackagePathResolver,
        resourceIdentity: EpubResourceIdentity
    ) -> String {
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(after: index)
            if value[index] == "/", next < value.endIndex, value[next] == "*" {
                let end = endOfComment(in: value, from: index)
                output += String(value[index..<end])
                index = end
                continue
            }
            if value[index] == "\"" || value[index] == "'" {
                guard let end = endOfQuotedString(in: value, from: index) else {
                    output += String(value[index...])
                    break
                }
                output += String(value[index..<end])
                index = end
                continue
            }
            let previousIsIdentifier = index > value.startIndex
                && isIdentifierCharacter(value[value.index(before: index)])
            guard !previousIsIdentifier, matchesToken("url(", in: value, at: index) else {
                output.append(value[index])
                index = next
                continue
            }

            let valueStart = value.index(index, offsetBy: "url(".count)
            guard let close = findClosingParenthesis(in: value, from: valueStart) else {
                output += String(value[index...])
                break
            }
            let raw = value[valueStart..<close].trimmingCharacters(in: .whitespacesAndNewlines)
            let unquoted: String
            if raw.count >= 2,
               let first = raw.first,
               let last = raw.last,
               (first == "\"" || first == "'"), first == last {
                unquoted = String(raw.dropFirst().dropLast())
            } else {
                unquoted = raw
            }
            if let resolved = try? resolver.resolve(unquoted, relativeTo: styleSheetPath) {
                let rewritten = EpubResourceLocator.resourceURLString(
                    identity: resourceIdentity,
                    canonicalPath: resolved.path,
                    fragment: resolved.fragment
                )
                output += "url(\"\(rewritten)\")"
            } else if unquoted.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().hasPrefix("data:") {
                output += String(value[index...close])
            } else {
                output += "url(\"\")"
            }
            index = value.index(after: close)
        }
        return output
    }

    /// Splits source at separators that are outside strings, comments, and parentheses.
    private static func topLevelSegments(in source: String, separator: Character) -> [String] {
        var result: [String] = []
        var start = source.startIndex
        var index = source.startIndex
        var quote: Character?
        var parenthesisDepth = 0
        var inComment = false

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if inComment {
                if character == "*", next < source.endIndex, source[next] == "/" {
                    inComment = false
                    index = source.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            if quote == nil, character == "/", next < source.endIndex, source[next] == "*" {
                inComment = true
                index = source.index(after: next)
                continue
            }
            if (character == "\"" || character == "'"), !isEscaped(index, in: source) {
                if quote == character { quote = nil } else if quote == nil { quote = character }
            } else if quote == nil {
                if character == "(" { parenthesisDepth += 1 }
                if character == ")" { parenthesisDepth = max(0, parenthesisDepth - 1) }
                if character == separator, parenthesisDepth == 0 {
                    result.append(String(source[start..<index]))
                    start = next
                }
            }
            index = next
        }
        result.append(String(source[start...]))
        return result
    }

    /// Finds one token outside quoted strings and block comments.
    private static func findUnquoted(
        _ token: Character,
        in source: String,
        from start: String.Index
    ) -> String.Index? {
        var index = start
        var quote: Character?
        var inComment = false
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if inComment {
                if character == "*", next < source.endIndex, source[next] == "/" {
                    inComment = false
                    index = source.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            if quote == nil, character == "/", next < source.endIndex, source[next] == "*" {
                inComment = true
                index = source.index(after: next)
                continue
            }
            if (character == "\"" || character == "'"), !isEscaped(index, in: source) {
                if quote == character { quote = nil } else if quote == nil { quote = character }
            } else if quote == nil, character == token {
                return index
            }
            index = next
        }
        return nil
    }

    /// Finds the balanced closing brace for one top-level CSS block.
    private static func matchingBrace(in source: String, openBrace: String.Index) -> String.Index? {
        var index = source.index(after: openBrace)
        var depth = 1
        var quote: Character?
        var inComment = false
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if inComment {
                if character == "*", next < source.endIndex, source[next] == "/" {
                    inComment = false
                    index = source.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            if quote == nil, character == "/", next < source.endIndex, source[next] == "*" {
                inComment = true
                index = source.index(after: next)
                continue
            }
            if (character == "\"" || character == "'"), !isEscaped(index, in: source) {
                if quote == character { quote = nil } else if quote == nil { quote = character }
            } else if quote == nil {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index = next
        }
        return nil
    }

    /// Finds the closing parenthesis for a CSS URL token.
    private static func findClosingParenthesis(in source: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if character == "/", next < source.endIndex, source[next] == "*" {
                index = endOfComment(in: source, from: index)
                continue
            }
            if character == "\"" || character == "'" {
                guard let end = endOfQuotedString(in: source, from: index) else { return nil }
                index = end
                continue
            }
            if character == ")", !isEscaped(index, in: source) {
                return index
            }
            index = next
        }
        return nil
    }

    /// Tests a case-insensitive ASCII CSS token at one source position.
    private static func matchesToken(_ token: String, in source: String, at index: String.Index) -> Bool {
        guard let end = source.index(index, offsetBy: token.count, limitedBy: source.endIndex) else {
            return false
        }
        return String(source[index..<end]).caseInsensitiveCompare(token) == .orderedSame
    }

    /// Returns whether a character can continue a CSS identifier before a function token.
    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    /// Returns the first index after a CSS block comment, or `endIndex` for an unterminated comment.
    private static func endOfComment(in source: String, from start: String.Index) -> String.Index {
        let contentStart = source.index(start, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
        guard let close = source.range(of: "*/", range: contentStart..<source.endIndex) else {
            return source.endIndex
        }
        return close.upperBound
    }

    /// Returns the first index after a quoted CSS string while honoring escaped quote characters.
    private static func endOfQuotedString(in source: String, from start: String.Index) -> String.Index? {
        let quote = source[start]
        var index = source.index(after: start)
        while index < source.endIndex {
            if source[index] == quote, !isEscaped(index, in: source) {
                return source.index(after: index)
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Returns whether the scalar at `index` is preceded by an odd run of backslashes.
    private static func isEscaped(_ index: String.Index, in source: String) -> Bool {
        guard index > source.startIndex else { return false }
        var cursor = source.index(before: index)
        var count = 0
        while source[cursor] == "\\" {
            count += 1
            guard cursor > source.startIndex else { break }
            cursor = source.index(before: cursor)
        }
        return count.isMultiple(of: 2) == false
    }
}
