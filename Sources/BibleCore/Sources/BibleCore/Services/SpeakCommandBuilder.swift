// SpeakCommandBuilder.swift -- Android-style OSIS speech command generation

import Foundation

/**
 Converts one OSIS entry into Android-equivalent speech commands.

 The parser mirrors `OsisToBibleSpeak`: references and non-study notes are excluded, study notes
 obey `speakFootnotes`, titles obey `speakTitles`, paragraph boundaries emit 500 ms pauses, and
 divine-name replacement is limited to `<divineName>` content. Malformed fragments are marked with
 an explicit exclusion command before the supplied plain-text fallback is used.
 */
public enum SpeakCommandBuilder {
    /**
     Builds commands for one OSIS fragment.

     - Parameters:
       - rawOSIS: Raw SWORD OSIS entry.
       - fallbackPlainText: Plain text used only when OSIS parsing fails or produces no speech.
       - language: Source document language used for Android's localized divine-name arrays.
       - playbackSettings: Structured Android playback settings.
       - advancedSettings: Structured Android advanced settings.
     - Returns: Ordered semantic commands, including explicit exclusions.
     - Side effects: Parses XML in memory.
     - Failure modes: Malformed XML is represented by `.excluded(.unsupportedMarkup)` and falls
       back to normalized plain text rather than silently dropping the entry.
     */
    public static func commands(
        rawOSIS: String,
        fallbackPlainText: String,
        language: String,
        playbackSettings: PlaybackSettings,
        advancedSettings: AdvancedSpeakSettings
    ) -> [SpeakCommand] {
        let normalizedFallback = normalizeText(fallbackPlainText)
        guard !rawOSIS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return normalizedFallback.isEmpty ? [] : [.text(normalizedFallback)]
        }

        let delegate = OSISSpeechParserDelegate(
            playbackSettings: playbackSettings,
            advancedSettings: advancedSettings,
            divineNameArrays: SpeakDivineNameCatalog.arrays(for: language)
        )
        let fragment = rawOSIS.replacingOccurrences(
            of: #"<\?xml[^>]*\?>"#,
            with: "",
            options: .regularExpression
        )
        let parser = XMLParser(data: Data("<osis-root>\(fragment)</osis-root>".utf8))
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate

        guard parser.parse() else {
            var result: [SpeakCommand] = [.excluded(.unsupportedMarkup)]
            if !normalizedFallback.isEmpty { result.append(.text(normalizedFallback)) }
            return result
        }

