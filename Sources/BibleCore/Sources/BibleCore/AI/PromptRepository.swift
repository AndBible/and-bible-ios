import CryptoKit
import Foundation
import SwordKit

/**
 Identifies where an effective prompt came from without persisting transient add-on metadata.
 */
public enum PromptOrigin: Equatable, Sendable {
    /// A read-only prompt compiled into BibleCore.
    case builtIn

    /// A read-only prompt loaded from a named SWORD add-on module.
    case swordPack(moduleName: String)

    /// An editable SwiftData prompt.
    case user
}

/**
 Effective prompt plus its ownership metadata.
 */
public struct ResolvedAgentPrompt {
    /// Detached prompt value used for execution or presentation.
    public let prompt: AgentPrompt

    /// Source controlling edit and precedence behavior.
    public let origin: PromptOrigin

    /** Creates a resolved prompt value without side effects. */
    public init(prompt: AgentPrompt, origin: PromptOrigin) {
        self.prompt = prompt
        self.origin = origin
    }
}

/**
 One SWORD add-on prompt pack after CSV parsing.
 */
public struct SwordPromptPack {
    /// Installed module initials used for attribution.
    public let moduleName: String

    /// Prompts in source-file order.
    public let prompts: [AgentPrompt]

    /** Creates a parsed prompt-pack value. */
    public init(moduleName: String, prompts: [AgentPrompt]) {
        self.moduleName = moduleName
        self.prompts = prompts
    }
}

/**
 Abstracts prompt-pack discovery so repositories can be tested without a SWORD installation.
 */
public protocol SwordPromptPackProviding {
    /**
     Loads every readable prompt pack in deterministic module order.

     - Returns: Parsed packs. Individual malformed rows are skipped by Android-compatible CSV rules.
     - Side effects: Implementations may enumerate SWORD modules and read local files.
     - Throws: Fatal discovery or file-read failures. Production discovery skips malformed modules.
     */
    func loadPromptPacks() throws -> [SwordPromptPack]
}

/**
 Discovers Android `AndBibleProvidesPrompts` files through an installed `SwordManager`.

 Add-on admission, duplicate ownership, and ordering come from the shared Android `Books.installed()`
 projection. Each referenced filename is constrained to its adjusted module payload directory inside
 the SWORD root. Traversal, absolute paths, unreadable files, and malformed packs are skipped rather
 than weakening the precedence of remaining installed packs.
 */
public final class SwordPromptPackProvider: SwordPromptPackProviding {
    /// Upper bound preventing an installed prompt pack from exhausting memory during parsing.
    private static let maximumPackBytes = 8 * 1_024 * 1_024

    /// Installed-module manager supplying metadata and the module root.
    private let swordManager: SwordManager

    /// Filesystem dependency used for deterministic testing and file validation.
    private let fileManager: FileManager

    /**
     Creates a SWORD-backed prompt-pack provider.

     - Parameters:
       - swordManager: Manager for the installed module root.
       - fileManager: Filesystem implementation; defaults to `.default`.
     - Side effects: none until `loadPromptPacks()` is called.
     */
    public init(swordManager: SwordManager, fileManager: FileManager = .default) {
        self.swordManager = swordManager
        self.fileManager = fileManager
    }

    /**
     Loads prompt packs referenced by Android-admitted add-on metadata.

     - Returns: Parsed packs in pinned JSword installed TreeSet order.
     - Side effects: Reads the manager's shared admitted add-on projection and referenced CSV files.
     - Throws: This production implementation skips per-module failures and does not throw.
     */
    public func loadPromptPacks() throws -> [SwordPromptPack] {
        return swordManager.admittedAddonModules()
            .compactMap { addon in
                guard let rawFilename = addon.promptFileName,
                      !rawFilename.isEmpty,
                      let locationURL = addon.locationURL,
                      let fileURL = promptFileURL(
                        filename: rawFilename,
                        locationURL: locationURL
                      ) else {
                    return nil
                }
                guard fileManager.isReadableFile(atPath: fileURL.path),
                      let data = readPackData(at: fileURL),
                      let prompts = try? PromptCSVParser.parse(data: data) else {
                    return nil
                }
                return SwordPromptPack(moduleName: addon.moduleInfo.name, prompts: prompts)
            }
    }

    /** Reads no more than the configured pack limit plus one overflow-detection byte. */
    private func readPackData(at fileURL: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumPackBytes + 1),
              data.count <= Self.maximumPackBytes else {
            return nil
        }
        return data
    }

    /**
     Resolves a prompt-pack file relative to Android's adjusted module location.

     - Parameters:
       - filename: Singular first `AndBibleProvidesPrompts` value from installed metadata.
       - locationURL: Filesystem-adjusted JSword book location supplied by shared admission.
     - Returns: Standardized readable-candidate URL below the manager root, or nil for an unsafe
       absolute/traversing/escaped path. File readability is checked by the caller.
     - Side effects: Resolves filesystem symlinks without mutation.
     - Failure modes: Absolute paths, parent traversal, and symlink escapes return nil.
     */
    private func promptFileURL(filename: String, locationURL: URL) -> URL? {
        let normalizedFilename = filename.replacingOccurrences(of: "\\", with: "/")
        guard !normalizedFilename.hasPrefix("/"),
              !normalizedFilename.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == ".." }) else {
            return nil
        }
        let root = URL(fileURLWithPath: swordManager.modulePath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolved = locationURL.appendingPathComponent(normalizedFilename)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        guard resolved.path.hasPrefix(rootPrefix) else { return nil }
        return resolved
    }
}

