// SwordSourceFormatOSISConverter.swift -- Android-compatible native source conversion

import CLibSword
import Foundation

/**
 Converts the current SWORD entry to the same structural OSIS source family used by Android.

 Pinned JSword selects `OSISFilter` for OSIS/TEI, `THMLFilter` for ThML, `GBFFilter` for GBF, and
 `PlainTextFilter` for plain/unknown source types. Native libsword filters are not equivalent: they
 can emit malformed markup or different line, Strong, reference, and tag semantics. Every native
 read crosses this boundary so reader, Search, speech, AI, and unlock validation cannot drift.
 */
enum SwordSourceFormatOSISConverter {
    /**
     Converts the current module entry without moving its cursor.

     - Parameter handle: Live SWORD module handle whose cursor and runtime lease are owned by the
       caller.
     - Returns: Canonical structural OSIS for the current entry, or an empty string when source
       metadata/content cannot be converted under the Android contract.
     - Side effects: Reads module metadata and one backend-extracted/decoded entry buffer; ThML/GBF
       passage references are resolved against the current native VerseKey.
     - Failure modes: Never throws. Missing source, invalid references, and irreparable structured
       markup fail closed without rendered-text substitution.
     - Important: Call only while holding `SwordRuntime`; native pointers are copied immediately.
     */
    static func fragment(handle: UnsafeMutableRawPointer) -> String {
        let source = SWModule_getDecodedSourceFragment(handle).map(String.init(cString:)) ?? ""
        return fragment(handle: handle, decodedSource: source)
    }

    /**
     Converts one already-decoded physical source record through the configured JSword filter.

     - Parameters:
       - handle: Live SWORD module supplying source metadata and current key/reference context.
       - decodedSource: Exact backend-extracted source after native encoding conversion only.
     - Returns: Pinned JSword-compatible structural OSIS for the configured source family.
     - Side effects: Reads module metadata and may resolve ThML/GBF references against the current
       native key; no cursor or persisted state is mutated.
     - Failure modes: Missing/unknown `SourceType` follows JSword's plain-text default. Irreparable
       OSIS/TEI/ThML becomes empty output; malformed GBF tags follow its tolerant tokenizer.
     - Important: Call only while holding `SwordRuntime`.
     */
    static func fragment(
        handle: UnsafeMutableRawPointer,
        decodedSource: String
    ) -> String {
        let sourceType = SWModule_getConfigEntry(handle, "SourceType")
            .map { String(cString: $0).lowercased(with: Locale(identifier: "en")) } ?? ""
        let moduleInitials = String(cString: SWModule_getName(handle))
        switch sourceType {
        case "osis", "tei":
            return SwordJSwordOSISSourceCompatibility.repairedSourceXML(
                decodedSource,
                moduleInitials: moduleInitials
            )
        case "thml":
            return thmlFragment(handle: handle, decodedSource: decodedSource)
        case "gbf":
            return SwordJSwordGBFSourceFilter.convert(
                decodedSource,
                resolveReference: referenceResolver(handle: handle)
            )
        default:
            return SwordJSwordPlainTextSourceFilter.convert(decodedSource)
        }
    }

    /**
     Converts an already-decoded physical ThML record through the same Android boundary.

     - Parameters:
       - handle: Live SWORD module supplying current key/reference context.
       - decodedSource: Exact backend-extracted/decoded ThML, including physical RawLD records that
         bypass an ambiguous native key lookup.
     - Returns: JSword-compatible structural OSIS.
     - Side effects: Resolves scripture references against native VerseKey context when available.
     - Failure modes: Irreparable source becomes empty output and invalid references remain visible
       without an invented canonical target.
     - Important: Call only while holding `SwordRuntime`.
     */
    static func thmlFragment(
        handle: UnsafeMutableRawPointer,
        decodedSource: String
    ) -> String {
        guard !decodedSource.isEmpty else { return "" }
        let currentOSISRef = SWModule_getCurrentOSISRef(handle).map(String.init(cString:)) ?? ""
        let verseOrdinal = Int(SWModule_getVerseKeyIndex(handle))
        return SwordJSwordThMLSourceFilter.convert(
            decodedSource,
            verseOSISRef: positiveVerseOSISRef(currentOSISRef),
            verseOrdinal: verseOrdinal >= 0 ? verseOrdinal : nil,
            resolveReference: referenceResolver(handle: handle)
        )
    }

