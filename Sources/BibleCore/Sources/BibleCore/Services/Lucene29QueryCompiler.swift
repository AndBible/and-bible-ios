// Lucene29QueryCompiler.swift - Lucene 3.6.2 query parsing and FTS5 set translation

import Foundation
import SwordKit

/**
 Parses the Android/JSword Lucene query subset and emits an equivalent FTS5 match expression.

 Parsing follows Lucene 3.6.2 `QueryParser` with its default OR operator. Translation deliberately
 models Lucene clause occurrence (`MUST`, `SHOULD`, `MUST_NOT`) instead of mapping operator spelling
 directly to FTS5. Unsupported Lucene features fail before SQLite sees the query.
 */
enum Lucene29QueryCompiler {
    /** Lucene Boolean clause occurrence. */
    fileprivate enum Occur {
        case must
        case should
        case mustNot
    }

    /** Parsed Lucene query nodes needed by Android Search's supported subset. */
    fileprivate indirect enum QueryNode {
        case term([String])
        case phrase([String])
        case prefix(String)
        case boolean([Clause])
    }

    /** One Boolean child and the occurrence assigned by Lucene's `addClause`. */
    fileprivate struct Clause {
        var node: QueryNode
        var occur: Occur
    }

    /** Token categories from the relevant portion of Lucene's JavaCC grammar. */
    fileprivate enum Token: Equatable {
        case and
        case or
        case not
        case plus
        case minus
        case leftParen
        case rightParen
        case colon
        case term(String)
        case phrase(String)
        case prefix(String)
        case unsupported(String)
    }

    /** Optional conjunction consumed immediately before a Lucene clause. */
    private enum Conjunction {
        case none
        case and
        case or
    }

    /** Optional unary modifier consumed immediately before a Lucene clause. */
    private enum Modifier {
        case none
        case required
        case prohibited
    }

    /** Result of lowering one query node to FTS5's Boolean expression model. */
    private enum LoweredExpression {
        case expression(String)
        case matchNone
    }

    /**
     Cleans, decorates, parses, and lowers one raw Search query.

     - Parameters:
       - query: User input before Android's `cleanSearchString` pass.
       - wordMode: Search mode whose JSword decorator runs before parsing.
       - analyzer: Module-specific analyzer used for ordinary terms and phrases.
     - Returns: An FTS5 expression preserving Lucene's result set for supported syntax.
     - Side effects: May lazily load analyzer tables and dictionaries.
     - Throws: Explicit `SearchIndexError` values for malformed or unsupported syntax.
     */
    static func compile(
        query: String,
        wordMode: SearchWordMode,
        analyzer: SearchAnalyzerProfile
    ) throws -> String {
        try compileWithHighlightClauses(
            query: query,
            wordMode: wordMode,
            analyzer: analyzer
        ).ftsQuery
    }

    /**
     Compiles matching and visible-emphasis contracts from one shared Lucene syntax tree.

     - Parameters:
       - query: User input before Android's cleanup/decorator passes.
       - wordMode: Search mode applied before Lucene parsing.
       - analyzer: Module-specific analyzer used for terms and phrases.
     - Returns: FTS expression plus positive term/prefix/phrase clauses in parsed order.
     - Side effects: May lazily load analyzer resources.
     - Failure modes: Propagates the same empty, malformed, unsupported, or resource failures as
       `compile`; a prohibited-only query never yields a presentation-only plan.
     */
    static func compileWithHighlightClauses(
        query: String,
        wordMode: SearchWordMode,
        analyzer: SearchAnalyzerProfile
    ) throws -> (ftsQuery: String, highlightClauses: [SearchTextHighlightClause]) {
        let cleaned = cleanSearchString(query)
        guard !cleaned.isEmpty else { throw SearchIndexError.emptyQuery }
        let decorated = decorate(cleaned, wordMode: wordMode)
        var parser = try Parser(tokens: Lexer.tokenize(decorated), analyzer: analyzer)
        let queryNode = try parser.parseTopLevel()
        switch try lower(queryNode) {
        case .expression(let expression):
            return (expression, positiveHighlightClauses(in: queryNode))
        case .matchNone:
            throw SearchIndexError.unsupportedQuerySyntax(token: "query with only prohibited clauses")
        }
    }