/** Errors raised by Android-compatible prompt-pack CSV parsing. */
public enum PromptCSVError: Error, Equatable, Sendable {
    /// The file has no header row.
    case emptyFile

    /// Input is not UTF-8.
    case invalidUTF8
}

/**
 Parses semicolon-delimited Android prompt-pack CSV, including quoted multiline fields.

 The parser mirrors Android's tolerance: unknown enum values and malformed data rows are skipped,
 while a missing file/header is fatal. At most 1,000 data rows are considered.
 */
public enum PromptCSVParser {
    /// Maximum number of data rows accepted from one pack.
    public static let maximumRows = 1_000

    /**
     Parses prompt rows from UTF-8 CSV data.

     - Parameter data: Semicolon-delimited prompt-pack bytes.
     - Returns: Valid prompt rows in file order.
     - Side effects: none.
     - Throws: `PromptCSVError.invalidUTF8` or `.emptyFile`.
     */
    public static func parse(data: Data) throws -> [AgentPrompt] {
        guard let source = String(data: data, encoding: .utf8) else {
            throw PromptCSVError.invalidUTF8
        }
        var scanner = PromptCSVScanner(source: source)
        guard let headers = scanner.nextRecord() else { throw PromptCSVError.emptyFile }
        let indexes = Dictionary(uniqueKeysWithValues: headers.enumerated().map {
            ($0.element.trimmingCharacters(in: .whitespacesAndNewlines), $0.offset)
        })

        var prompts: [AgentPrompt] = []
        var rowCount = 0
        while rowCount < maximumRows, let values = scanner.nextRecord() {
            rowCount += 1
            guard values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  let prompt = prompt(values: values, indexes: indexes) else {
                continue
            }
            prompts.append(prompt)
        }
        return prompts
    }