    /**
     Creates one copied-string scripture-reference resolver for structural source filters.

     - Parameter handle: Live SWORD module positioned on the source entry owning relative context.
     - Returns: Closure mapping one source reference to canonical space-delimited OSIS, or empty
       text when native VerseKey parsing rejects it.
     - Side effects: Calls the native reference parser without moving the module cursor.
     - Failure modes: Invalid and non-VerseKey references return an empty string without throwing.
     - Important: The closure must not escape the enclosing `SwordRuntime` lease.
     */
    private static func referenceResolver(
        handle: UnsafeMutableRawPointer
    ) -> (String) -> String {
        { reference in
            reference.withCString { pointer in
                SWModule_resolveOSISReference(handle, pointer).map(String.init(cString:)) ?? ""
            }
        }
    }

    /**
     Accepts only a canonical positive-verse OSIS reference for JSword's generated verse wrapper.

     - Parameter reference: Current native VerseKey OSIS reference.
     - Returns: The exact reference when its last component is a positive integer; otherwise nil.
     - Side effects: None.
     - Failure modes: Empty, generic, range, chapter-introduction, and book-introduction keys return
       nil so they remain unwrapped like JSword verse-zero content.
     */
    private static func positiveVerseOSISRef(_ reference: String) -> String? {
        guard !reference.contains("-"),
              let component = reference.split(separator: ".").last,
              let verse = Int(component),
              verse > 0 else {
            return nil
        }
        return reference
    }
}

/**
 Ports pinned JSword's `THMLFilter` tag projection into the shared iOS XML tree.

 The filter repairs source as ThML first, then converts SAX-equivalent tags to OSIS. Unknown tags
 remain visible as `seg[type=x-*]`; ignored wrappers keep their children; skipped source families
 disappear with their descendants. It never routes semantic source through rendered HTML.
 */
enum SwordJSwordThMLSourceFilter {
    /// Tags whose entire subtree pinned JSword removes.
    private static let skippedTags: Set<String> = [
        "applet", "area", "base", "basefont", "button", "col", "colgroup", "form", "frame",
        "head", "hr", "iframe", "input", "link", "map", "meta", "noscript", "object",
        "optgroup", "option", "param", "pb", "script", "select", "style", "textarea", "title",
    ]

    /// Tags whose wrapper pinned JSword removes while retaining converted descendants.
    private static let ignoredTags: Set<String> = [
        "bdo", "body", "fieldset", "frameset", "html", "pre", "span", "tbody", "tfoot", "thead",
    ]

    /// Known tags represented by JSword's generic `AnonymousTag` handler.
    private static let anonymousTags: Set<String> = [
        "address", "caption", "cite", "code", "del", "dfn", "ins", "kbd", "label", "legend",
        "samp", "var", "added", "attr", "argument", "date", "deleted", "def", "index",
        "insertindex", "glossary", "scripcom", "scripcontext", "unclear",
    ]

    /**
     Converts one decoded ThML source fragment to JSword-compatible OSIS.

     - Parameters:
       - source: Exact decoded ThML after physical extraction, decryption, and character decoding;
         no native display or markup option filter has transformed it.
       - verseOSISRef: Positive current VerseKey reference, or nil for generic/intro content.
       - verseOrdinal: Current native VerseKey ordinal used by JSword's generated verse element.
       - resolveReference: Resolver for ThML `scripRef` text relative to the current VerseKey.
     - Returns: Deterministically serialized OSIS child XML.
     - Side effects: Allocates/mutates in-memory XML nodes and calls the supplied resolver; no module
       cursor movement or persisted state mutation occurs.
     - Failure modes: Irreparable source becomes empty output. Unparseable scripture references keep
       their visible content without an invented `osisRef`.
     */
    static func convert(
        _ source: String,
        verseOSISRef: String?,
        verseOrdinal: Int?,
        resolveReference: (String) -> String
    ) -> String {
        let thmlRoot = SwordJSwordOSISFragmentParser.parseThML(source)
        var output = convertChildren(of: thmlRoot, resolveReference: resolveReference)
        guard !output.isEmpty else { return "" }
        if let verseOSISRef,
           !output.contains(where: { $0.isElement(exactlyNamed: "verse") }) {
            var attributes = ["osisID": verseOSISRef]
            if let verseOrdinal {
                attributes["verseOrdinal"] = String(verseOrdinal)
            }
            let verse = SwordXMLNode.element(name: "verse", attributes: attributes)
            verse.children = output
            output = [verse]
        }
        return output.map { $0.serializedXML() }.joined()
    }