    /**
     Collects positive visible-emphasis clauses from one parsed Lucene subtree.

     - Parameter node: Parsed term, prefix, phrase, or Boolean subtree after analyzer processing.
     - Returns: Positive clauses in parser order; prohibited subtrees contribute no presentation.
     - Side effects: None.
     - Failure modes: None; empty analyzed nodes return no clauses and matching remains owned by
       the independently lowered FTS expression.
     */
    private static func positiveHighlightClauses(
        in node: QueryNode
    ) -> [SearchTextHighlightClause] {
        switch node {
        case .term(let terms):
            return terms.map(SearchTextHighlightClause.term)
        case .prefix(let prefix):
            return [.prefix(prefix)]
        case .phrase(let terms):
            return terms.isEmpty ? [] : [.phrase(terms)]
        case .boolean(let clauses):
            return clauses.flatMap { clause in
                clause.occur == .mustNot ? [] : positiveHighlightClauses(in: clause.node)
            }
        }
    }

    /** Mirrors Android `SearchControl.cleanSearchString`, including its single double-space pass. */
    private static func cleanSearchString(_ query: String) -> String {
        let placeholder = "strongCOLON"
        return query
            .replacingOccurrences(of: "strong:", with: placeholder)
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: placeholder, with: "strong:")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
    }

    /** Mirrors JSword `LuceneQueryDecorator` exactly for Search's three exposed modes. */
    private static func decorate(_ query: String, wordMode: SearchWordMode) -> String {
        switch wordMode {
        case .allWords:
            return "+" + query.components(separatedBy: " ").joined(separator: " +")
        case .anyWord:
            return query
        case .phrase:
            return "\"\(query)\""
        }
    }

    /**
     Lowers Lucene clause occurrence to an equivalent FTS5 set expression over opaque tokens.

     Analyzer tokens are encoded at this final boundary so Boolean structure remains readable while
     SQLite cannot split punctuation or apply another Unicode normalization pass. UTF-8 hex preserves
     prefix bytes, so Lucene prefix terms retain their matching set after encoding.

     - Parameter node: Parsed Lucene query node containing complete analyzer tokens.
     - Returns: Equivalent FTS5 set expression or an internal match-none sentinel.
     - Side effects: None.
     - Throws: `unsupportedQuerySyntax` when Lucene's clause set is purely prohibited and therefore has
       no bounded positive FTS5 universe.
     */
    private static func lower(_ node: QueryNode) throws -> LoweredExpression {
        switch node {
        case .term(let tokens):
            guard !tokens.isEmpty else { return .matchNone }
            return .expression(join(tokens.map { quote(SearchIndexTokenCodec.encode($0)) }, operator: "OR"))
        case .phrase(let tokens):
            guard !tokens.isEmpty else { return .matchNone }
            return .expression(quote(SearchIndexTokenCodec.encodedText(tokens)))
        case .prefix(let prefix):
            return .expression("\(quote(SearchIndexTokenCodec.encode(prefix)))*")
        case .boolean(let clauses):
            var required: [String] = []
            var optional: [String] = []
            var prohibited: [String] = []

            for clause in clauses {
                let lowered = try lower(clause.node)
                switch (clause.occur, lowered) {
                case (.must, .matchNone):
                    return .matchNone
                case (.should, .matchNone), (.mustNot, .matchNone):
                    continue
                case (.must, .expression(let expression)):
                    required.append(expression)
                case (.should, .expression(let expression)):
                    optional.append(expression)
                case (.mustNot, .expression(let expression)):
                    prohibited.append(expression)
                }
            }

            let positive = required.isEmpty ? optional : required
            guard !positive.isEmpty else { return .matchNone }
            var expression = join(positive, operator: required.isEmpty ? "OR" : "AND")
            if !prohibited.isEmpty {
                expression = "(\(expression)) NOT (\(join(prohibited, operator: "OR")))"
            }
            return .expression(expression)
        }
    }

    /** Joins child expressions with stable parentheses so FTS5 precedence cannot change the set. */
    private static func join(_ expressions: [String], operator operation: String) -> String {
        guard expressions.count > 1 else { return expressions.first ?? "" }
        return expressions.map { "(\($0))" }.joined(separator: " \(operation) ")
    }

    /** Quotes an analyzed FTS5 token or phrase without exposing user syntax to SQLite. */
    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/** Lucene 3.6.2 JavaCC-compatible lexical scanner for the supported query subset. */