        let commands = delegate.commands
        let hasAudibleCommand = commands.contains { $0.spokenText != nil }
        if hasAudibleCommand || normalizedFallback.isEmpty {
            return commands
        }
        return commands + [.text(normalizedFallback)]
    }

    /** Normalizes the quote variants and whitespace Android normalizes before TTS. */
    public static func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{201d}", with: "\"")
            .replacingOccurrences(of: "\u{201c}", with: "\"")
            .replacingOccurrences(of: "`", with: "'")
            .replacingOccurrences(of: "\u{00b4}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

private final class OSISSpeechParserDelegate: NSObject, XMLParserDelegate {
    private enum ContentKind {
        case normal
        case title
        case footnote
        case divineName
        case paragraph
        case hidden
    }

    private struct ElementState {
        let visible: Bool
        let kind: ContentKind
    }

    private enum SpokenTextKind {
        case normal
        case title
        case footnote
    }

    private struct PendingText {
        var rawValue: String
        let kind: SpokenTextKind
        let replacesDivineName: Bool
    }

    let playbackSettings: PlaybackSettings
    let advancedSettings: AdvancedSpeakSettings
    let divineNameArrays: SpeakDivineNameArrays
    var commands: [SpeakCommand] = []

    private var states: [ElementState] = [.init(visible: true, kind: .normal)]
    private var titleDepth = 0
    private var divineNameDepth = 0
    private var footnoteDepth = 0
    private var pendingText: PendingText?

    init(
        playbackSettings: PlaybackSettings,
        advancedSettings: AdvancedSpeakSettings,
        divineNameArrays: SpeakDivineNameArrays
    ) {
        self.playbackSettings = playbackSettings
        self.advancedSettings = advancedSettings
        self.divineNameArrays = divineNameArrays
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        flushPendingText()
        let name = localName(elementName)
        let parentVisible = states.last?.visible ?? true
        switch name {
        case "verse":
            if let marker = attributeDict["osisID"] ?? attributeDict["sID"],
               let verse = marker.split(separator: ".").last.flatMap({ Int($0) }) {
                commands.append(.verseNumber(verse))
            }
            states.append(.init(visible: parentVisible, kind: .normal))
        case "note":
            if attributeDict["type"] == "study", playbackSettings.speakFootnotes {
                commands.append(.pause(milliseconds: 150))
                footnoteDepth += 1
                states.append(.init(visible: parentVisible, kind: .footnote))
            } else {
                commands.append(.excluded(.nonStudyNote))
                states.append(.init(visible: false, kind: .hidden))
            }
        case "reference":
            commands.append(.excluded(.crossReference))
            states.append(.init(visible: false, kind: .hidden))
        case "title":
            if playbackSettings.speakTitles {
                commands.append(.pause(milliseconds: 150))
            }
            titleDepth += 1
            states.append(.init(visible: parentVisible && playbackSettings.speakTitles, kind: .title))
        case "divinename":
            divineNameDepth += 1
            states.append(.init(visible: parentVisible, kind: .divineName))
        case "p", "l", "lb":
            states.append(.init(visible: parentVisible, kind: .paragraph))
        case "div":
            let type = attributeDict["type"] ?? ""
            let isParagraph = ["paragraph", "x-p", "x-end-paragraph"].contains(type)
            if isParagraph, attributeDict["sID"] == nil {
                commands.append(.pause(milliseconds: 500))
            }
            states.append(.init(visible: parentVisible, kind: isParagraph ? .paragraph : .normal))
        default:
            states.append(.init(visible: parentVisible, kind: .normal))
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        flushPendingText()
        guard states.count > 1 else { return }
        let state = states.removeLast()
        switch state.kind {
        case .title where playbackSettings.speakTitles:
            commands.append(.pause(milliseconds: 500))
            titleDepth = max(titleDepth - 1, 0)
        case .footnote where playbackSettings.speakFootnotes:
            commands.append(.pause(milliseconds: 150))
            footnoteDepth = max(footnoteDepth - 1, 0)
        case .divineName:
            divineNameDepth = max(divineNameDepth - 1, 0)
        case .title:
            titleDepth = max(titleDepth - 1, 0)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let state = states.last, state.visible else { return }
        let kind: SpokenTextKind
        if titleDepth > 0 {
            kind = .title
        } else if footnoteDepth > 0 {
            kind = .footnote
        } else {
            kind = .normal
        }
        let replacesDivineName = divineNameDepth > 0 && advancedSettings.replaceDivineName
        if pendingText?.kind == kind, pendingText?.replacesDivineName == replacesDivineName {
            pendingText?.rawValue.append(string)
        } else {
            flushPendingText()
            pendingText = PendingText(
                rawValue: string,
                kind: kind,
                replacesDivineName: replacesDivineName
            )
        }
    }

    /** Flushes one XML character run without crossing an OSIS element boundary. */
    private func flushPendingText() {
        guard let pendingText else { return }
        self.pendingText = nil
        var text = SpeakCommandBuilder.normalizeText(pendingText.rawValue)
        guard !text.isEmpty else { return }
        if pendingText.replacesDivineName {
            for (source, replacement) in zip(divineNameArrays.original, divineNameArrays.replacement)
                where !source.isEmpty {
                text = text.replacingOccurrences(of: source, with: replacement)
            }
        }
        switch pendingText.kind {
        case .title:
            commands.append(.heading(text))
        case .footnote:
            commands.append(.footnote(text))
        case .normal:
            commands.append(.text(text))
        }
    }

    private func localName(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init)?.lowercased() ?? value.lowercased()
    }
}