    /**
     Converts children in document order while allowing `sync` to mutate the prior sibling.

     - Parameters:
       - parent: Parsed ThML parent whose direct children are consumed.
       - resolveReference: Current-VerseKey scripture-reference resolver.
     - Returns: OSIS nodes in pinned SAX event order.
     - Side effects: Mutates only newly allocated output nodes.
     - Failure modes: Unsupported/unknown tags become semantic `seg` wrappers; skipped tags return
       no output and no error.
     */
    private static func convertChildren(
        of parent: SwordXMLNode,
        resolveReference: (String) -> String
    ) -> [SwordXMLNode] {
        var output: [SwordXMLNode] = []
        for child in parent.children {
            guard child.isElement else {
                if child.isTextLike {
                    output.append(.text(child.stringValue))
                }
                continue
            }

            let name = child.localName.lowercased()
            if name == "sync" {
                applySync(child, to: &output)
                continue
            }
            output.append(contentsOf: convertElement(child, resolveReference: resolveReference))
        }
        return output
    }

    /**
     Converts one parsed ThML element using pinned JSword's final tag registry.

     - Parameters:
       - source: Parsed source element, including its preserved attributes and children.
       - resolveReference: Current-VerseKey scripture-reference resolver.
     - Returns: Zero or more OSIS nodes because ignored/headings tags flatten into their parent.
     - Side effects: Allocates new nodes and may call the resolver for `scripRef`.
     - Failure modes: Missing optional attributes are omitted; unknown tags remain visible as
       `seg[type=x-qualifiedName]` rather than being discarded.
     */
    private static func convertElement(
        _ source: SwordXMLNode,
        resolveReference: (String) -> String
    ) -> [SwordXMLNode] {
        let name = source.localName.lowercased()
        if skippedTags.contains(name) { return [] }
        if ignoredTags.contains(name) {
            return convertChildren(of: source, resolveReference: resolveReference)
        }
        if (1...6).map({ "h\($0)" }).contains(name) {
            let level = String(name.dropFirst())
            return [SwordXMLNode.element(name: "title", attributes: ["level": level])]
                + convertChildren(of: source, resolveReference: resolveReference)
        }

        let children = convertChildren(of: source, resolveReference: resolveReference)
        let element: SwordXMLNode
        switch name {
        case "a":
            let href = source.attribute(named: "href").flatMap { $0.isEmpty ? nil : $0 }
            element = node("reference", attribute: "osisRef", value: href)
        case "abbr", "acronym":
            element = node("abbr")
        case "b", "strong":
            element = node("hi", attributes: ["type": "bold"])
        case "big":
            element = node("hi", attributes: ["type": "x-big"])
        case "blockquote":
            // Pinned registration order replaces BlockquoteTag with QTag.
            element = node("q")
        case "br":
            element = node("lb")
        case "center":
            element = node("seg", attributes: ["type": "text-align: center;"])
        case "citation":
            element = node("q", attributes: ["type": "blockquote"])
        case "div", "div1", "div2", "div3", "div4", "div5", "div6":
            if source.attribute(named: "type") == "variant" {
                var attributes = ["type": "x-variant"]
                if let variantClass = source.attribute(named: "class") {
                    attributes["subType"] = "x--\(variantClass)"
                }
                element = node("seg", attributes: attributes)
            } else {
                element = node("div")
            }
        case "dl", "ul":
            element = node("list", attributes: ["type": "x-unordered"])
        case "ol":
            element = node("list", attributes: ["type": "x-ordered"])
        case "dd", "dt", "li":
            element = node("item")
        case "em", "i":
            element = node("hi", attributes: ["type": "italic"])
        case "font":
            var style = ""
            if let color = source.attribute(named: "color") { style += "color: \(color);" }
            if let size = source.attribute(named: "size") { style += "font-size: \(size);" }
            element = node("seg", attributes: style.isEmpty ? [:] : ["type": style])
        case "foreign":
            element = node("foreign", attribute: "xml:lang", value: source.attribute(named: "lang"))
        case "img":
            element = node("figure", attribute: "src", value: source.attribute(named: "src"))
        case "name":
            element = node("seg")
        case "note":
            element = node("note", attributes: ["type": "x-StudyNote"])
        case "p", "scripture":
            element = node("p")
        case "scripref":
            let passage = source.attribute(named: "passage")
            let requested = passage ?? source.stringValue
            let resolved = resolveReference(requested)
            let osisReference = resolved.isEmpty ? passage : resolved
            element = node("reference", attribute: "osisRef", value: osisReference)
        case "small":
            element = node("hi", attributes: ["type": "x-small"])
        case "sub":
            element = node("hi", attributes: ["type": "sub"])
        case "sup":
            element = node("hi", attributes: ["type": "super"])
        case "table":
            element = node("table", attribute: "border", value: source.attribute(named: "border"))
        case "td", "th":
            var attributes: [String: String] = [:]
            if let rows = source.attribute(named: "rowspan") { attributes["rows"] = rows }
            if let columns = source.attribute(named: "colspan") { attributes["cols"] = columns }
            if name == "th" { attributes["role"] = "label" }
            element = node("cell", attributes: attributes)
        case "term":
            element = node("name")
        case "tr":
            element = node("row")
        case "tt":
            element = node("hi", attributes: ["type": "x-tt"])
        case "u":
            element = node("hi", attributes: ["type": "underline"])
        case "verse":
            element = node("lg")
        default:
            let tagName = anonymousTags.contains(name) ? name : source.qualifiedName
            element = node("seg", attributes: ["type": "x-\(tagName)"])
        }
        element.children = children
        return [element]
    }