private extension Lucene29QueryCompiler {
    enum Lexer {
        /**
         Tokenizes Lucene syntax while preserving escapes inside terms and phrases.

         Unsupported range, fuzzy, boost, generic wildcard, and field tokens are emitted
         explicitly so the parser can reject them deterministically.
         */
        fileprivate static func tokenize(_ source: String) throws -> [Token] {
            let characters = Array(source)
            var tokens: [Token] = []
            var index = 0

            while index < characters.count {
                let character = characters[index]
                if isWhitespace(character) {
                    index += 1
                    continue
                }
                if character == "&", peek(characters, after: index) == "&" {
                    tokens.append(.and)
                    index += 2
                    continue
                }
                if character == "|", peek(characters, after: index) == "|" {
                    tokens.append(.or)
                    index += 2
                    continue
                }

                switch character {
                case "+":
                    appendSymbolicModifier(
                        .plus,
                        source: characters,
                        index: &index,
                        tokens: &tokens
                    )
                case "-":
                    appendSymbolicModifier(
                        .minus,
                        source: characters,
                        index: &index,
                        tokens: &tokens
                    )
                case "!":
                    appendSymbolicModifier(
                        .not,
                        source: characters,
                        index: &index,
                        tokens: &tokens
                    )
                case "(": tokens.append(.leftParen); index += 1
                case ")": tokens.append(.rightParen); index += 1
                case ":": tokens.append(.colon); index += 1
                case "\"":
                    let phrase = try scanPhrase(characters, index: &index)
                    tokens.append(.phrase(phrase))
                case "[", "]", "{", "}", "~", "^":
                    tokens.append(.unsupported(String(character)))
                    index += 1
                default:
                    let term = try scanTerm(characters, index: &index)
                    if term == "AND" {
                        tokens.append(.and)
                    } else if term == "OR" {
                        tokens.append(.or)
                    } else if term == "NOT" {
                        tokens.append(.not)
                    } else if term.contains("?") || term.contains("*") {
                        let starCount = term.filter { $0 == "*" }.count
                        if starCount == 1, term.hasSuffix("*"), term.count > 1, !term.contains("?") {
                            tokens.append(.prefix(String(term.dropLast())))
                        } else {
                            tokens.append(.unsupported(term))
                        }
                    } else {
                        tokens.append(.term(term))
                    }
                }
            }
            return tokens
        }

        /**
         Emits an attached unary modifier and ignores Lucene JavaCC's whitespace-separated BAREOPER.

         `+faith`, `-works`, and `!works` are modifiers. In contrast, Lucene 3.6.2 consumes the
         standalone operator in `+ faith`, `- works`, or `! works` without changing the next clause.
         */
        private static func appendSymbolicModifier(
            _ token: Token,
            source: [Character],
            index: inout Int,
            tokens: inout [Token]
        ) {
            index += 1
            guard index < source.count, !isWhitespace(source[index]) else { return }
            tokens.append(token)
        }

        /** Reads one quoted token and applies Lucene's backslash escape removal. */
        private static func scanPhrase(_ source: [Character], index: inout Int) throws -> String {
            index += 1
            var output = ""
            while index < source.count {
                let character = source[index]
                if character == "\"" {
                    index += 1
                    return output
                }
                if character == "\\" {
                    index += 1
                    guard index < source.count else {
                        throw SearchIndexError.invalidQuery(reason: "trailing escape")
                    }
                }
                output.append(source[index])
                index += 1
            }
            throw SearchIndexError.invalidQuery(reason: "unclosed quote")
        }

        /** Reads one JavaCC TERM/PREFIXTERM/WILDTERM token and removes Lucene escapes. */
        private static func scanTerm(_ source: [Character], index: inout Int) throws -> String {
            var output = ""
            while index < source.count {
                let character = source[index]
                if isWhitespace(character) || "!():^[]\"{}~".contains(character) {
                    break
                }
                if (character == "+" || character == "-") && output.isEmpty {
                    break
                }
                if character == "\\" {
                    index += 1
                    guard index < source.count else {
                        throw SearchIndexError.invalidQuery(reason: "trailing escape")
                    }
                    output.append(source[index])
                    index += 1
                    continue
                }
                output.append(character)
                index += 1
            }
            guard !output.isEmpty else {
                throw SearchIndexError.invalidQuery(reason: "unexpected token \(source[index])")
            }
            return output
        }

        /** Returns the following character without advancing the scanner. */
        private static func peek(_ source: [Character], after index: Int) -> Character? {
            let next = index + 1
            return next < source.count ? source[next] : nil
        }

        /** Matches Lucene's default query-parser whitespace set. */
        private static func isWhitespace(_ character: Character) -> Bool {
            character == " " || character == "\t" || character == "\n" ||
                character == "\r" || character == "\u{3000}"
        }
    }
}

/** Recursive-descent port of Lucene 3.6.2 `QueryParser.Query`, `Clause`, and `addClause`. */
private extension Lucene29QueryCompiler {
    struct Parser {
        fileprivate let tokens: [Token]
        fileprivate let analyzer: SearchAnalyzerProfile
        fileprivate var index = 0

        /** Creates a deterministic parser over a pre-tokenized query. */
        fileprivate init(tokens: [Token], analyzer: SearchAnalyzerProfile) throws {
            guard !tokens.isEmpty else { throw SearchIndexError.emptyQuery }
            self.tokens = tokens
            self.analyzer = analyzer
        }