    /** Converts one tolerant CSV row into an Android-compatible prompt. */
    private static func prompt(values: [String], indexes: [String: Int]) -> AgentPrompt? {
        func value(_ key: String) -> String? {
            guard let index = indexes[key], values.indices.contains(index) else { return nil }
            return values[index]
        }
        guard let name = value("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let template = value("promptTemplate"),
              !template.isEmpty else {
            return nil
        }

        let id = value("id").flatMap(UUID.init(uuidString:)) ?? UUID()
        let contexts = Set((value("showIn") ?? "").split(separator: ",").compactMap {
            PromptContext(rawValue: String($0).trimmingCharacters(in: .whitespacesAndNewlines))
        })
        let allowed = optionalToolSet(value("allowedTools"))
        let denied = optionalToolSet(value("deniedTools"))
        let createdAt = value("createdAt").flatMap(isoDateFormatter.date(from:))
            .map { Int64($0.timeIntervalSince1970 * 1_000) }
            ?? Int64(Date().timeIntervalSince1970 * 1_000)

        return AgentPrompt(
            id: id,
            name: name,
            description: value("description").flatMap { $0.isEmpty ? nil : $0 },
            promptTemplate: template,
            showIn: contexts,
            orderNumber: Int(value("orderNumber") ?? "") ?? 0,
            createdAtMilliseconds: createdAt,
            strictContextMatching: strictBoolean(value("strictContextMatching")) ?? true,
            permissionMode: value("permissionMode").flatMap(AIPermissionMode.init(rawValue:)),
            allowedTools: allowed,
            deniedTools: denied,
            configuredModelId: value("configuredModelId").flatMap(UUID.init(uuidString:)),
            bibleOnly: strictBoolean(value("bibleOnly")) ?? false
        )
    }

    /** Decodes Android's nullable comma-delimited tool sets. */
    private static func optionalToolSet(_ rawValue: String?) -> Set<AgentTool>? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        return Set(rawValue.split(separator: ",").compactMap {
            AgentTool(rawValue: String($0).trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    /** Accepts only Kotlin's strict case-insensitive boolean spellings. */
    private static func strictBoolean(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// UTC formatter matching Android prompt CSV timestamps.
    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/** Stateful scanner for semicolon CSV records with escaped quotes and embedded newlines. */
private struct PromptCSVScanner {
    /// Complete decoded source.
    private let characters: [Character]

    /// Current source offset.
    private var index = 0

    /** Creates a scanner over a decoded prompt-pack string. */
    init(source: String) {
        characters = Array(source)
    }

    /** Returns the next logical record, or `nil` after all source characters are consumed. */
    mutating func nextRecord() -> [String]? {
        guard index < characters.count else { return nil }
        var fields: [String] = []
        var field = ""
        var quoted = false

        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\"" {
                if quoted, index < characters.count, characters[index] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    quoted.toggle()
                }
            } else if character == ";", !quoted {
                fields.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"), !quoted {
                if character == "\r", index < characters.count, characters[index] == "\n" {
                    index += 1
                }
                fields.append(field)
                return fields
            } else {
                field.append(character)
            }
        }
        fields.append(field)
        return fields
    }
}

/**
 Code-owned Android production prompt catalog with UUID-v3 identities.

 IDs are generated from UTF-8 `andbible-builtin:<key>` exactly as Java
 `UUID.nameUUIDFromBytes`, including RFC 4122 version and variant bits.
 */
public enum BuiltInPromptCatalog {
    /// Study-category identity.
    public static let studyCategoryID = id(forKey: "category-study")
    /// Notes-category identity.
    public static let notesCategoryID = id(forKey: "category-notes")
    /// General-category identity.
    public static let generalCategoryID = id(forKey: "category-general")

    /// Android production prompt keys in display order.
    public static let productionKeys = [
        "translate-ui-language",
        "summary",
        "explain-verses",
        "explain-verses-studypad",
        "word-study",
        "cross-references",
        "compare-translations",
        "thematic-study",
        "bookmark-annotate",
        "study-layout",
        "workspace-assistant",
        "enhance-note",
        "ask-question",
        "custom-prompt",
    ]

    /**
     Generates Java-compatible UUID v3 for one built-in key.

     - Parameter key: Stable catalog key without the namespace prefix.
     - Returns: Deterministic RFC 4122 version-3 UUID.
     - Side effects: none.
     - Failure modes: none for UTF-8 Swift strings.
     */
    public static func id(forKey key: String) -> UUID {
        var bytes = Array(Insecure.MD5.hash(data: Data("andbible-builtin:\(key)".utf8)))
        bytes[6] = (bytes[6] & 0x0f) | 0x30
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /** Returns the three Android production categories as detached values. */
    public static func categories() -> [PromptCategory] {
        [
            PromptCategory(
                id: studyCategoryID,
                name: String(localized: "prompt_category_study", defaultValue: "Study"),
                orderNumber: 0
            ),
            PromptCategory(
                id: notesCategoryID,
                name: String(localized: "prompt_category_notes", defaultValue: "Notes"),
                orderNumber: 1
            ),
            PromptCategory(
                id: generalCategoryID,
                name: String(localized: "prompt_category_general", defaultValue: "General"),
                orderNumber: 2
            ),
        ]
    }

    /**
     Builds Android's production prompts with language-dependent translation text.

     - Parameter responseLanguageName: Display language inserted into the translation prompt.
     - Returns: Fresh unmanaged prompt values in Android display order.
     - Side effects: none.
     */
    public static func productionPrompts(responseLanguageName: String = "the user's UI language") -> [AgentPrompt] {
        let bibleRead: Set<AgentTool> = [
            .getVerseContent, .searchBible, .getCommentaries, .getInstalledDocuments,
        ]
        let bibleStudy = bibleRead.union([.searchByStrongs, .getDictionaryEntry])

        func denied(except allowed: Set<AgentTool>) -> Set<AgentTool> {
            Set(AgentTool.allCases).subtracting(allowed).subtracting(structuralTools)
        }
        func prompt(
            _ key: String,
            _ name: String,
            _ description: String,
            _ template: String,
            contexts: Set<PromptContext>,
            category: UUID,
            strict: Bool = true,
            mode: AIPermissionMode? = nil,
            allowed: Set<AgentTool>? = nil,
            bibleOnly: Bool = false,
            specify: Bool = false,
            noDocument: Bool = false,
            includeDocuments: Bool = false,
            includeCommentaries: Bool = false,
            transformation: Bool = false
        ) -> AgentPrompt {
            let index = productionKeys.firstIndex(of: key) ?? 0
            return AgentPrompt(
                id: id(forKey: key),
                name: name,
                description: description,
                promptTemplate: template,
                showIn: contexts,
                orderNumber: index,
                createdAtMilliseconds: 0,
                strictContextMatching: strict,
                permissionMode: mode,
                allowedTools: allowed,
                deniedTools: allowed.map { denied(except: $0) },
                specifyBeforeRun: specify,
                noDocumentCreation: noDocument,
                autoIncludeDocuments: includeDocuments,
                autoIncludeCommentaries: includeCommentaries,
                bibleOnly: bibleOnly,
                isTextTransformation: transformation,
                categoryId: category
            )
        }

        return [
            prompt(
                "translate-ui-language",
                String(
                    format: String(
                        localized: "default_prompt_translate_to_language",
                        defaultValue: "Translate to %@"
                    ),
                    responseLanguageName
                ),
                String(
                    localized: "default_prompt_translate_to_ui_language_desc",
                    defaultValue: "Translates document text to the app interface language"
                ),
                """
                Translate the selected text to \(responseLanguageName).
                If the user has highlighted or selected a specific portion, translate ONLY that portion.
                Aim for accuracy over literary style.
                Do not add explanations or commentary.
                Output only the translated text.
                """,
                contexts: [.verseSelection, .windowMenu], category: generalCategoryID,
                transformation: true
            ),
            prompt(
                "summary",
                String(localized: "default_prompt_summary", defaultValue: "Summary"),
                String(
                    localized: "default_prompt_summary_desc",
                    defaultValue: "Creates a concise summary of the selected text"
                ),
                """
                Create a concise summary of the selected passage.
                If the user has highlighted or selected a specific portion, focus your summary on that portion.

                Structure your summary as:
                1. **Context** — Brief historical/literary context (1-2 sentences)
                2. **Main Points** — Key themes and teachings (bullet points)
                3. **Significance** — Why this passage matters (1-2 sentences)

                Keep the total length to 150-300 words.
                """,
                contexts: [.verseSelection, .windowMenu], category: generalCategoryID,
                allowed: []
            ),
            prompt(
                "explain-verses",
                String(localized: "default_prompt_explain_verses", defaultValue: "Explain verses"),
                String(
                    localized: "default_prompt_explain_verses_desc",
                    defaultValue: "Explains the meaning and context of selected verses"
                ),
                """
                Explain the meaning and context of the selected verses.

                APPROACH:
                Installed documents and commentaries for the selected verses are provided below.
                Synthesize the commentary perspectives into a clear explanation.
                If Strong's dictionaries are available, use getDictionaryEntry for key theological terms.

                STRUCTURE your explanation:
                - **Historical Context** — Who wrote this, to whom, and when
                - **Verse-by-Verse Explanation** — Walk through the passage
                - **Key Themes** — Major theological themes
                - **Application** — How this applies today

                Base your explanation on the provided commentaries. Cite each source by name.
                Do not invent interpretations — ground everything in the available reference works.
                """,
                contexts: [.verseSelection, .windowMenu], category: studyCategoryID,
                allowed: bibleStudy, bibleOnly: true, includeDocuments: true,
                includeCommentaries: true
            ),
            prompt(
                "explain-verses-studypad",
                String(
                    localized: "default_prompt_explain_verses_studypad",
                    defaultValue: "Explain verses → Study Pad"
                ),
                String(
                    localized: "default_prompt_explain_verses_studypad_desc",
                    defaultValue: "Create a Study Pad with verse-by-verse explanation and bookmarks"
                ),
                """
                Explain the selected verses and create a StudyPad with the explanation.

                APPROACH:
                Installed documents and commentaries for the selected verses are provided below.
                If Strong's dictionaries are available, use getDictionaryEntry for key theological terms.
                Build a StudyPad using createStudyPad with these items in order:
                   - A text entry with historical context (who wrote this, to whom, when)
                   - For each verse or small group of verses:
                     a. A bookmark to the verse(s)
                     b. A text entry explaining that verse, citing commentaries by name
                   - A text entry summarizing key themes
                   - A text entry with application for today
                5. Call finishWithStudyPad with the returned labelId to open it.

                Base your explanation on the provided commentaries.
                Do not invent interpretations — ground everything in the available reference works.
                """,
                contexts: [.verseSelection, .windowMenu], category: studyCategoryID,
                strict: false, mode: .askOncePerRun, allowed: bibleStudy.union([.createStudyPad]),
                bibleOnly: true, includeDocuments: true, includeCommentaries: true
            ),
            prompt(
                "word-study",
                String(localized: "default_prompt_word_study", defaultValue: "Word study"),
                String(
                    localized: "default_prompt_word_study_desc",
                    defaultValue: "Analyzes original Hebrew/Greek words"
                ),
                """
                Perform a word study on the original Hebrew/Greek words in the selected text.

                APPROACH:
                Installed documents are provided below.
                1. Use getVerseContent with osis=true to retrieve text with Strong's markup.
                3. For each key word, use getDictionaryEntry to look up its Strong's number.
                4. Use searchByStrongs to find other passages where the same word appears.

                STRUCTURE your study per key word (3-5 words max):
                - **Original word** — Hebrew/Greek form, transliteration, Strong's number with link [Strong's GXXXX](strongs://GXXXX)
                - **Definition** — Full dictionary definition (cite the source by name)
                - **Usage in this passage** — How the word functions here
                - **Other occurrences** — 3-5 notable passages using this word (with links)
                - **Theological significance** — Key insights

                Focus on the most theologically significant words.
                """,
                contexts: [.verseSelection, .textSelection, .windowMenu], category: studyCategoryID,
                strict: false, allowed: bibleStudy, bibleOnly: true, includeDocuments: true
            ),
            prompt(
                "cross-references",
                String(localized: "default_prompt_cross_references", defaultValue: "Cross-references"),
                String(
                    localized: "default_prompt_cross_references_desc",
                    defaultValue: "Finds and explains related Bible passages"
                ),
                """
                Find and explain cross-references for the selected verses.

                APPROACH:
                Commentaries for the selected verses are provided below.
                1. Use searchBible to find passages with shared keywords and themes.
                2. Check the provided commentaries for passages they mention as related.

                GROUP cross-references by connection type:
                - **Direct Quotes/Allusions** — Where this passage quotes or echoes another
                - **Parallel Passages** — Similar accounts or teachings elsewhere
                - **Thematic Connections** — Passages sharing the same theme
                - **Fulfillment/Prophecy** — Prophetic connections

                For each cross-reference, provide a clickable link and a brief explanation (1-2 sentences).
                Aim for 8-15 cross-references, prioritizing the most significant connections.
                """,
                contexts: [.verseSelection, .windowMenu], category: studyCategoryID,
                strict: false, allowed: bibleRead, bibleOnly: true, includeCommentaries: true
            ),
            prompt(
                "compare-translations",
                String(
                    localized: "default_prompt_compare_translations",
                    defaultValue: "Compare translations"
                ),
                String(
                    localized: "default_prompt_compare_translations_desc",
                    defaultValue: "Shows how different installed translations render the text"
                ),
                """
                Compare how different Bible translations render the selected verses.

                APPROACH:
                Installed documents are provided below.
                1. Use getVerseContent to retrieve the selected passage from each installed Bible translation.
                3. Compare the translations side by side.

                STRUCTURE:
                - List each translation's rendering with the translation name as a heading.
                - After listing all translations, provide a **Key Differences** section highlighting:
                  - Significant wording differences and what they mean
                  - Where translations disagree on meaning (not just style)
                  - Which textual traditions or manuscripts may explain differences

                If Strong's dictionaries are available, reference the original language
                where it helps explain why translations differ.
                Do not editorialize about which translation is "better."
                """,
                contexts: [.verseSelection, .windowMenu], category: studyCategoryID,
                strict: false,
                allowed: [.getVerseContent, .getInstalledDocuments, .getDictionaryEntry, .searchBible],
                bibleOnly: true, includeDocuments: true
            ),
            prompt(
                "thematic-study",
                String(localized: "default_prompt_thematic_study", defaultValue: "Thematic study"),
                String(
                    localized: "default_prompt_thematic_study_desc",
                    defaultValue: "Builds a StudyPad with passages and notes on the central theme"
                ),
                """
                Build a thematic study based on the selected passage.

                APPROACH:
                1. Identify the primary theme (e.g., "God's faithfulness", "prayer", "forgiveness").
                2. Identify 8-12 passages related to this theme using your Bible knowledge.
                   You may use searchBible to supplement, but for thematic connections your own
                   knowledge of Scripture is usually more effective than keyword search.
                   If you do search, use the indexed Bible's language (see system context).
                3. Use getVerseContent to retrieve each passage from the active document.
                4. Use the provided commentaries (included below) to add depth to 2-3 key passages.
                5. Build a StudyPad using createStudyPad with a descriptive name
                   (e.g., "Thematic Study: God's Faithfulness") and items:
                   - A text entry with an introduction to the theme
                   - For each key passage: a bookmark with a note explaining its relevance
                   - A text entry with concluding thoughts
                6. Call finishWithStudyPad with the returned labelId to open it.

                Organize passages in a logical progression (e.g., Old Testament → New Testament).
                Include 8-12 passages total.
                """,
                contexts: [.verseSelection, .windowMenu], category: studyCategoryID,
                strict: false, mode: .askOncePerRun,
                allowed: bibleRead.union([.createStudyPad, .getAllLabels, .getBookmarksForVerse]),
                bibleOnly: true, includeDocuments: true, includeCommentaries: true
            ),
            prompt(
                "bookmark-annotate",
                String(
                    localized: "default_prompt_bookmark_annotate",
                    defaultValue: "Bookmark & annotate"
                ),
                String(
                    localized: "default_prompt_bookmark_annotate_desc",
                    defaultValue: "Creates a bookmark with an AI-generated study note"
                ),
                """
                Create a bookmark for the selected verses and add a study note.

                APPROACH:
                Commentaries for the selected verses are provided below (if available).
                1. Create a bookmark using createBookmark for the selected verses.
                3. Write a concise study note (3-5 sentences) covering:
                   - What this passage is about
                   - Key insight or takeaway
                   - A related cross-reference
                4. Use addBookmarkNote to attach the note to the bookmark.
                5. Call finishWithoutDocument with a confirmation message.

                Keep the note concise and useful for future reference.
                """,
                contexts: [.verseSelection, .windowMenu], category: notesCategoryID,
                mode: .askOncePerRun,
                allowed: [.getVerseContent, .getCommentaries, .getInstalledDocuments,
                          .createBookmark, .addBookmarkNote, .getBookmarksForVerse],
                bibleOnly: true, noDocument: true, includeDocuments: true,
                includeCommentaries: true
            ),
            prompt(
                "study-layout",
                String(localized: "default_prompt_study_layout", defaultValue: "Open study layout"),
                String(
                    localized: "default_prompt_study_layout_desc",
                    defaultValue: "Opens commentary and parallel translation windows for study"
                ),
                """
                Set up a multi-window study layout for the selected passage.

                APPROACH:
                1. Use getInstalledDocuments to find available Bibles, commentaries, and dictionaries.
                2. Use getWindows to see the current window layout.
                3. Set up an optimal study layout:
                   a. Ensure the current window shows the selected passage.
                   b. If a commentary is installed, use createWindow to open a commentary window on the same passage.
                   c. If another Bible translation is installed, use createWindow to open a parallel translation window.
                4. Call finishWithoutDocument confirming what layout was created.

                Create at most 3 windows total (including existing ones) to avoid cluttering the screen.
                Prefer: 1 Bible + 1 Commentary, or 2 Bibles + 1 Commentary.
                """,
                contexts: [.verseSelection, .windowMenu, .workspaceMenu], category: notesCategoryID,
                mode: .askOncePerRun,
                allowed: [.getInstalledDocuments, .getWindows, .getVerseContent, .createWindow,
                          .manageWindow, .setWindowDocument],
                noDocument: true, includeDocuments: true
            ),
            prompt(
                "workspace-assistant",
                String(
                    localized: "default_prompt_workspace_assistant",
                    defaultValue: "Workspace assistant"
                ),
                String(
                    localized: "default_prompt_workspace_assistant_desc",
                    defaultValue: "Manage windows: create, close, rearrange, change documents"
                ),
                """
                Help the user manage their workspace windows.
                The current workspace layout is provided in the system prompt.

                You can:
                - Rearrange, create, close, or minimize windows
                - Change documents shown in windows
                - Set up study layouts with multiple translations and commentaries

                User will tell you what they'd like to do.
                Use getWindows and getInstalledDocuments to understand the current state,
                then use createWindow, manageWindow, and setWindowDocument as needed.
                When done, call finishWithoutDocument with a summary of changes made.
                """,
                contexts: [.workspaceMenu], category: generalCategoryID,
                mode: .askOncePerRun,
                allowed: [.getInstalledDocuments, .getWindows, .getVerseContent, .createWindow,
                          .manageWindow, .setWindowDocument],
                specify: true, noDocument: true, includeDocuments: true
            ),
            prompt(
                "enhance-note",
                String(localized: "default_prompt_enhance_note", defaultValue: "Enhance note"),
                String(
                    localized: "default_prompt_enhance_note_desc",
                    defaultValue: "Improves grammar, clarity, and readability of your note"
                ),
                """
                Improve the language and clarity of the user's note.

                APPROACH:
                - Fix grammar, spelling, and punctuation errors
                - Improve sentence structure and readability
                - Make the writing more concise where appropriate
                - Preserve the original meaning and intent

                IMPORTANT: Preserve the user's original thoughts, voice, and content.
                Only improve the language — do not add new content, commentary, or cross-references.
                """,
                contexts: [.noteEditor], category: notesCategoryID,
                transformation: true
            ),
            prompt(
                "ask-question",
                String(localized: "default_prompt_ask_question", defaultValue: "Ask a question"),
                String(
                    localized: "default_prompt_ask_question_desc",
                    defaultValue: "Ask any question about the selected passage"
                ),
                """
                Answer the user's question about the selected passage.
                Commentaries and installed documents are provided below.
                Use them to provide a well-sourced answer.
                Cite your sources and include clickable Bible reference links.
                """,
                contexts: [.verseSelection, .windowMenu], category: generalCategoryID,
                allowed: bibleStudy, specify: true, includeDocuments: true,
                includeCommentaries: true
            ),
            prompt(
                "custom-prompt",
                String(localized: "default_prompt_custom", defaultValue: "Custom prompt"),
                String(
                    localized: "default_prompt_custom_desc",
                    defaultValue: "Run a custom task on the selected passage"
                ),
                String(
                    localized: "default_prompt_custom_template",
                    defaultValue: "Follow the user's task specification for the selected Bible passage."
                ),
                contexts: [.verseSelection, .windowMenu], category: generalCategoryID,
                specify: true
            ),
        ]
    }

    /// Structural tools that remain available even when a prompt denies every ordinary tool.
    public static let structuralTools: Set<AgentTool> = [
        .setDocumentTitle, .finishWithStudyPad, .finishWithMyDocumentPage, .finishWithoutDocument,
    ]

    /** Returns whether an identity belongs to a production built-in prompt. */
    public static func contains(id: UUID) -> Bool {
        productionKeys.contains { self.id(forKey: $0) == id }
    }
}

/** Errors raised when a caller attempts to mutate code-owned prompt state. */
public enum PromptRepositoryError: Error, Equatable, Sendable {
    /// Built-in and SWORD prompts are immutable; callers must copy before editing.
    case readOnlyPrompt(UUID)

    /// A source prompt could not be found.
    case promptNotFound(UUID)

    /// A built-in or user category could not be found.
    case categoryNotFound(UUID)
}

/**
 Resolves prompts with Android precedence: built-in, then SWORD pack, then user SwiftData.

 Persisted model overrides are merged into built-in and SWORD add-on prompts before values leave
 the repository. Hidden built-ins are removed only from list APIs; direct identity lookup still
 resolves them, matching Android.
 */
@MainActor
public final class PromptRepository {
    /// Persisted user settings and overrides.
    private let settingsStore: AISettingsStore

    /// Code-owned catalog builder.
    private let builtInPrompts: () -> [AgentPrompt]

    /// Prompt-pack source; `nil` disables add-on discovery.
    private let packProvider: SwordPromptPackProviding?

    /**
     Creates a prompt repository with injectable catalog and pack discovery.

     - Parameters:
       - settingsStore: SwiftData AI settings store.
       - packProvider: Optional SWORD prompt-pack provider.
       - builtInPrompts: Fresh built-in value builder.
     - Side effects: none until a query loads SwiftData or prompt-pack files.
     */
    public init(
        settingsStore: AISettingsStore,
        packProvider: SwordPromptPackProviding? = nil,
        builtInPrompts: @escaping () -> [AgentPrompt] = {
            BuiltInPromptCatalog.productionPrompts()
        }
    ) {
        self.settingsStore = settingsStore
        self.packProvider = packProvider
        self.builtInPrompts = builtInPrompts
    }

    /**
     Resolves one prompt using Android source precedence.

     - Parameter id: Stable prompt identity.
     - Returns: Effective prompt and origin, or `nil`.
     - Side effects: Reads SwiftData and may load SWORD CSV files.
     - Throws: SwiftData or prompt-pack discovery errors.
     */
    public func entryById(_ id: UUID) throws -> ResolvedAgentPrompt? {
        if let builtIn = builtInPrompts().first(where: { $0.id == id }) {
            return ResolvedAgentPrompt(prompt: try applyOverride(to: builtIn), origin: .builtIn)
        }
        for pack in try packProvider?.loadPromptPacks() ?? [] {
            if let prompt = pack.prompts.first(where: { $0.id == id }) {
                return ResolvedAgentPrompt(
                    prompt: try applyOverride(to: prompt),
                    origin: .swordPack(moduleName: pack.moduleName)
                )
            }
        }
        return try settingsStore.userPrompt(id: id).map {
            ResolvedAgentPrompt(
                prompt: $0.detachedCopy(configuredModelId: $0.configuredModelId),
                origin: .user
            )
        }
    }

    /** Returns only the effective prompt value for an identity. */
    public func promptById(_ id: UUID) throws -> AgentPrompt? {
        try entryById(id)?.prompt
    }

    /**
     Returns visible prompts in Android source and source-file order.

     Hidden built-ins are excluded. Add-on and user prompts remain visible because Android's hidden
     set applies only to built-in identities.
     */
    public func allPrompts() throws -> [ResolvedAgentPrompt] {
        let hidden = try settingsStore.globalSettings().hiddenBuiltInPrompts
        return try allPromptsIncludingHidden().filter {
            $0.origin != .builtIn || !hidden.contains($0.prompt.id)
        }
    }

    /**
     Returns every effective prompt, including hidden built-ins, in Android source order.

     This is the settings-screen listing API. Built-in overrides are applied, while SWORD and user
     ownership metadata remains available so callers can expose copy versus edit operations.
     */
    public func allPromptsIncludingHidden() throws -> [ResolvedAgentPrompt] {
        let builtIns = try builtInPrompts().map {
            ResolvedAgentPrompt(prompt: try applyOverride(to: $0), origin: .builtIn)
        }
        let packs = try (packProvider?.loadPromptPacks() ?? []).flatMap { pack in
            try pack.prompts.map {
                ResolvedAgentPrompt(
                    prompt: try applyOverride(to: $0),
                    origin: .swordPack(moduleName: pack.moduleName)
                )
            }
        }
        let users = try settingsStore.userPrompts().map {
            ResolvedAgentPrompt(
                prompt: $0.detachedCopy(configuredModelId: $0.configuredModelId),
                origin: .user
            )
        }
        return builtIns + packs + users
    }

    /**
     Returns built-in then user categories in Android display order.

     - Returns: Fresh code-owned category values followed by managed user rows.
     - Side effects: Reads SwiftData user categories.
     - Throws: SwiftData fetch errors.
     */
    public func allCategories() throws -> [PromptCategory] {
        BuiltInPromptCatalog.categories() + (try settingsStore.userCategories())
    }

    /**
     Resolves a category with built-in precedence over a colliding user identity.

     - Parameter id: Stable category identity.
     - Returns: Code-owned or managed category, or `nil`.
     - Side effects: Reads SwiftData only when no built-in matches.
     - Throws: SwiftData fetch errors.
     */
    public func categoryById(_ id: UUID) throws -> PromptCategory? {
        if let builtIn = BuiltInPromptCatalog.categories().first(where: { $0.id == id }) {
            return builtIn
        }
        return try settingsStore.userCategory(id: id)
    }

    /**
     Returns Android's combined row-level and global built-in-category hidden state.

     - Parameter category: Effective category to inspect.
     - Returns: `true` when either persisted mechanism hides the category.
     - Side effects: Reads singleton SwiftData settings unless the row itself is hidden.
     - Throws: SwiftData fetch or first-use singleton-save errors.
     */
    public func isCategoryHidden(_ category: PromptCategory) throws -> Bool {
        if category.hidden { return true }
        return try settingsStore.globalSettings().hiddenBuiltInCategories.contains(category.id)
    }

    /**
     Idempotently changes whether a built-in prompt is hidden from action lists.

     - Parameters:
       - hidden: Desired hidden state.
       - promptID: Stable production built-in identity.
     - Side effects: Mutates and saves synced singleton settings.
     - Throws: Missing-prompt or SwiftData errors.
     */
    public func setBuiltInPromptHidden(_ hidden: Bool, promptID: UUID) throws {
        guard BuiltInPromptCatalog.contains(id: promptID) else {
            throw PromptRepositoryError.promptNotFound(promptID)
        }
        let settings = try settingsStore.globalSettings()
        if hidden {
            settings.hiddenBuiltInPrompts.insert(promptID)
        } else {
            settings.hiddenBuiltInPrompts.remove(promptID)
        }
        try settingsStore.save()
    }

    /**
     Idempotently changes whether a built-in category is hidden from action lists.

     - Parameters:
       - hidden: Desired hidden state.
       - categoryID: Stable production built-in category identity.
     - Side effects: Mutates and saves synced singleton settings.
     - Throws: Missing-category or SwiftData errors.
     */
    public func setBuiltInCategoryHidden(_ hidden: Bool, categoryID: UUID) throws {
        guard BuiltInPromptCatalog.categories().contains(where: { $0.id == categoryID }) else {
            throw PromptRepositoryError.categoryNotFound(categoryID)
        }
        let settings = try settingsStore.globalSettings()
        if hidden {
            settings.hiddenBuiltInCategories.insert(categoryID)
        } else {
            settings.hiddenBuiltInCategories.remove(categoryID)
        }
        try settingsStore.save()
    }

    /**
     Returns the current synced favorite prompt identities.

     - Returns: Stable identities, including temporarily unavailable add-on prompts.
     - Side effects: Reads or creates singleton SwiftData settings.
     - Throws: SwiftData fetch or first-use save errors.
     */
    public func favoritePromptIDs() throws -> Set<UUID> {
        try settingsStore.globalSettings().favoritePrompts
    }

    /**
     Idempotently changes one prompt's synced favorite state.

     - Parameters:
       - favorite: Desired favorite state.
       - promptID: Effective built-in, SWORD, or user prompt identity.
     - Side effects: May read prompt packs, then mutates and saves synced singleton settings.
     - Throws: Missing-prompt, prompt-pack, or SwiftData errors.
     */
    public func setFavorite(_ favorite: Bool, promptID: UUID) throws {
        guard try entryById(promptID) != nil else {
            throw PromptRepositoryError.promptNotFound(promptID)
        }
        let settings = try settingsStore.globalSettings()
        if favorite {
            settings.favoritePrompts.insert(promptID)
        } else {
            settings.favoritePrompts.remove(promptID)
        }
        try settingsStore.save()
    }

    /** Returns visible prompts for one UI context and optional Bible-only filter. */
    public func prompts(for context: PromptContext, documentIsBible: Bool? = nil) throws
        -> [ResolvedAgentPrompt] {
        try allPrompts().filter {
            $0.prompt.showIn.contains(context)
                && (documentIsBible == nil || !$0.prompt.bibleOnly || documentIsBible == true)
        }
    }

    /** Returns whether a prompt is code- or module-owned and therefore read-only. */
    public func isReadOnly(id: UUID) throws -> Bool {
        guard let entry = try entryById(id) else { return false }
        return entry.origin != .user
    }

    /**
     Inserts a user prompt after rejecting built-in and add-on identity collisions.

     - Throws: `PromptRepositoryError.readOnlyPrompt` or SwiftData errors.
     */
    public func insert(_ prompt: AgentPrompt) throws {
        if let existing = try entryById(prompt.id), existing.origin != .user {
            throw PromptRepositoryError.readOnlyPrompt(prompt.id)
        }
        try settingsStore.insertPrompt(prompt)
    }

    /**
     Replaces every editable field of an existing user prompt from a detached value.

     - Parameter prompt: Detached user prompt carrying the same stable identity.
     - Side effects: Mutates and saves one SwiftData prompt row.
     - Throws: Read-only, missing-prompt, or SwiftData errors.
     */
    public func update(_ prompt: AgentPrompt) throws {
        guard let entry = try entryById(prompt.id) else {
            throw PromptRepositoryError.promptNotFound(prompt.id)
        }
        guard entry.origin == .user,
              let managed = try settingsStore.userPrompt(id: prompt.id) else {
            throw PromptRepositoryError.readOnlyPrompt(prompt.id)
        }
        managed.name = prompt.name
        managed.promptDescription = prompt.promptDescription
        managed.promptTemplate = prompt.promptTemplate
        managed.showIn = prompt.showIn
        managed.orderNumber = prompt.orderNumber
        managed.createdAtMilliseconds = prompt.createdAtMilliseconds
        managed.strictContextMatching = prompt.strictContextMatching
        managed.permissionMode = prompt.permissionMode
        managed.allowedTools = prompt.allowedTools
        managed.deniedTools = prompt.deniedTools
        managed.configuredModelId = prompt.configuredModelId
        managed.specifyBeforeRun = prompt.specifyBeforeRun
        managed.noDocumentCreation = prompt.noDocumentCreation
        managed.maxIterations = prompt.maxIterations
        managed.autoIncludeDocuments = prompt.autoIncludeDocuments
        managed.autoIncludeCommentaries = prompt.autoIncludeCommentaries
        managed.bibleOnly = prompt.bibleOnly
        managed.isTextTransformation = prompt.isTextTransformation
        managed.categoryId = prompt.categoryId
        try settingsStore.save()
    }

    /**
     Copies any effective prompt into a new editable user prompt.

     - Parameters:
       - id: Built-in, SWORD, or user prompt identity to copy.
       - name: Optional replacement display name.
     - Returns: Inserted managed user prompt with a fresh identity and creation time.
     - Side effects: Loads prompt packs when needed and inserts one SwiftData row.
     - Throws: Missing-prompt, prompt-pack, or SwiftData errors.
     */
    @discardableResult
    public func copy(id: UUID, name: String? = nil) throws -> AgentPrompt {
        guard let entry = try entryById(id) else {
            throw PromptRepositoryError.promptNotFound(id)
        }
        let copy = entry.prompt.detachedCopy()
        copy.id = UUID()
        copy.name = name ?? "\(copy.name) (copy)"
        copy.createdAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        copy.orderNumber = entry.prompt.orderNumber + 1
        for userPrompt in try settingsStore.userPrompts()
        where userPrompt.orderNumber > entry.prompt.orderNumber {
            userPrompt.orderNumber += 1
        }
        try settingsStore.insertPrompt(copy)
        return copy
    }

    /**
     Sets an effective prompt's configured model through its source-appropriate persistence path.

     Built-ins and SWORD add-on prompts use the synced override row because their source content is
     immutable; user prompts mutate their managed row. This preserves Android's run-dialog ability
     to remember a model for an add-on without attempting to update a non-existent Room prompt row.
     */
    public func setConfiguredModel(promptID: UUID, modelID: UUID?) throws {
        guard let entry = try entryById(promptID) else {
            throw PromptRepositoryError.promptNotFound(promptID)
        }
        if let modelID, try settingsStore.model(id: modelID) == nil {
            throw AISettingsStoreError.modelNotFound(modelID)
        }
        switch entry.origin {
        case .builtIn, .swordPack:
            try settingsStore.setBuiltInModelOverride(promptID: promptID, modelID: modelID)
        case .user:
            guard let managed = try settingsStore.userPrompt(id: promptID) else {
                throw PromptRepositoryError.promptNotFound(promptID)
            }
            managed.configuredModelId = modelID
            try settingsStore.save()
        }
    }

    /** Deletes an editable prompt and rejects built-in or SWORD pack identities. */
    public func delete(id: UUID) throws {
        guard let entry = try entryById(id) else {
            throw PromptRepositoryError.promptNotFound(id)
        }
        guard entry.origin == .user, let managed = try settingsStore.userPrompt(id: id) else {
            throw PromptRepositoryError.readOnlyPrompt(id)
        }
        try settingsStore.deletePrompt(managed)
    }

    /** Applies the synced immutable-prompt model override to a detached catalog or add-on prompt. */
    private func applyOverride(to prompt: AgentPrompt) throws -> AgentPrompt {
        let override = try settingsStore.builtInOverride(id: prompt.id)
        let modelID = override == nil ? prompt.configuredModelId : override?.configuredModelId
        return prompt.detachedCopy(configuredModelId: modelID)
    }
}