    /**
     Applies pinned JSword `SyncTag` to the already-emitted sibling immediately before the tag.

     - Parameters:
       - source: Parsed `sync` element carrying exact `type` and `value` attributes.
       - siblings: Current converted sibling list, mutated in place.
     - Side effects: Wraps a prior text node in `w`, appends lemma/morph metadata to a prior `w`,
       or appends a dictionary-identity `div`.
     - Failure modes: Missing attributes, unsupported types, and absent/non-text prior siblings are
       ignored exactly like JSword's data-police path; no error is thrown.
     */
    private static func applySync(_ source: SwordXMLNode, to siblings: inout [SwordXMLNode]) {
        guard let type = source.attribute(named: "type"),
              let value = source.attribute(named: "value") else {
            return
        }
        if type == "Dict" {
            siblings.append(node("div", attributes: ["osisID": "dict://\(value)"]))
            return
        }

        let attribute: String
        let prefix: String
        switch type {
        case "Strongs":
            attribute = "lemma"
            prefix = "strong:"
        case "morph":
            attribute = "morph"
            prefix = "robinson:"
        case "lemma":
            attribute = "lemma"
            prefix = "lemma:"
        default:
            return
        }
        guard let last = siblings.last else { return }
        if last.isTextLike {
            let word = node("w", attributes: [attribute: prefix + value])
            word.children = [last]
            siblings[siblings.count - 1] = word
        } else if last.isElement(exactlyNamed: "w") {
            let existing = last.attribute(named: attribute)
            let combined = [existing, prefix + value].compactMap { $0 }.joined(separator: " ")
            last.setAttribute(named: attribute, value: combined)
        }
    }

    /**
     Creates one OSIS node with a complete attribute dictionary.

     - Parameters:
       - name: Exact OSIS element name.
       - attributes: Exact no-namespace or qualified attribute values.
     - Returns: Empty mutable element ready for converted children.
     - Side effects: None outside allocation.
     - Failure modes: None; serializer escaping occurs later.
     */
    private static func node(
        _ name: String,
        attributes: [String: String] = [:]
    ) -> SwordXMLNode {
        SwordXMLNode.element(name: name, attributes: attributes)
    }

    /**
     Creates one OSIS node while omitting a missing optional attribute.

     - Parameters:
       - name: Exact OSIS element name.
       - attribute: Exact attribute name.
       - value: Optional source value.
     - Returns: Empty element with the attribute only when its value is non-nil.
     - Side effects: None outside allocation.
     - Failure modes: None.
     */
    private static func node(
        _ name: String,
        attribute: String,
        value: String?
    ) -> SwordXMLNode {
        node(name, attributes: value.map { [attribute: $0] } ?? [:])
    }
}
