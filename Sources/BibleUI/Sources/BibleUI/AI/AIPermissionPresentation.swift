// AIPermissionPresentation.swift -- Android agent-tool labels and grouping

import BibleCore
import Foundation

/** Stable localized titles and grouping shared by Android-parity permission UI and run dialogs. */
enum AIPermissionPresentation {
    /// Agent-flow controls that Android keeps available but never exposes as user permissions.
    static let structuralTools: Set<AgentTool> = [
        .setDocumentTitle,
        .finishWithStudyPad,
        .finishWithMyDocumentPage,
        .finishWithoutDocument,
    ]

    /** One Android tool-category section. */
    struct CategoryGroup {
        let category: AgentTool.Category
        let title: String
        let tools: [AgentTool]
    }

    /// All Android categories in production display order.
    static var categories: [CategoryGroup] {
        let definitions: [(AgentTool.Category, String)] = [
            (.bibleSearch, String(localized: "tool_category_bible_search", defaultValue: "Bible & Search")),
            (.bookmarks, String(localized: "tool_category_bookmarks", defaultValue: "Bookmarks")),
            (.labels, String(localized: "tool_category_labels", defaultValue: "Labels")),
            (.studyPads, String(localized: "tool_category_study_pads", defaultValue: "Study Pads")),
            (.myDocuments, String(localized: "tool_category_my_documents", defaultValue: "My Documents")),
            (.generalBooks, String(localized: "tool_category_general_books", defaultValue: "General Books")),
            (.windows, String(localized: "tool_category_windows", defaultValue: "Windows")),
        ]
        return definitions.map { category, title in
            CategoryGroup(
                category: category,
                title: title,
                tools: AgentTool.allCases.filter {
                    $0.category == category && !structuralTools.contains($0)
                }
            )
        }
    }

    /** Returns Android's localized label for one permission mode. */
    static func title(for mode: AIPermissionMode) -> String {
        switch mode {
        case .alwaysAsk:
            return String(localized: "permission_always_ask", defaultValue: "Always ask")
        case .askOncePerRun:
            return String(localized: "permission_ask_once_per_run", defaultValue: "Ask once per run")
        case .allowAll:
            return String(localized: "permission_allow_all", defaultValue: "Allow all")
        case .denyAll:
            return String(localized: "permission_deny_all", defaultValue: "Deny all")
        }
    }

    /** Returns Android's localized display name for one agent tool. */
    static func title(for tool: AgentTool) -> String {
        switch tool {
        case .getVerseContent:
            return String(localized: "tool_get_verse_content", defaultValue: "Read verse content")
        case .searchBible:
            return String(localized: "tool_search_bible", defaultValue: "Search Bible")
        case .searchByStrongs:
            return String(localized: "tool_search_by_strongs", defaultValue: "Search by Strong's number")
        case .getCommentaries:
            return String(localized: "tool_get_commentaries", defaultValue: "Read commentaries")
        case .getDictionaryEntry:
            return String(localized: "tool_get_dictionary_entry", defaultValue: "Look up dictionary entry")
        case .getBookmarksForVerse:
            return String(localized: "tool_get_bookmarks_for_verse", defaultValue: "Get bookmarks for verse")
        case .getBookmarksWithLabel:
            return String(localized: "tool_get_bookmarks_with_label", defaultValue: "Get bookmarks with label")
        case .getAllLabels:
            return String(localized: "tool_get_all_labels", defaultValue: "List all labels")
        case .getStudyPadContent:
            return String(localized: "tool_get_study_pad_content", defaultValue: "Read study pad content")
        case .searchStudyPads:
            return String(localized: "tool_search_study_pads", defaultValue: "Search study pads")
        case .getInstalledDocuments:
            return String(localized: "tool_get_installed_documents", defaultValue: "List installed documents")
        case .getMyDocuments:
            return String(localized: "tool_get_my_documents", defaultValue: "List My Documents")
        case .getMyDocumentPages:
            return String(localized: "tool_get_my_document_pages", defaultValue: "List My Document pages")
        case .getGenBookKeys:
            return String(localized: "tool_get_genbook_keys", defaultValue: "List general book keys")
        case .getGenBookContent:
            return String(localized: "tool_get_genbook_content", defaultValue: "Read general book content")
        case .getWindows:
            return String(localized: "tool_get_windows", defaultValue: "List windows")
        case .createBookmark:
            return String(localized: "tool_create_bookmark", defaultValue: "Create bookmark")
        case .addBookmarkNote:
            return String(localized: "tool_add_bookmark_note", defaultValue: "Add bookmark note")
        case .updateBookmarkNote:
            return String(localized: "tool_update_bookmark_note", defaultValue: "Update bookmark note")
        case .createLabel:
            return String(localized: "tool_create_label", defaultValue: "Create label")
        case .addLabelToBookmark:
            return String(localized: "tool_add_label_to_bookmark", defaultValue: "Add label to bookmark")
        case .deleteBookmark:
            return String(localized: "tool_delete_bookmark", defaultValue: "Delete bookmark")
        case .deleteLabel:
            return String(localized: "tool_delete_label", defaultValue: "Delete label")
        case .removeLabelFromBookmark:
            return String(localized: "tool_remove_label_from_bookmark", defaultValue: "Remove label from bookmark")
        case .addStudyPadEntry:
            return String(localized: "tool_add_study_pad_entry", defaultValue: "Add study pad entry")
        case .updateStudyPadTextEntry:
            return String(localized: "tool_update_studypad_text_entry", defaultValue: "Update study pad text entry")
        case .createStudyPad:
            return String(localized: "tool_create_study_pad", defaultValue: "Create study pad")
        case .createMyDocument:
            return String(localized: "tool_create_my_document", defaultValue: "Create My Document")
        case .addMyDocumentPage:
            return String(localized: "tool_add_my_document_page", defaultValue: "Add My Document page")
        case .editMyDocumentPage:
            return String(localized: "tool_edit_my_document_page", defaultValue: "Edit My Document page")
        case .deleteMyDocumentPage:
            return String(localized: "tool_delete_my_document_page", defaultValue: "Delete My Document page")
        case .createWindow:
            return String(localized: "tool_create_window", defaultValue: "Create window")
        case .manageWindow:
            return String(localized: "tool_manage_window", defaultValue: "Manage window")
        case .setWindowDocument:
            return String(localized: "tool_set_window_document", defaultValue: "Set window document")
        case .setDocumentTitle:
            return String(localized: "tool_set_document_title", defaultValue: "Set document title")
        case .finishWithStudyPad:
            return String(localized: "tool_finish_with_study_pad", defaultValue: "Open study pad")
        case .finishWithMyDocumentPage:
            return String(localized: "tool_finish_with_my_document_page", defaultValue: "Open My Document page")
        case .finishWithoutDocument:
            return String(localized: "tool_finish_without_document", defaultValue: "Finish without document")
        }
    }
}