        /** Parses one complete query and rejects trailing tokens as Lucene's top-level parser does. */
        fileprivate mutating func parseTopLevel() throws -> QueryNode {
            let result = try parseQuery(stoppingAtRightParenthesis: false)
            guard index == tokens.count else {
                throw SearchIndexError.invalidQuery(reason: "unexpected trailing token")
            }
            return result
        }

        /** Parses Lucene's flat clause sequence until EOF or a containing right parenthesis. */
        private mutating func parseQuery(stoppingAtRightParenthesis: Bool) throws -> QueryNode {
            var clauses: [Clause] = []
            let firstModifier = parseModifier()
            let firstNode = try parseClause()
            addClause(&clauses, conjunction: .none, modifier: firstModifier, node: firstNode)

            while index < tokens.count {
                if tokens[index] == .rightParen {
                    guard stoppingAtRightParenthesis else {
                        throw SearchIndexError.invalidQuery(reason: "misplaced closing parenthesis")
                    }
                    break
                }
                let conjunction = parseConjunction()
                let modifier = parseModifier()
                let node = try parseClause()
                addClause(&clauses, conjunction: conjunction, modifier: modifier, node: node)
            }
            return clauses.count == 1 && firstModifier == .none
                ? clauses[0].node
                : .boolean(clauses)
        }

        /** Parses one term, phrase, prefix, or nested query clause. */
        private mutating func parseClause() throws -> QueryNode {
            guard index < tokens.count else {
                throw SearchIndexError.invalidQuery(reason: "missing clause")
            }
            let token = tokens[index]
            index += 1
            switch token {
            case .term(let source):
                if index < tokens.count, tokens[index] == .colon {
                    throw SearchIndexError.unsupportedQuerySyntax(token: "\(source):")
                }
                let analyzed = try SearchTextAnalyzer.analyzedTokens(source, profile: analyzer)
                guard !analyzed.isEmpty else {
                    throw SearchIndexError.invalidQuery(reason: "empty analyzed term")
                }
                return .term(analyzed)
            case .phrase(let source):
                if index < tokens.count, tokens[index] == .unsupported("~") {
                    throw SearchIndexError.unsupportedQuerySyntax(token: "phrase slop")
                }
                let analyzed = try SearchTextAnalyzer.analyzedTokens(source, profile: analyzer)
                guard !analyzed.isEmpty else {
                    throw SearchIndexError.invalidQuery(reason: "empty analyzed phrase")
                }
                return .phrase(analyzed)
            case .prefix(let source):
                let lowered = try SearchTextAnalyzer.lowercasedExpandedTerm(source)
                guard !lowered.isEmpty else {
                    throw SearchIndexError.invalidQuery(reason: "empty prefix")
                }
                return .prefix(lowered)
            case .leftParen:
                let nested = try parseQuery(stoppingAtRightParenthesis: true)
                guard index < tokens.count, tokens[index] == .rightParen else {
                    throw SearchIndexError.invalidQuery(reason: "unclosed parenthesis")
                }
                index += 1
                return nested
            case .unsupported(let source):
                throw SearchIndexError.unsupportedQuerySyntax(token: source)
            case .colon:
                throw SearchIndexError.unsupportedQuerySyntax(token: ":")
            case .and, .or, .not, .plus, .minus, .rightParen:
                throw SearchIndexError.invalidQuery(reason: "operator without a following clause")
            }
        }

        /** Consumes an optional Lucene conjunction. */
        private mutating func parseConjunction() -> Conjunction {
            guard index < tokens.count else { return .none }
            switch tokens[index] {
            case .and:
                index += 1
                return .and
            case .or:
                index += 1
                return .or
            default:
                return .none
            }
        }

        /** Consumes an optional Lucene unary modifier. */
        private mutating func parseModifier() -> Modifier {
            guard index < tokens.count else { return .none }
            switch tokens[index] {
            case .plus:
                index += 1
                return .required
            case .minus, .not:
                index += 1
                return .prohibited
            default:
                return .none
            }
        }

        /** Assigns occurrence exactly as Lucene 3.6.2 `QueryParser.addClause` in default-OR mode. */
        private func addClause(
            _ clauses: inout [Clause],
            conjunction: Conjunction,
            modifier: Modifier,
            node: QueryNode
        ) {
            if conjunction == .and, let previous = clauses.indices.last,
               clauses[previous].occur != .mustNot {
                clauses[previous].occur = .must
            }

            let occur: Occur
            if modifier == .prohibited {
                occur = .mustNot
            } else if modifier == .required || conjunction == .and {
                occur = .must
            } else {
                occur = .should
            }
            clauses.append(Clause(node: node, occur: occur))
        }
    }
}
