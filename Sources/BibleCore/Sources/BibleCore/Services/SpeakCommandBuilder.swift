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

    /// Divine-name content accumulated for replacement before folding into the surrounding run.
    private var divineNameRun: String?

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
        let name = localName(elementName)
        let parentVisible = states.last?.visible ?? true
        switch name {
        case "verse":
            flushPendingText()
            if let marker = attributeDict["osisID"] ?? attributeDict["sID"],
               let verse = marker.split(separator: ".").last.flatMap({ Int($0) }) {
                commands.append(.verseNumber(verse))
            }
            states.append(.init(visible: parentVisible, kind: .normal))
        case "note":
            flushPendingText()
            if attributeDict["type"] == "study", playbackSettings.speakFootnotes {
                commands.append(.pause(milliseconds: 150))
                footnoteDepth += 1
                states.append(.init(visible: parentVisible, kind: .footnote))
            } else {
                commands.append(.excluded(.nonStudyNote))
                states.append(.init(visible: false, kind: .hidden))
            }
        case "reference":
            flushPendingText()
            commands.append(.excluded(.crossReference))
            states.append(.init(visible: false, kind: .hidden))
        case "title":
            flushPendingText()
            if playbackSettings.speakTitles {
                commands.append(.pause(milliseconds: 150))
            }
            titleDepth += 1
            states.append(.init(visible: parentVisible && playbackSettings.speakTitles, kind: .title))
        case "divinename":
            divineNameDepth += 1
            states.append(.init(visible: parentVisible, kind: .divineName))
        case "p", "l", "lb":
            flushPendingText()
            states.append(.init(visible: parentVisible, kind: .paragraph))
        case "div":
            flushPendingText()
            let type = attributeDict["type"] ?? ""
            let isParagraph = ["paragraph", "x-p", "x-end-paragraph"].contains(type)
            if isParagraph, attributeDict["sID"] == nil {
                commands.append(.pause(milliseconds: 500))
            }
            states.append(.init(visible: parentVisible, kind: isParagraph ? .paragraph : .normal))
        default:
            // Inline OSIS markup (w, seg, transChange, q, hi, milestones, unknown elements) must
            // not interrupt the spoken run: Android's OsisToBibleSpeak accumulates straight
            // through it. Flushing here split Strong's-tagged text into one utterance per word
            // and left bare punctuation runs that the synthesizer narrated as "comma".
            states.append(.init(visible: parentVisible, kind: .normal))
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard states.count > 1 else { return }
        let state = states.removeLast()
        switch state.kind {
        case .title where playbackSettings.speakTitles:
            flushPendingText()
            commands.append(.pause(milliseconds: 500))
            titleDepth = max(titleDepth - 1, 0)
        case .footnote where playbackSettings.speakFootnotes:
            flushPendingText()
            commands.append(.pause(milliseconds: 150))
            footnoteDepth = max(footnoteDepth - 1, 0)
        case .divineName:
            foldDivineNameRun()
            divineNameDepth = max(divineNameDepth - 1, 0)
        case .title:
            titleDepth = max(titleDepth - 1, 0)
        case .paragraph:
            flushPendingText()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let state = states.last, state.visible else { return }
        if divineNameDepth > 0, advancedSettings.replaceDivineName {
            divineNameRun = (divineNameRun ?? "") + string
            return
        }
        appendToPendingText(string)
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        flushPendingText()
    }

    /** Accumulates one visible character run into the current same-kind pending text. */
    private func appendToPendingText(_ string: String) {
        let kind: SpokenTextKind
        if titleDepth > 0 {
            kind = .title
        } else if footnoteDepth > 0 {
            kind = .footnote
        } else {
            kind = .normal
        }
        if pendingText?.kind == kind {
            pendingText?.rawValue.append(string)
        } else {
            flushPendingText()
            pendingText = PendingText(rawValue: string, kind: kind)
        }
    }

    /** Applies divine-name replacement to the finished run and folds it into the surrounding text. */
    private func foldDivineNameRun() {
        guard let run = divineNameRun else { return }
        divineNameRun = nil
        var text = run
        for (source, replacement) in zip(divineNameArrays.original, divineNameArrays.replacement)
            where !source.isEmpty {
            text = text.replacingOccurrences(of: source, with: replacement)
        }
        appendToPendingText(text)
    }

    /** Flushes the accumulated spoken run at one structural OSIS boundary. */
    private func flushPendingText() {
        guard let pendingText else { return }
        self.pendingText = nil
        let text = SpeakCommandBuilder.normalizeText(pendingText.rawValue)
        guard !text.isEmpty else { return }
        // A run without letters or digits is stray markup punctuation; synthesizers narrate it
        // ("comma", "full stop") when spoken alone, so it merges into the preceding same-kind
        // command or is dropped.
        if !text.contains(where: { $0.isLetter || $0.isNumber }) {
            mergeTrailingPunctuation(text, kind: pendingText.kind)
            return
        }
        commands.append(command(for: text, kind: pendingText.kind))
    }

    /** Attaches a punctuation-only run to the previous same-kind command when one exists. */
    private func mergeTrailingPunctuation(_ text: String, kind: SpokenTextKind) {
        guard let last = commands.last else { return }
        let merged: SpeakCommand?
        switch (last, kind) {
        case (.text(let value), .normal):
            merged = .text("\(value)\(joiner(for: text))\(text)")
        case (.heading(let value), .title):
            merged = .heading("\(value)\(joiner(for: text))\(text)")
        case (.footnote(let value), .footnote):
            merged = .footnote("\(value)\(joiner(for: text))\(text)")
        default:
            merged = nil
        }
        if let merged {
            commands[commands.count - 1] = merged
        }
    }

    /** Sentence punctuation attaches directly; bracketing punctuation keeps one space. */
    private func joiner(for text: String) -> String {
        guard let first = text.first else { return "" }
        return [",", ".", ";", ":", "!", "?"].contains(String(first)) ? "" : " "
    }

    /** Maps one spoken-text kind onto its command constructor. */
    private func command(for text: String, kind: SpokenTextKind) -> SpeakCommand {
        switch kind {
        case .title:
            return .heading(text)
        case .footnote:
            return .footnote(text)
        case .normal:
            return .text(text)
        }
    }

    private func localName(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init)?.lowercased() ?? value.lowercased()
    }
}
