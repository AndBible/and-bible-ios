#!/usr/bin/env python3
"""
Regression tests for the reader presentation-ownership contract.

The catalog below is deliberately source-backed: each live reader route has an Android owner
reference and a required iOS presentation surface.  This prevents a generic "app-owned" label
from silently accepting a SwiftUI sheet where Android uses an activity or dialog.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
ANDROID_REPO_ROOT_CANDIDATES = (
    REPO_ROOT.parent / "and-bible",
    REPO_ROOT.parent.parent.parent / "and-bible",
)
READER_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Bible"
    / "BibleReaderView.swift"
)
BIBLE_READER_VIEW = READER_VIEW
DAILY_READING_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "ReadingPlans"
    / "DailyReadingView.swift"
)
READING_PLAN_LIST_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "ReadingPlans"
    / "ReadingPlanListView.swift"
)
ANDROID_DAILY_READING_ACTIVITY_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "ReadingPlans"
    / "AndroidDailyReadingActivityView.swift"
)
ANDROID_READING_PLAN_SELECTOR_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "ReadingPlans"
    / "AndroidReadingPlanSelectorView.swift"
)
READING_PLAN_START_DATE_DIALOG = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "ReadingPlans"
    / "AndroidReadingPlanStartDateDialog.swift"
)
READING_PROGRESS_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Bible"
    / "ReadingProgressViews.swift"
)
ANDROID_READING_PROGRESS_ACTIVITY_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Bible"
    / "AndroidReadingProgressActivityView.swift"
)
ANDROID_READING_PROGRESS_SETTINGS_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Bible"
    / "AndroidReadingProgressSettingsView.swift"
)
ANDROID_READ_HISTORY_DIALOG = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Shared"
    / "AndroidChapterReadHistoryDialog.swift"
)
ANDROID_FEATURE_HELP_DIALOG = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Shared"
    / "AndroidFeatureHelpDialog.swift"
)
AI_MODELS_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "AI"
    / "AIModelsView.swift"
)
AI_SETTINGS_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "AI"
    / "AISettingsView.swift"
)
AI_CONNECTION_SETTINGS_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "AI"
    / "AIConnectionSettingsView.swift"
)
AI_CONFIGURATION_DIALOG_PRESENTATION = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "AI"
    / "AIConfigurationDialogPresentation.swift"
)
AI_MODEL_DIALOGS = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "AI"
    / "AIModelDialogs.swift"
)
IMPORT_EXPORT_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Settings"
    / "ImportExportView.swift"
)
ANDROID_BACKUP_RESTORE_ACTIVITY_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Settings"
    / "AndroidBackupRestoreActivityView.swift"
)
ANDROID_DATABASE_BACKUP_IMPORT_DIALOG = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Settings"
    / "AndroidDatabaseBackupImportDialog.swift"
)
ANDROID_MODULE_BACKUP_EXPORT_SHEET = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Settings"
    / "AndroidModuleBackupExportSheet.swift"
)
ANDROID_MULTISELECT_DIALOG_CONTENT = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Shared"
    / "AndroidMultiselectDialogContent.swift"
)
BIBLE_READER_MODULE_PICKER = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Bible"
    / "BibleReaderModulePicker.swift"
)
EPUB_LIBRARY_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Dictionary"
    / "EpubLibraryView.swift"
)
MODULE_BROWSER_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Downloads"
    / "ModuleBrowserView.swift"
)
LEGACY_SEARCH_RESULTS_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Search"
    / "SearchResultsView.swift"
)
ANDROID_DOCUMENT_SELECTION_CONTROLS = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Shared"
    / "AndroidDocumentSelectionControls.swift"
)
BOOKMARK_LIST_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Bookmarks"
    / "BookmarkListView.swift"
)
BOOKMARK_CSV_TRANSFER_DOCUMENT = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Bookmarks"
    / "BookmarkCSVTransferDocument.swift"
)
SPEAK_CONTROL_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Speak"
    / "SpeakControlView.swift"
)
MY_DOCUMENT_PAGES_LIST_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "MyDocuments"
    / "MyDocumentPagesListView.swift"
)
MY_DOCUMENTS_LIST_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "MyDocuments"
    / "MyDocumentsListView.swift"
)
MY_DOCUMENT_PAGE_EDITOR = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "MyDocuments"
    / "MyDocumentPageEditor.swift"
)
ANDROID_MY_DOCUMENTS_ACTIVITY_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "MyDocuments"
    / "AndroidMyDocumentsActivityView.swift"
)
ANDROID_MY_DOCUMENT_PAGES_ACTIVITY_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "MyDocuments"
    / "AndroidMyDocumentPagesActivityView.swift"
)
AI_READER_HELP_PRESENTATION = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "AI"
    / "AIReaderHelpPresentation.swift"
)
BIBLE_WINDOW_PANE = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Bible"
    / "BibleWindowPane.swift"
)
AI_READER_RUN_VIEWS = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "AI"
    / "AIReaderRunViews.swift"
)
AI_READER_TRANSIENT_DIALOGS = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "AI"
    / "AIReaderTransientDialogs.swift"
)
SEARCH_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Search"
    / "SearchView.swift"
)
ADR_0006 = REPO_ROOT / "docs" / "adr" / "0006-modal-presentation-ownership-for-android-parity.md"
ADR_0008 = REPO_ROOT / "docs" / "adr" / "0008-parity-documentation-ownership.md"


ROUTE_CLASSIFICATIONS: dict[str, tuple[str, str]] = {
    "historyDialogRequest": (
        "Android app-owned",
        "Dialog-themed History activity equivalent. It captures the launching window, uses history_for, omits iOS-only destructive controls, and returns selection to that pane.",
    ),
    "chapterReadHistoryDialogRequest": (
        "Android app-owned",
        "Read History dialog captures its pane and target; staged deletes commit when it closes.",
    ),
    "ReaderDestination.readingProgressSettings": (
        "Android app-owned",
        "Android ReadingProgressSettingsActivity-equivalent reader destination.",
    ),
    "ReaderDestination.passageChooser": (
        "Android app-owned",
        "Android GridChoosePassageBook-equivalent destination. It must retain its captured pane and not regress into an in-place reader overlay.",
    ),
    "ReaderDestination.search": (
        "Android app-owned",
        "Adapted app-owned route with UI coverage protecting destination presentation.",
    ),
    "ReaderDestination.bookmarks": (
        "Android app-owned",
        "App-owned route. Bookmarks must not be reintroduced as a ReaderSheet route.",
    ),
    "ReaderDestination.studyPads": (
        "Android app-owned",
        "App-owned route. StudyPads must not be reintroduced as a nested selector modal.",
    ),
    "ReaderDestination.myDocuments": (
        "Android app-owned",
        "Drawer-owned app route through the reader My Documents document pipeline.",
    ),
    "ReaderDestination.workspaces": (
        "Android app-owned",
        "Android WorkspaceSelectorActivity-equivalent reader destination.",
    ),
    "ReaderDestination.readingPlans": (
        "Android app-owned",
        "App-owned route. Reading Plans must not be reintroduced as a ReaderSheet route.",
    ),
    "ReaderDestination.readingProgress": (
        "Android app-owned",
        "Android ReadingProgressActivity-equivalent destination. It must retain its captured reader pane and must not regress into ReaderSheet ownership.",
    ),
    "ReaderDestination.speakControls": (
        "Android app-owned",
        "Android BibleSpeakActivity-equivalent destination. Speak controls must retain the captured reader pane and must not regress into ReaderModal sheet ownership.",
    ),
    "ReaderDestination.settings": (
        "Android app-owned",
        "Adapted app-owned route with Settings UI coverage.",
    ),
    "ReaderDestination.aiSettings": (
        "Android app-owned",
        "Android top-level settings route with direct and Application Preferences UI coverage.",
    ),
    "ReaderDestination.startupDocumentSetup": (
        "Android app-owned",
        "Startup setup route matching Android's first-download activity surface.",
    ),
    "ReaderDestination.downloads": (
        "Android app-owned",
        "Adapted app-owned route.",
    ),
    "ReaderDestination.importExport": (
        "Android app-owned plus iOS system boundary",
        "Android BackupActivity-equivalent route; may use native iOS file boundaries only at OS handoff points.",
    ),
    "ReaderDestination.globalTextOptions": (
        "Android app-owned",
        "App-owned settings route. Scope semantics are governed by ADR 0005.",
    ),
    "ReaderDestination.workspaceTextOptions": (
        "Android app-owned",
        "App-owned settings route. Workspace color behavior is governed by ADR 0005.",
    ),
    "ReaderDestination.windowTextOptions": (
        "Android app-owned",
        "App-owned settings route.",
    ),
    "ReaderDestination.windowColorSettings": (
        "Android app-owned",
        "App-owned settings route.",
    ),
    "ReaderDestination.windowHiddenLabels": (
        "Android app-owned",
        "Android ManageLabels HIDELABELS-mode activity reached from the active window's text options.",
    ),
    "ReaderDestination.syncSettings": (
        "Android app-owned",
        "Android SyncSettingsActivity-equivalent reader navigation route.",
    ),
    "ReaderDestination.modulePicker": (
        "Android app-owned",
        "Android ChooseDocument activity hosted on the same reader destination stack as Downloads.",
    ),
    "ReaderDestination.dictionaryBrowser": (
        "Android app-owned",
        "Android ChooseDictionaryWord-equivalent reader navigation route.",
    ),
    "ReaderDestination.generalBookBrowser": (
        "Android app-owned",
        "Android ChooseGeneralBookKey-equivalent reader navigation route.",
    ),
    "ReaderDestination.mapBrowser": (
        "Android app-owned",
        "Android ChooseMapKey-equivalent reader navigation route.",
    ),
    "ReaderDestination.epubSearch": (
        "Android app-owned",
        "Android EpubSearch-equivalent reader navigation route.",
    ),
    "ReaderDestination.labelManager": (
        "Android app-owned",
        "Android ManageLabels-equivalent reader navigation route.",
    ),
    "ReaderDestination.chooseDocument": (
        "Android app-owned",
        "Android all-types ChooseDocument activity hosted on the same reader destination stack as Downloads.",
    ),
    "helpDialogOverlay": (
        "Android app-owned",
        "Android Help & Tips dialog rendered outside generic adaptive sheet ownership.",
    ),
    "licenseDialogOverlay": (
        "Android app-owned",
        "Android Open Source License dialog renders bundled GPL text without a browser handoff.",
    ),
    "bugReportDialogOverlay": (
        "Android app-owned plus iOS system boundary",
        "Android diagnostic-report confirmation precedes the legitimate iOS share handoff.",
    ),
    "showReaderStrongsModeDialog": (
        "Android app-owned",
        "Acceptable dialog adaptation if choices, reset/default semantics, and preference mutation match Android.",
    ),
    "shareSheetBinding": (
        "iOS system boundary",
        "Acceptable platform boundary when it only hands selected/generated content to OS sharing.",
    ),
    "showRefChooser": (
        "Android app-owned",
        "Adapted app-owned chooser route. Keep async callback semantics and pane context intact.",
    ),
    "BibleReaderModulePicker.AndroidPseudoDocument.myNotes": (
        "Vue/WebView-owned",
        "Chooser-owned pseudo-document route. Drawer My Notes/My Documents must route through ReaderDestination.myDocuments.",
    ),
    "SearchView.translationPicker": (
        "Android app-owned",
        "Android Dialogs.multiselect-equivalent overlay. Draft selection commits only on non-empty OK; Cancel leaves the Search selection unchanged.",
    ),
}


ANDROID_MAIN_MENU = "app/src/main/java/net/bible/android/view/activity/page/MenuCommandHandler.kt"
ANDROID_MAIN_ACTIVITY = "app/src/main/java/net/bible/android/view/activity/page/MainBibleActivity.kt"
ANDROID_STARTUP_ACTIVITY = "app/src/main/java/net/bible/android/view/activity/StartupActivity.kt"
ANDROID_MANIFEST = "app/src/main/AndroidManifest.xml"
ANDROID_HISTORY = "app/src/main/java/net/bible/android/view/activity/navigation/History.kt"
ANDROID_PROGRESS = "app/src/main/java/net/bible/android/view/activity/progress/ReadingProgressActivity.kt"
ANDROID_READ_HISTORY = "app/src/main/java/net/bible/android/view/activity/progress/ReadHistoryDialog.kt"
ANDROID_SEARCH = "app/src/main/java/net/bible/android/view/activity/search/Search.kt"
ANDROID_MANAGE_LABELS = "app/src/main/java/net/bible/android/view/activity/bookmark/ManageLabels.kt"
ANDROID_PLATFORM_BOUNDARY = "Android platform handoff (no app-owned window)"


@dataclass(frozen=True)
class RouteContract:
    """Evidence required to claim Android/iOS presentation ownership parity for one live route."""

    android_owner: str
    disposition: str
    android_source: str
    required_ios_surface: str


def route_keys(*keys: str, source: str, surface: str) -> dict[str, tuple[str, str]]:
    """Build concise Android-source/surface entries shared by routes with the same owner contract."""
    return {key: (source, surface) for key in keys}


ROUTE_EVIDENCE: dict[str, tuple[str, str]] = {
    **route_keys(
        "ReaderDestination.search",
        "ReaderDestination.bookmarks",
        "ReaderDestination.studyPads",
        "ReaderDestination.myDocuments",
        "ReaderDestination.workspaces",
        "ReaderDestination.readingPlans",
        "ReaderDestination.downloads",
        "ReaderDestination.importExport",
        "ReaderDestination.settings",
        "ReaderDestination.aiSettings",
        "ReaderDestination.globalTextOptions",
        "ReaderDestination.workspaceTextOptions",
        "ReaderDestination.windowTextOptions",
        "ReaderDestination.windowColorSettings",
        "ReaderDestination.syncSettings",
        source=ANDROID_MAIN_MENU,
        surface="reader navigation destination",
    ),
    **route_keys(
        "ReaderDestination.startupDocumentSetup",
        source=ANDROID_STARTUP_ACTIVITY,
        surface="reader navigation destination",
    ),
    **route_keys(
        "ReaderDestination.readingProgress",
        "ReaderDestination.readingProgressSettings",
        source=ANDROID_PROGRESS,
        surface="reader navigation destination",
    ),
    **route_keys(
        "ReaderDestination.passageChooser",
        "ReaderDestination.speakControls",
        "ReaderDestination.dictionaryBrowser",
        "ReaderDestination.generalBookBrowser",
        "ReaderDestination.mapBrowser",
        "ReaderDestination.epubSearch",
        "ReaderDestination.labelManager",
        source=ANDROID_MANIFEST,
        surface="reader navigation destination",
    ),
    **route_keys(
        "ReaderDestination.modulePicker",
        "ReaderDestination.chooseDocument",
        source=ANDROID_MAIN_ACTIVITY,
        surface="reader navigation destination",
    ),
    **route_keys(
        "ReaderDestination.windowHiddenLabels",
        source=ANDROID_MANAGE_LABELS,
        surface="reader navigation destination",
    ),
    **route_keys(
        "historyDialogRequest",
        source=ANDROID_HISTORY,
        surface="reader-owned dialog overlay",
    ),
    **route_keys(
        "chapterReadHistoryDialogRequest",
        source=ANDROID_READ_HISTORY,
        surface="reader-owned dialog overlay",
    ),
    **route_keys(
        "helpDialogOverlay",
        "licenseDialogOverlay",
        "bugReportDialogOverlay",
        "showReaderStrongsModeDialog",
        source=ANDROID_MAIN_MENU,
        surface="reader-owned dialog overlay",
    ),
    **route_keys(
        "showRefChooser",
        source=ANDROID_MANIFEST,
        surface="full-screen app-owned chooser",
    ),
    **route_keys(
        "BibleReaderModulePicker.AndroidPseudoDocument.myNotes",
        source=ANDROID_MAIN_ACTIVITY,
        surface="WebView/document pipeline",
    ),
    **route_keys(
        "SearchView.translationPicker",
        source=ANDROID_SEARCH,
        surface="Search-owned dialog overlay",
    ),
    **route_keys(
        "shareSheetBinding",
        source=ANDROID_PLATFORM_BOUNDARY,
        surface="iOS system share boundary",
    ),
}


def swift_enum_cases(source: str, enum_name: str) -> list[str]:
    """Return simple `case name` entries from one Swift enum declaration."""
    match = re.search(rf"\benum\s+{re.escape(enum_name)}\b[^\{{]*\{{", source)
    if match is None:
        raise AssertionError(f"Expected enum {enum_name} to exist.")

    start = match.end()
    depth = 1
    index = start
    while index < len(source) and depth > 0:
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        index += 1

    if depth != 0:
        raise AssertionError(f"Expected enum {enum_name} body to close.")

    body = source[start : index - 1]
    cases: list[str] = []
    for line in body.splitlines():
        case_match = re.match(r"\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\b", line)
        if case_match is not None:
            cases.append(case_match.group(1))

    return cases


def swift_function_body(source: str, function_name: str) -> str:
    """Return one Swift function body by matching balanced braces."""
    match = re.search(rf"\bfunc\s+{re.escape(function_name)}\b[^\{{]*\{{", source)
    if match is None:
        raise AssertionError(f"Expected function {function_name} to exist.")

    start = match.end()
    depth = 1
    index = start
    while index < len(source) and depth > 0:
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        index += 1

    if depth != 0:
        raise AssertionError(f"Expected function {function_name} body to close.")
    return source[start : index - 1]


def swift_switch_case_body(function_body: str, case_name: str) -> str:
    """Return the body for one simple `case .name:` inside a Swift switch."""
    case_match = re.search(rf"^\s*case\s+\.{re.escape(case_name)}\s*:", function_body, re.MULTILINE)
    if case_match is None:
        raise AssertionError(f"Expected switch case .{case_name} to exist.")

    next_case = re.search(r"^\s*case\s+\.", function_body[case_match.end() :], re.MULTILINE)
    if next_case is None:
        return function_body[case_match.end() :]
    return function_body[case_match.end() : case_match.end() + next_case.start()]


def route_contract(token: str) -> RouteContract:
    """Return the Android source and required iOS surface for one live reader presentation route."""
    try:
        android_owner, disposition = ROUTE_CLASSIFICATIONS[token]
    except KeyError as error:
        raise AssertionError(f"Expected {token} to be contracted under ADR 0006.") from error
    try:
        android_source, required_ios_surface = ROUTE_EVIDENCE[token]
    except KeyError as error:
        raise AssertionError(
            f"Expected {token} to name an Android source and required iOS surface."
        ) from error
    return RouteContract(
        android_owner=android_owner,
        disposition=disposition,
        android_source=android_source,
        required_ios_surface=required_ios_surface,
    )


class ReaderModalOwnershipMatrixTests(unittest.TestCase):
    """Keeps live reader presentations tied to exact Android owners and iOS surfaces under ADR 0006."""

    def test_reader_sheet_cases_have_source_backed_contracts(self) -> None:
        """Every live `ReaderSheet` case must name an Android source and required iOS surface."""
        source = READER_VIEW.read_text(encoding="utf-8")

        for case in swift_enum_cases(source, "ReaderSheet"):
            route_contract(f"ReaderSheet.{case}")

    def test_reader_destination_cases_have_source_backed_contracts(self) -> None:
        """Every reader destination must retain a source-backed Android activity contract."""
        source = READER_VIEW.read_text(encoding="utf-8")

        for case in swift_enum_cases(source, "ReaderDestination"):
            route_contract(f"ReaderDestination.{case}")

    def test_reader_modal_cases_have_source_backed_contracts(self) -> None:
        """Every reader modal must name whether Android requires a dialog or full-screen chooser."""
        source = READER_VIEW.read_text(encoding="utf-8")

        for case in swift_enum_cases(source, "ReaderModal"):
            route_contract(f"ReaderModal.{case}")

    def test_standalone_transient_routes_have_source_backed_contracts(self) -> None:
        """State-backed reader presentations outside the enums remain source-backed rather than labeled."""
        for token in [
            "showReaderStrongsModeDialog",
            "shareSheetBinding",
            "showRefChooser",
            "BibleReaderModulePicker.AndroidPseudoDocument.myNotes",
            "historyDialogRequest",
            "chapterReadHistoryDialogRequest",
            "helpDialogOverlay",
            "licenseDialogOverlay",
            "bugReportDialogOverlay",
            "SearchView.translationPicker",
        ]:
            route_contract(token)

    def test_high_risk_routes_keep_expected_owner_contract(self) -> None:
        """
        Protect Android parity ownership for routes most likely to drift.

        The matrix is not just an inventory. These routes sit at different
        ownership boundaries in Android: search and chooser flows are
        app-owned, sharing is an OS boundary, and cross references are
        document/WebView-owned. A failure here means a future docs or reader
        change has altered that contract and needs product review before parity
        is claimed.
        """
        expected_owners = {
            "ReaderDestination.search": "Android app-owned",
            "ReaderDestination.bookmarks": "Android app-owned",
            "ReaderDestination.studyPads": "Android app-owned",
            "ReaderDestination.myDocuments": "Android app-owned",
            "ReaderDestination.readingPlans": "Android app-owned",
            "ReaderDestination.readingProgress": "Android app-owned",
            "ReaderDestination.importExport": "Android app-owned plus iOS system boundary",
            "ReaderDestination.speakControls": "Android app-owned",
            "historyDialogRequest": "Android app-owned",
            "showRefChooser": "Android app-owned",
            "ReaderDestination.chooseDocument": "Android app-owned",
            "ReaderDestination.modulePicker": "Android app-owned",
            "ReaderDestination.labelManager": "Android app-owned",
            "shareSheetBinding": "iOS system boundary",
            "BibleReaderModulePicker.AndroidPseudoDocument.myNotes": "Vue/WebView-owned",
        }

        for token, owner in expected_owners.items():
            contract = route_contract(token)
            self.assertEqual(owner, contract.android_owner)
            self.assertTrue(contract.android_source)
            self.assertTrue(contract.required_ios_surface)

    def test_live_contracts_reference_android_source_or_an_explicit_platform_boundary(self) -> None:
        """
        Prevent route-contract prose from drifting away from Android implementation evidence.

        Setup: the parity scratchpad names the sibling Android checkout as the behavioral source of
        truth. Every live app-owned route must therefore resolve to a real Android source file;
        only the share handoff may identify an explicit platform boundary instead. A failure means
        the ownership matrix has become an assertion without auditable source evidence.
        """
        android_root = next(
            (candidate for candidate in ANDROID_REPO_ROOT_CANDIDATES if candidate.is_dir()),
            None,
        )
        self.assertIsNotNone(android_root, "Expected the sibling Android source checkout for parity evidence.")

        for token in ROUTE_EVIDENCE:
            contract = route_contract(token)
            if contract.android_source == ANDROID_PLATFORM_BOUNDARY:
                self.assertEqual("iOS system share boundary", contract.required_ios_surface)
                continue
            self.assertTrue(
                (android_root / contract.android_source).is_file(),
                f"Expected {token} to reference a real Android source: {contract.android_source}",
            )

    def test_drawer_owned_destinations_do_not_route_through_reader_sheets(self) -> None:
        """
        Keep left-drawer app screens on the reader destination stack.

        Android launches Bookmarks, StudyPads, and Reading Plan as app-owned activities from the
        drawer. The iOS drawer route must therefore not preserve the old SwiftUI sheet/modal path
        just because a legacy non-drawer shortcut still has a row in the matrix.
        """
        source = READER_VIEW.read_text(encoding="utf-8")
        drawer_handler = swift_function_body(source, "handleReaderNavigationDrawerAction")

        expected_destinations = {
            "chooseDocument": "presentReaderDestination(.chooseDocument",
            "bookmarks": "presentReaderDestination(.bookmarks",
            "studyPads": "presentReaderDestination(.studyPads",
            "myNotes": "presentReaderDestination(.myDocuments",
            "readingPlans": "presentReaderDestination(.readingPlans",
            "readingProgress": "presentReadingProgress(initialTab: nil",
            "importExport": "presentReaderDestination(.importExport",
        }

        for drawer_case, expected_route in expected_destinations.items():
            body = swift_switch_case_body(drawer_handler, drawer_case)
            self.assertIn(expected_route, body)
            self.assertNotIn("presentReaderSheet", body)
            self.assertNotIn("presentReaderModal", body)

        module_picker_body = swift_function_body(source, "presentModulePicker")
        self.assertIn("presentReaderDestination(.modulePicker", module_picker_body)
        self.assertNotIn("presentReaderModal", module_picker_body)
        self.assertNotIn("if let modal = activeReaderModal", source)
        self.assertIn("documentChooserDestinationContent(", source)

    def test_document_chooser_remains_the_same_full_activity_family_as_document_downloader(self) -> None:
        """
        Protect Choose Document from regressing into a large-font History-like modal.

        Android's chooser and downloader derive from the same `DocumentSelectionBase` activity.
        Both iOS projections must therefore reuse the same viewport host, app bar, filter strip,
        palette, and document-row type scale. Merely drawing an app-owned dialog is not sufficient.
        """
        chooser_source = BIBLE_READER_MODULE_PICKER.read_text(encoding="utf-8")
        downloader_source = MODULE_BROWSER_VIEW.read_text(encoding="utf-8")
        shared_source = ANDROID_DOCUMENT_SELECTION_CONTROLS.read_text(encoding="utf-8")
        reader_source = READER_VIEW.read_text(encoding="utf-8")

        for source in (chooser_source, downloader_source):
            self.assertIn("AndroidDocumentSelectionActivityScreen(surfacePalette: surfacePalette)", source)
            self.assertIn("AndroidDocumentSelectionFilterBar(", source)
            self.assertIn("AndroidActivityTopAppBar(", source)
            self.assertIn(".font(.system(size: 16, weight: .regular))", source)
            self.assertIn(".font(.system(size: 14, weight: .regular))", source)
            self.assertNotIn("AndroidHistoryDialog", source)
            self.assertNotIn("AndroidDialogWindow", source)
            self.assertNotIn("AndroidDialogScaffold", source)
            self.assertNotIn(".presentationDetents", source)
            self.assertNotIn("NavigationStack {", source)
            self.assertNotIn("List {", source)
            self.assertNotIn(".navigationTitle(", source)

        self.assertIn('title: String(localized: "document", defaultValue: "Document")', chooser_source)
        self.assertIn(
            'title: String(localized: "download", defaultValue: "Download Documents")',
            downloader_source,
        )
        self.assertIn(
            ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)",
            shared_source,
        )
        self.assertIn("AndroidActivitySurface(palette: surfacePalette)", shared_source)
        self.assertNotIn("surfacePalette.backgroundColor.ignoresSafeArea()", shared_source)
        self.assertNotIn(".navigationBarBackButtonHidden(true)", shared_source)
        self.assertNotIn(".toolbar(.hidden, for: .navigationBar)", shared_source)

        destination_body = swift_function_body(reader_source, "documentChooserDestinationContent")
        self.assertIn("BibleReaderModulePicker(", destination_body)
        self.assertIn("onDeleteEpub: reconcileDeletedEpubAcrossReaderPanes", destination_body)
        self.assertNotIn("AndroidHistoryDialog", destination_body)
        self.assertNotIn("AndroidDialogWindow", destination_body)

    def test_startup_setup_reuses_android_activity_resources_and_owner_palette(self) -> None:
        """First-download setup must not reintroduce native iOS navigation or screenshot styling."""
        startup_source = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Bible"
            / "StartupDocumentSetupView.swift"
        ).read_text(encoding="utf-8")
        reader_source = READER_VIEW.read_text(encoding="utf-8")
        destination_body = swift_switch_case_body(
            swift_function_body(reader_source, "readerDestinationContent"),
            "startupDocumentSetup",
        )

        self.assertIn('Image("DrawerLogo", bundle: .module)', startup_source)
        self.assertIn("AndroidRaisedTextButton(", startup_source)
        self.assertIn("surfacePalette.controlFillColor", startup_source)
        self.assertIn("surfacePalette.secondaryForegroundColor", startup_source)
        self.assertIn("AndroidDialogSurfacePalette.accent(for: colorScheme)", startup_source)
        self.assertIn("AndroidActivityAccessibilityMarker(", startup_source)
        self.assertIn('title: "https://andbible.org"', startup_source)
        self.assertIn('title: "https://github.com/AndBible/and-bible"', startup_source)
        self.assertIn(".toolbar(.hidden, for: .navigationBar)", startup_source)
        self.assertNotIn(".buttonStyle(.borderedProminent)", startup_source)
        self.assertNotIn(".controlSize(.large)", startup_source)
        self.assertNotIn("systemBackground", startup_source)
        self.assertNotIn("windowBackgroundColor", startup_source)
        self.assertNotIn("Image(systemName:", startup_source)
        self.assertIn("surfacePalette: readerThemeSurfacePalette", destination_body)
        self.assertNotIn(".toolbar(.visible, for: .navigationBar)", destination_body)

        download_index = startup_source.index("startupActionButton(for: .downloadDocuments)")
        restore_index = startup_source.index("startupActionButton(for: .restoreDatabase)")
        formats_index = startup_source.index("Text(supportedFormatsText)")
        import_index = startup_source.index("startupActionButton(for: .loadDocumentsFromFiles)")
        homepage_index = startup_source.index('title: "https://andbible.org"')
        self.assertLess(download_index, restore_index)
        self.assertLess(restore_index, formats_index)
        self.assertLess(formats_index, import_index)
        self.assertLess(import_index, homepage_index)

    def test_production_sheet_inventory_is_only_explicit_operating_system_handoffs(self) -> None:
        """Every remaining SwiftUI sheet must be a mail/share boundary, never app content."""
        source_root = REPO_ROOT / "Sources" / "BibleUI" / "Sources" / "BibleUI"
        expected = {
            "AI/AIRawLogHistoryView.swift": [".sheet(item: $bugReportMail)"],
            "AI/AIReaderLiveRawLogView.swift": [".sheet(item: $bugReportMail)"],
            "Bible/BibleReaderView.swift": [
                ".sheet(item: $manualBugReportMailPayload, onDismiss: finishBugReportMailPresentation)",
                ".sheet(item: $manualBugReportExport, onDismiss: finishBugReportExportShare)",
                ".sheet(isPresented: shareSheetBinding)",
            ],
            "MyDocuments/MyDocumentPagesListView.swift": [
                ".sheet(isPresented: $showsShareSheet, onDismiss: clearPageExport)"
            ],
            "Settings/ImportExportView.swift": [
                ".sheet(isPresented: $showExportSheet, onDismiss: handleShareSheetDismiss)"
            ],
        }
        actual: dict[str, list[str]] = {}
        for path in source_root.rglob("*.swift"):
            signatures = [
                line.strip().split(" {", maxsplit=1)[0]
                for line in path.read_text(encoding="utf-8").splitlines()
                if re.search(r"\.sheet\s*\(", line)
            ]
            if signatures:
                actual[str(path.relative_to(source_root))] = signatures

        self.assertEqual(expected, actual)
        self.assertIn(
            "AIBugReportMailComposer(payload: payload)",
            (source_root / "AI" / "AIRawLogHistoryView.swift").read_text(encoding="utf-8"),
        )
        self.assertIn(
            "AIBugReportMailComposer(payload: payload)",
            (source_root / "AI" / "AIReaderLiveRawLogView.swift").read_text(encoding="utf-8"),
        )

    def test_app_owned_bibleui_has_no_native_application_presentation_primitives(self) -> None:
        """Live BibleUI source must use shared app-owned controls instead of iOS UI substitutes."""
        source_root = REPO_ROOT / "Sources" / "BibleUI" / "Sources" / "BibleUI"
        forbidden_patterns = {
            "native collection/control": re.compile(
                r"\b(?:List|Form|Menu|Picker|Toggle|DatePicker|NavigationLink)\s*[({]"
            ),
            "native adaptive presentation": re.compile(
                r"\.(?:alert|confirmationDialog|popover|fullScreenCover|presentationDetents)\s*\("
            ),
            "native search/context behavior": re.compile(
                r"\.(?:searchable|contextMenu|swipeActions)\s*\("
            ),
            "native navigation title": re.compile(r"\.navigationTitle\s*\("),
        }

        for path in source_root.rglob("*.swift"):
            swift_source = path.read_text(encoding="utf-8")
            code_only = re.sub(r"/\*.*?\*/", "", swift_source, flags=re.DOTALL)
            code_only = re.sub(r"//.*", "", code_only)
            for owner, pattern in forbidden_patterns.items():
                with self.subTest(path=str(path.relative_to(source_root)), owner=owner):
                    self.assertIsNone(pattern.search(code_only))

        self.assertFalse((source_root / "Settings" / "AboutView.swift").exists())

    def test_epub_management_reuses_choose_document_instead_of_a_parallel_library(self) -> None:
        """Imported EPUBs retain Android's document row, context bar, and immutable-index actions."""
        chooser_source = BIBLE_READER_MODULE_PICKER.read_text(encoding="utf-8")
        reader_source = READER_VIEW.read_text(encoding="utf-8")

        self.assertFalse(EPUB_LIBRARY_VIEW.exists())
        self.assertNotIn("epubLibrary", swift_enum_cases(reader_source, "ReaderDestination"))
        self.assertNotIn("EpubLibraryView", reader_source)
        self.assertIn("case .epub(let epub):", chooser_source)
        self.assertIn("onLongPress: { beginContextualEpubSelection(epub) }", chooser_source)
        self.assertIn("AndroidDocumentContextActionBar(", chooser_source)
        self.assertIn("private var contextualEpubActions", chooser_source)
        self.assertIn("[.about, .uninstall, .deleteIndex]", chooser_source)
        self.assertIn("ModuleBrowserModuleDetails(epub: contextualEpub)", chooser_source)
        self.assertIn("EpubLibraryDeletionState", chooser_source)
        self.assertIn("EpubReader.deleteSearchIndex(identifier: identifier)", chooser_source)
        self.assertIn("controller.adoptRebuiltEpubReader(replacementReader)", chooser_source)
        self.assertIn("Text(epub.initials)", chooser_source)
        self.assertIn("Text(epub.title)", chooser_source)
        self.assertNotIn("Text(epub.author)", chooser_source)

    def test_reader_preparation_and_search_results_do_not_reintroduce_native_activity_chrome(self) -> None:
        """Transient loading and Search retain shared app-owned activity ownership."""
        reader_source = READER_VIEW.read_text(encoding="utf-8")

        self.assertFalse(LEGACY_SEARCH_RESULTS_VIEW.exists())
        self.assertNotIn("NavigationStack {", reader_source)
        self.assertIn("private struct ReaderPanePreparationView", reader_source)
        self.assertIn("AndroidActivityScreen(", reader_source)
        self.assertIn("AndroidActivityLoadingView(", reader_source)
        self.assertIn("AndroidActivityEmptyListView(", reader_source)
        self.assertIn("surfacePalette: readerThemeSurfacePalette", reader_source)
        self.assertNotIn("ProgressView()", reader_source)

    def test_history_is_a_captured_android_dialog_not_a_reader_sheet(self) -> None:
        """History must retain Android dialog ownership, title, and active-window result routing."""
        source = READER_VIEW.read_text(encoding="utf-8")
        drawer_handler = swift_function_body(source, "handleReaderNavigationDrawerAction")
        history_body = swift_switch_case_body(drawer_handler, "history")

        self.assertIn("presentHistoryDialog", history_body)
        self.assertNotIn("presentReaderSheet", history_body)
        self.assertNotIn("history", swift_enum_cases(source, "ReaderSheet"))
        self.assertIn("historyDialogRequest", source)
        self.assertIn("HistoryDialogRequest", source)
        self.assertIn('localized: "history_for"', source)
        self.assertIn("AndroidHistoryDialog", source)

    def test_reading_plan_start_date_uses_android_date_picker_dialog_ownership(self) -> None:
        """Android's calendar must remain app-owned rather than an iOS picker or sheet."""
        daily_reading_source = DAILY_READING_VIEW.read_text(encoding="utf-8")
        dialog_source = READING_PLAN_START_DATE_DIALOG.read_text(encoding="utf-8")

        self.assertIn("AndroidReadingPlanStartDateDialog", daily_reading_source)
        self.assertNotIn(".sheet(isPresented: $showStartDatePicker)", daily_reading_source)
        self.assertIn("AndroidDialogWindow", dialog_source)
        self.assertIn("LazyVGrid", dialog_source)
        self.assertIn("calendar.compare(date, to: Date(), toGranularity: .day)", dialog_source)
        self.assertNotIn("DatePicker(", dialog_source)
        self.assertNotIn(".regularMaterial", dialog_source)
        self.assertIn("androidReadingPlanStartDateDialog", dialog_source)
        self.assertIn("dailyReadingStartDateCancelButton", dialog_source)
        self.assertIn("dailyReadingStartDateDoneButton", dialog_source)

    def test_reading_plan_route_uses_android_activities_not_ios_collections(self) -> None:
        """Plan selection and Daily Reading must not conceal native iOS collection chrome."""
        route_source = READING_PLAN_LIST_VIEW.read_text(encoding="utf-8")
        owner_source = DAILY_READING_VIEW.read_text(encoding="utf-8")
        activity_source = ANDROID_DAILY_READING_ACTIVITY_VIEW.read_text(encoding="utf-8")
        selector_source = ANDROID_READING_PLAN_SELECTOR_VIEW.read_text(encoding="utf-8")
        combined = "\n".join((route_source, owner_source, activity_source, selector_source))

        for forbidden in (
            "List {",
            "Form {",
            "NavigationStack",
            "NavigationLink",
            "Menu {",
            ".sheet(",
            ".popover(",
            ".contextMenu",
            ".swipeActions",
            ".regularMaterial",
        ):
            self.assertNotIn(forbidden, combined)

        self.assertIn("AndroidReadingPlanSelectorView", route_source)
        self.assertIn("AndroidDailyReadingActivityView", owner_source)
        self.assertIn("AndroidActivityScreen(", selector_source)
        self.assertIn("AndroidActivityAccessibilityMarker(", selector_source)
        self.assertIn(".androidAnchoredPopupMenu", activity_source)
        self.assertIn("AndroidPopupMenuSurface", activity_source)
        self.assertIn("AndroidRaisedTextButton", activity_source)
        self.assertIn(".fileImporter(", route_source)

    def test_read_history_is_a_captured_staged_delete_dialog_not_a_reader_sheet(self) -> None:
        """Read History must retain Android dialog dismissal semantics instead of sheet ownership."""
        source = READER_VIEW.read_text(encoding="utf-8")
        dialog_source = ANDROID_READ_HISTORY_DIALOG.read_text(encoding="utf-8")

        self.assertNotIn("chapterReadHistory", swift_enum_cases(source, "ReaderSheet"))
        self.assertIn("chapterReadHistoryDialogRequest", source)
        self.assertIn("ChapterReadHistoryDialogRequest", source)
        self.assertIn("AndroidChapterReadHistoryDialog", source)
        self.assertIn("presentChapterReadHistoryDialog(target: target, from: window.id)", source)
        self.assertIn("AndroidReadHistoryDialog", dialog_source)
        self.assertIn("AndroidDialogWindow", dialog_source)
        self.assertIn("deleteHistoryEntries(ids: pendingDeleteIDs)", dialog_source)
        self.assertIn('Text(isPending ? "↶" : "×")', dialog_source)
        for forbidden in (
            "NavigationStack",
            "NavigationView",
            "Form {",
            "List {",
            "Section(",
            ".sheet(",
            ".regularMaterial",
            "Image(systemName:",
        ):
            self.assertNotIn(forbidden, dialog_source)

    def test_help_is_an_android_owned_dialog_not_a_reader_modal_sheet(self) -> None:
        """Help & Tips must use the app-owned Android dialog owner at every reader entry point."""
        source = READER_VIEW.read_text(encoding="utf-8")

        self.assertNotIn("help", swift_enum_cases(source, "ReaderModal"))
        self.assertIn("helpDialogOverlay", source)
        self.assertIn("AndroidHelpDialog", source)
        self.assertIn("presentHelpDialog()", source)
        self.assertNotIn("presentReaderModal(.help)", source)

    def test_app_license_is_a_bundled_android_dialog_not_an_external_link(self) -> None:
        """The drawer license must render shipped GPL content in an app-owned dialog."""
        source = READER_VIEW.read_text(encoding="utf-8")
        drawer_handler = swift_function_body(source, "handleReaderNavigationDrawerAction")
        license_body = swift_switch_case_body(drawer_handler, "appLicense")
        license_dialog = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Shared"
            / "AndroidLicenseDialog.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("presentLicenseDialog", license_body)
        self.assertNotIn("openExternalLink", license_body)
        self.assertIn("licenseDialogOverlay", source)
        self.assertIn("AndroidLicenseDialog", source)
        self.assertIn('Bundle.module.url(forResource: "LICENSE", withExtension: "txt")', license_dialog)

    def test_rate_review_uses_system_prompt_without_custom_interstitial(self) -> None:
        """Rate & Review must invoke StoreKit directly and keep feedback actions separate.

        Apple disallows custom review prompts, so the drawer action may dismiss presentation state
        but must not route through an app-owned rating dialog. Support and bug reporting remain
        separate drawer actions rather than being used to steer negative reviewers.
        """
        source = READER_VIEW.read_text(encoding="utf-8")
        drawer_handler = swift_function_body(source, "handleReaderNavigationDrawerAction")
        rate_body = swift_switch_case_body(drawer_handler, "rateApp")
        rate_dialog_path = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Shared"
            / "AndroidRateReviewDialog.swift"
        )

        self.assertIn("requestSystemReview", rate_body)
        self.assertNotIn("presentRateReviewDialog", source)
        self.assertNotIn("rateReviewDialogOverlay", source)
        self.assertNotIn("AndroidRateReviewDialog", source)
        self.assertFalse(rate_dialog_path.exists())
        self.assertIn("SKStoreReviewController.requestReview", source)
        self.assertIn("case .needHelp:", drawer_handler)
        self.assertIn("case .reportBug:", drawer_handler)

    def test_bug_report_prepares_diagnostics_before_consent_gated_mail_handoff(self) -> None:
        """Manual reports prepare evidence before consent and never degrade to an unaddressed share."""
        source = READER_VIEW.read_text(encoding="utf-8")
        drawer_handler = swift_function_body(source, "handleReaderNavigationDrawerAction")
        report_body = swift_switch_case_body(drawer_handler, "reportBug")
        report_source = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Shared"
            / "AndroidBugReportDialog.swift"
        ).read_text(encoding="utf-8")
        preparation_source = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Shared"
            / "ProductFeedbackReportPreparation.swift"
        ).read_text(encoding="utf-8")
        collection_body = swift_function_body(source, "presentBugReportDialog")
        consent_body = swift_function_body(source, "presentPreparedBugReport")

        self.assertIn("presentBugReportDialog", report_body)
        self.assertNotIn("openExternalLink", report_body)
        self.assertIn("bugReportDialogOverlay", source)
        self.assertIn("ManualBugReportCoordinator", source)
        self.assertIn("manualBugReportCoordinator", source)
        self.assertIn("ProductFeedbackReportPreparation.captureUIEvidence()", source)
        self.assertIn("ProductFeedbackReportPreparation.prepare(uiEvidence:", source)
        self.assertIn("presentPreparedBugReport", source)
        self.assertIn("AddressedMailComposer", source)
        self.assertIn(
            "@State private var manualBugReportPreparedPayload: AddressedMailPayload?",
            source,
        )
        self.assertIn(
            ".sheet(item: $manualBugReportMailPayload, onDismiss: finishBugReportMailPresentation)",
            source,
        )
        self.assertIn(
            ".sheet(item: $manualBugReportExport, onDismiss: finishBugReportExportShare)",
            source,
        )
        self.assertNotIn(
            ".sheet(item: $manualBugReportPreparedPayload)",
            source,
        )
        self.assertIn(
            "manualBugReportPreparedPayload = payload",
            collection_body,
        )
        self.assertNotIn(
            "manualBugReportMailPayload = ProductFeedbackReportPreparation.prepare(",
            collection_body,
        )
        self.assertIn("AddressedMailComposer.capability", consent_body)
        self.assertIn("guard capability == .available else { return }", consent_body)
        self.assertIn("manualBugReportMailPayload = payload", consent_body)
        self.assertNotIn("shareText = AndroidBugReportDiagnostic.manualReport()", source)
        self.assertIn("App id: ", preparation_source)
        self.assertIn("Operating system: ", preparation_source)
        self.assertNotIn("bug_report_app_id", preparation_source)
        self.assertNotIn("bug_report_operating_system", preparation_source)
        self.assertIn("ProductFeedbackContract.diagnosticRecipient", preparation_source)
        self.assertIn("androidBugReportDialog", report_source)

    def test_progress_settings_is_a_reader_destination_not_a_sheet(self) -> None:
        """Progress settings mirrors Android's separate activity on the reader navigation stack."""
        source = READER_VIEW.read_text(encoding="utf-8")

        self.assertNotIn("readingProgressSettings", swift_enum_cases(source, "ReaderSheet"))
        self.assertIn("readingProgressSettings", swift_enum_cases(source, "ReaderDestination"))
        self.assertIn("presentReaderDestination(.readingProgressSettings, from: window.id)", source)
        self.assertIn("case .readingProgressSettings:", source)

    def test_speak_controls_is_a_reader_destination_not_a_modal_sheet(self) -> None:
        """Android's BibleSpeakActivity must not regress into generic SwiftUI sheet ownership."""
        source = READER_VIEW.read_text(encoding="utf-8")

        self.assertNotIn("speakControls", swift_enum_cases(source, "ReaderModal"))
        self.assertIn("speakControls", swift_enum_cases(source, "ReaderDestination"))
        self.assertNotIn("presentReaderModal(.speakControls", source)
        self.assertIn("presentReaderDestination(.speakControls", source)
        self.assertIn("case .speakControls:", source)

    def test_sync_settings_is_a_reader_destination_not_a_modal_sheet(self) -> None:
        """Android SyncSettingsActivity must retain reader-stack ownership in fallback hosts."""
        source = READER_VIEW.read_text(encoding="utf-8")

        self.assertNotIn("syncSettings", swift_enum_cases(source, "ReaderModal"))
        self.assertIn("syncSettings", swift_enum_cases(source, "ReaderDestination"))
        self.assertIn("presentReaderDestination(.syncSettings", source)
        self.assertIn("case .syncSettings:", source)
        self.assertNotIn("syncSettingsDoneButton", source)

    def test_android_browser_activities_use_reader_destinations_not_modal_sheets(self) -> None:
        """Android key/search activities must preserve their captured pane on the reader stack."""
        source = READER_VIEW.read_text(encoding="utf-8")
        modal_cases = swift_enum_cases(source, "ReaderModal")
        destination_cases = swift_enum_cases(source, "ReaderDestination")

        for route in ["dictionaryBrowser", "generalBookBrowser", "mapBrowser", "epubSearch"]:
            self.assertNotIn(route, modal_cases)
            self.assertIn(route, destination_cases)
        self.assertIn("presentReaderDestinationPreservingPane(.dictionaryBrowser)", source)
        self.assertIn("presentReaderDestinationPreservingPane(.generalBookBrowser)", source)
        self.assertIn("presentReaderDestinationPreservingPane(.mapBrowser)", source)
        self.assertIn("presentReaderDestination(.epubSearch", source)
        self.assertIn("dictionaryBrowserScreen", source)
        self.assertIn("generalBookBrowserScreen", source)
        self.assertIn("mapBrowserScreen", source)
        self.assertIn("epubSearchScreen", source)

    def test_label_manager_is_a_reader_destination_not_a_modal_sheet(self) -> None:
        """Android ManageLabels must retain full activity-style reader navigation ownership."""
        source = READER_VIEW.read_text(encoding="utf-8")

        self.assertNotIn("labelManager", swift_enum_cases(source, "ReaderModal"))
        self.assertIn("labelManager", swift_enum_cases(source, "ReaderDestination"))
        self.assertIn("presentReaderDestination(.labelManager", source)
        self.assertIn("case .labelManager:", source)

    def test_ai_model_editing_uses_an_android_dialog_not_a_generic_sheet(self) -> None:
        """Android's add/edit-model AlertDialog must reuse the shared app-owned window."""
        source = AI_MODELS_VIEW.read_text(encoding="utf-8")
        dialog_source = AI_MODEL_DIALOGS.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(", source)
        self.assertIn("@State private var dialog: AIModelDialog?", source)
        self.assertIn("AIModelDialogOverlay(", source)
        self.assertIn("AndroidDialogWindow(", dialog_source)
        self.assertIn('accessibilityIdentifier: "aiModelDialogOverlay"', dialog_source)
        self.assertNotIn("Color.black.opacity", dialog_source)
        self.assertNotIn(".regularMaterial", dialog_source)
        self.assertIn("No sheet, navigation editor, menu, or system confirmation participates.", dialog_source)

    def test_ai_disclaimer_information_uses_an_android_dialog_not_a_generic_sheet(self) -> None:
        """Android's cancellable AI disclaimer AlertDialog remains app-owned on iOS."""
        source = AI_CONNECTION_SETTINGS_VIEW.read_text(encoding="utf-8")
        dialog_source = AI_CONFIGURATION_DIALOG_PRESENTATION.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(", source)
        self.assertIn("activeDialog = .disclaimerInformation", source)
        self.assertIn(".aiConfigurationDialog(", source)
        self.assertIn("case .disclaimerInformation:", dialog_source)
        self.assertIn("AIDisclaimerDialog(mode: .information, onCancel: dismissDialog)", dialog_source)
        self.assertIn("aiConfigurationDialogOverlay", dialog_source)

    def test_ai_configuration_uses_a_navigation_destination_and_acceptance_dialog(self) -> None:
        """Android AI activities must not be substituted with a generic iOS settings sheet."""
        settings_source = AI_SETTINGS_VIEW.read_text(encoding="utf-8")
        connection_source = AI_CONNECTION_SETTINGS_VIEW.read_text(encoding="utf-8")
        dialog_source = AI_CONFIGURATION_DIALOG_PRESENTATION.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(", settings_source)
        self.assertNotIn(".sheet(", connection_source)
        self.assertNotIn("NavigationLink {", settings_source)
        self.assertIn("@State private var activityRoute: AISettingsActivityRoute?", settings_source)
        self.assertIn("case .connection:", settings_source)
        self.assertIn("AIConnectionSettingsView(", settings_source)
        self.assertNotIn("NavigationLink {", connection_source)
        self.assertIn("@State private var activeActivity: AIConnectionSettingsActivity?", connection_source)
        self.assertIn("case .models:", connection_source)
        self.assertIn("AIModelsView(", connection_source)
        self.assertIn("case disclaimerAcceptance(AIConfigurationEntryRequest)", dialog_source)
        self.assertIn("case .requireAcceptance(let pendingRequest):", dialog_source)
        self.assertIn("return .disclaimerAcceptance(pendingRequest)", dialog_source)

    def test_reader_prompt_editor_uses_navigation_not_a_generic_sheet(self) -> None:
        """Android PromptEditActivity must route from the pane coordinator onto reader navigation."""
        coordinator_source = AI_READER_RUN_VIEWS.read_text(encoding="utf-8")
        pane_source = BIBLE_WINDOW_PANE.read_text(encoding="utf-8")
        reader_source = BIBLE_READER_VIEW.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(item: $coordinator.presentation)", coordinator_source)
        self.assertNotIn("AIReaderAppOwnedOverlay", coordinator_source)
        self.assertIn("struct AIReaderCoordinatorHost: View", coordinator_source)
        self.assertIn("onPresentPromptEditor: (UUID) -> Void", coordinator_source)
        self.assertIn("case .promptEditor(_, let promptID):", coordinator_source)
        self.assertIn("AIReaderPromptEditorHandoff.perform(", coordinator_source)
        self.assertIn("coordinator.presentation = nil", coordinator_source)
        self.assertIn("onShowAIPromptEditor: ((UUID) -> Void)?", pane_source)
        self.assertIn("onPresentPromptEditor: { promptID in onShowAIPromptEditor?(promptID) }", pane_source)
        self.assertIn("@State private var activeAIPromptEditorDestination", reader_source)
        self.assertIn(".navigationDestination(item: $activeAIPromptEditorDestination)", reader_source)
        self.assertIn("presentAIPromptEditor(promptID, from: window.id)", reader_source)
        self.assertIn("aiPromptEditorScreen", reader_source)

    def test_android_backup_import_uses_an_app_owned_dialog_not_a_generic_sheet(self) -> None:
        """Android's restore-or-import AlertDialog must retain direct app-owned window ownership."""
        import_export_source = IMPORT_EXPORT_VIEW.read_text(encoding="utf-8")
        dialog_source = ANDROID_DATABASE_BACKUP_IMPORT_DIALOG.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(item: $androidBackupArchive", import_export_source)
        self.assertIn("AndroidDatabaseBackupImportDialog(", import_export_source)
        self.assertIn("if let archive = androidBackupArchive", import_export_source)
        self.assertIn("struct AndroidDatabaseBackupImportDialog: View", dialog_source)
        self.assertIn("androidDatabaseBackupImportDialog", dialog_source)
        self.assertIn("guard !isApplying else { return }", dialog_source)
        self.assertIn("AndroidDatabaseBackupDialogState", dialog_source)
        self.assertIn("AndroidDatabaseBackupSectionDialogContent(", dialog_source)
        self.assertIn("AndroidMultiselectDialogContent(", dialog_source)
        self.assertIn("AndroidDecisionDialog(", dialog_source)
        self.assertIn("AndroidIndeterminateProgressDialog(", dialog_source)
        self.assertNotIn("NavigationStack {", dialog_source)
        self.assertNotIn("List {", dialog_source)
        self.assertNotIn("Section {", dialog_source)
        self.assertNotIn("Toggle(", dialog_source)
        self.assertNotIn("Picker(", dialog_source)
        self.assertNotIn("ProgressView(", dialog_source)
        self.assertNotIn(".toolbar {", dialog_source)
        self.assertNotIn(".regularMaterial", dialog_source)

    def test_android_backup_activity_uses_shared_app_owned_activity_components(self) -> None:
        """
        BackupActivity must not hide native iOS list/navigation chrome behind Android copy.

        The workflow screen is a reader destination with an app-owned activity bar, shared radio
        rows, raised buttons, and owner palette. Files and Share remain valid system boundaries in
        `ImportExportView`; the application-owned layout itself may not regress to List/Section,
        navigation-title, bordered-button, or native ProgressView presentation.
        """
        import_export_source = IMPORT_EXPORT_VIEW.read_text(encoding="utf-8")
        activity_source = ANDROID_BACKUP_RESTORE_ACTIVITY_VIEW.read_text(encoding="utf-8")

        self.assertIn("AndroidBackupRestoreActivityView(", import_export_source)
        self.assertNotIn("List {", import_export_source)
        self.assertNotIn("Section {", import_export_source)
        self.assertNotIn(".navigationTitle(", import_export_source)
        self.assertNotIn(".buttonStyle(.borderedProminent)", import_export_source)
        self.assertIn("AndroidActivityScreen(", activity_source)
        self.assertIn("AndroidActivityAccessibilityMarker(", activity_source)
        self.assertIn("BackupWorkflowOptionRow(", activity_source)
        self.assertIn("AndroidRaisedTextButton(", activity_source)
        self.assertIn("surfacePalette", activity_source)
        self.assertNotIn("ProgressView(", activity_source)
        self.assertNotIn("List {", activity_source)
        self.assertNotIn("Section {", activity_source)

    def test_android_module_backup_multiselect_uses_an_app_owned_dialog(self) -> None:
        """
        Android's module multiselect must retain ownership and shared control behavior.

        The contract rejects native iOS list/navigation/toggle presentation, requires the shared
        AppCompat dialog, checkbox row, palette, and hourglass components, and pins Android's
        unchecked initial state. A failure means either backup entry point has structurally drifted
        from `Dialogs.multiselect` even if a screenshot still resembles a modal.
        """
        import_export_source = IMPORT_EXPORT_VIEW.read_text(encoding="utf-8")
        picker_source = BIBLE_READER_MODULE_PICKER.read_text(encoding="utf-8")
        dialog_source = ANDROID_MODULE_BACKUP_EXPORT_SHEET.read_text(encoding="utf-8")
        multiselect_source = ANDROID_MULTISELECT_DIALOG_CONTENT.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(\n            isPresented: $showAndroidModuleBackupExportSheet", import_export_source)
        self.assertNotIn(".sheet(isPresented: $showModuleBackupSelection)", picker_source)
        self.assertIn("AndroidModuleBackupExportDialog(", import_export_source)
        self.assertIn("AndroidModuleBackupExportDialog(", picker_source)
        self.assertIn("struct AndroidModuleBackupExportDialog", dialog_source)
        self.assertIn("androidModuleBackupExportDialog", dialog_source)
        self.assertIn("guard !isExporting else { return }", dialog_source)
        self.assertIn("AndroidMultiselectDialogContent(", dialog_source)
        self.assertIn("AndroidCheckboxRow(", multiselect_source)
        self.assertIn("AndroidDialogSurfacePalette", multiselect_source)
        self.assertIn("AndroidIndeterminateProgressDialog(", dialog_source)
        self.assertIn("initialSelectedModuleIdentities", dialog_source)
        self.assertNotIn("NavigationStack {", dialog_source)
        self.assertNotIn("List {", dialog_source)
        self.assertNotIn("Toggle(", dialog_source)
        self.assertNotIn(".toolbar {", dialog_source)

    def test_bookmark_csv_columns_use_an_android_multiselect_dialog(self) -> None:
        """Column choice stays app-owned before the legitimate system file-export handoff."""
        list_source = BOOKMARK_LIST_VIEW.read_text(encoding="utf-8")
        dialog_source = BOOKMARK_CSV_TRANSFER_DOCUMENT.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(isPresented: $showCSVColumnSelector", list_source)
        self.assertIn("BookmarkCSVColumnSelectionView(", list_source)
        self.assertIn(".fileExporter(", list_source)
        self.assertIn("Dialogs.multiselect", dialog_source)
        self.assertIn("without a generic SwiftUI sheet", dialog_source)
        self.assertIn("androidBookmarkCSVColumnDialog", dialog_source)
        self.assertIn("@State private var selectedColumns", dialog_source)
        self.assertNotIn("@Binding var selectedColumns", dialog_source)

    def test_search_translation_picker_uses_android_multiselect_dialog_ownership(self) -> None:
        """
        Protect Android's Search/SearchResults activities and shared translation dialog ownership.

        Android `Search.showTranslationSelector` calls `Dialogs.multiselect`, retaining the Search
        activity behind it and committing only a non-empty result. The iOS overlay must keep a
        private draft, discard it on Cancel, and leave the committed translation set unchanged
        when OK follows Select none. Submitting criteria must switch to a separate SearchResults
        activity with its own actions. A failure means Search lost Android activity/dialog ownership,
        changed persisted-selection behavior, or reinvented native/iOS presentation.
        """
        source = SEARCH_VIEW.read_text(encoding="utf-8")
        multiselect_source = ANDROID_MULTISELECT_DIALOG_CONTENT.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(isPresented: $showTranslationPicker)", source)
        self.assertNotIn("List {", source)
        self.assertNotIn(".navigationTitle", source)
        self.assertNotIn("Menu {", source)
        self.assertIn("AndroidActivityScreen(", source)
        self.assertIn("if presentationStage == .results", source)
        self.assertIn("private var searchResultsContent", source)
        self.assertIn("AndroidSearchHelpDialog(", source)
        self.assertIn(".androidAnchoredPopupMenu(", source)
        self.assertIn("if showTranslationPicker", source)
        self.assertIn("searchTranslationPickerOverlay", source)
        self.assertIn("AndroidMultiselectDialogContent(", source)
        self.assertIn('accessibilityPrefix: "searchTranslationPicker"', source)
        self.assertIn("SearchTranslationPickerDraftState.opened", source)
        self.assertIn("SearchTranslationPickerDraftState(", source)
        self.assertIn(".cancelled()", source)
        self.assertIn("shouldCommitSelection = !pendingTranslationSelection.isEmpty", source)
        self.assertIn("cancelTranslationPicker()", source)
        self.assertIn("commitTranslationPickerSelection()", source)
        self.assertIn(r'"\(accessibilityPrefix)SelectToggleButton"', multiselect_source)
        self.assertIn(r'"\(accessibilityPrefix)CancelButton"', multiselect_source)
        self.assertIn(r'"\(accessibilityPrefix)ApplyButton"', multiselect_source)

    def test_remaining_ios_sheets_are_system_share_handoffs_or_platform_fallbacks(self) -> None:
        """
        Keep the post-migration sheet inventory limited to legitimate system ownership boundaries.

        Android parity forbids substituting adaptive sheets for app activities or dialogs. My
        Documents exports all pages through the system Files exporter. A single-page Share choice
        may reach the system ShareSheet only after Android's app-owned Save-or-Share decision. A
        failure means application content regained native iOS sheet ownership.
        """
        page_list_source = MY_DOCUMENT_PAGES_LIST_VIEW.read_text(encoding="utf-8")
        document_list_source = MY_DOCUMENTS_LIST_VIEW.read_text(encoding="utf-8")
        import_export_source = IMPORT_EXPORT_VIEW.read_text(encoding="utf-8")
        reader_source = READER_VIEW.read_text(encoding="utf-8")
        pane_source = BIBLE_WINDOW_PANE.read_text(encoding="utf-8")

        self.assertIn(".sheet(isPresented: $showsShareSheet", page_list_source)
        self.assertIn("ShareSheet(items: exportURLs.map", page_list_source)
        self.assertIn("showsExportDestinationDecision", page_list_source)
        self.assertIn("myDocumentPagesExportDestinationDialog", page_list_source)
        self.assertIn(".fileExporter(", page_list_source)
        self.assertNotIn(".sheet", document_list_source)
        self.assertIn("documents: documentExportDocuments", document_list_source)
        self.assertIn("AndroidMyDocumentsActivityView(", document_list_source)
        self.assertIn(".sheet(isPresented: $showExportSheet", import_export_source)
        self.assertIn("ShareSheet(items: [url]", import_export_source)
        self.assertIn(".sheet(isPresented: shareSheetBinding)", reader_source)
        self.assertIn("shareSheetContent", reader_source)
        self.assertNotIn(".sheet(item: readerDocumentChooserModalBinding)", reader_source)
        self.assertNotIn(".fullScreenCover(item: readerDocumentChooserModalBinding)", reader_source)
        self.assertNotIn(".sheet(item: $activeReaderLabelAssignmentRoute)", reader_source)
        self.assertNotIn(".fullScreenCover(item: $activeReaderLabelAssignmentRoute)", reader_source)
        self.assertNotIn(".fullScreenCover(item: $refChooserPresentation)", reader_source)
        self.assertNotIn("ReaderAppOwnedOverlay", reader_source)
        self.assertIn("readerLabelAssignmentContent(route)", reader_source)
        self.assertIn("LabelAssignmentView(", reader_source)
        self.assertIn("ReaderPassageChooserOverlay", reader_source)
        self.assertIn("documentChooserDestinationContent(", reader_source)
        self.assertNotIn(".sheet(item: $historyDialogRequest)", reader_source)
        self.assertNotIn(".sheet(item: $chapterReadHistoryDialogRequest)", reader_source)
        self.assertNotIn("UIActivityViewController", pane_source)
        self.assertIn("ctrl.onShareHtml = { html in onShareText?(html) }", pane_source)

    def test_speak_passage_range_uses_a_navigation_destination_not_a_sheet(self) -> None:
        """Android's GridChoosePassageBook flow must retain app-owned activity-style routing."""
        source = SPEAK_CONTROL_VIEW.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(isPresented: $showVerseRangeEditor", source)
        self.assertNotIn(".navigationDestination(isPresented: $showVerseRangeEditor)", source)
        self.assertIn("private var destinationLayer", source)
        self.assertIn("case .verseRange:", source)
        self.assertIn("SpeakVerseRangeEditor(", source)
        self.assertIn("BookChooserView(", source)
        self.assertIn("two `GridChoosePassageBook` requests", source)
        self.assertIn("speak_beginning_of_passage", source)
        self.assertIn("speak_ending_of_passage", source)

    def test_my_document_page_editing_uses_an_android_dialog_not_a_sheet(self) -> None:
        """Android's native create-page dialog keeps Save/Cancel state app-owned."""
        list_source = MY_DOCUMENT_PAGES_LIST_VIEW.read_text(encoding="utf-8")
        editor_source = MY_DOCUMENT_PAGE_EDITOR.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(item: $editorRequest)", list_source)
        self.assertIn("if let editorRequest", list_source)
        self.assertIn("onCancel: { self.editorRequest = nil }", list_source)
        self.assertIn("androidMyDocumentPageEditorDialog", editor_source)
        self.assertIn("onCancel: () -> Void", editor_source)
        self.assertIn("myDocumentPageEditorSaveButton", editor_source)
        self.assertIn("AndroidDialogWindow(", editor_source)
        self.assertIn("AndroidPopupMenuSurface(", editor_source)
        self.assertNotIn("TextEditor", editor_source)
        self.assertNotIn("Picker(", editor_source)

    def test_my_documents_routes_use_android_activity_components_not_ios_collections(self) -> None:
        """Document and page managers must retain Android activity/list/menu ownership."""
        document_owner = MY_DOCUMENTS_LIST_VIEW.read_text(encoding="utf-8")
        page_owner = MY_DOCUMENT_PAGES_LIST_VIEW.read_text(encoding="utf-8")
        document_activity = ANDROID_MY_DOCUMENTS_ACTIVITY_VIEW.read_text(encoding="utf-8")
        page_activity = ANDROID_MY_DOCUMENT_PAGES_ACTIVITY_VIEW.read_text(encoding="utf-8")

        self.assertIn("AndroidMyDocumentsActivityView(", document_owner)
        self.assertIn("AndroidMyDocumentPagesActivityView(", page_owner)
        for source in (document_owner, page_owner, document_activity, page_activity):
            self.assertNotIn("List {", source)
            self.assertNotIn("Form {", source)
            self.assertNotIn("NavigationStack {", source)
            self.assertNotIn("Menu {", source)
            self.assertNotIn(".contextMenu", source)
            self.assertNotIn(".swipeActions", source)

        self.assertIn("AndroidActivityScreen(", document_activity)
        self.assertIn("AndroidActivityAccessibilityMarker(", document_activity)
        self.assertIn("AndroidActivityCommitBar(", document_activity)
        self.assertIn("AndroidPopupMenuSurface(", document_activity)
        self.assertIn("AndroidActivityScreen(", page_activity)
        self.assertIn("AndroidActivityAccessibilityMarker(", page_activity)
        self.assertIn("AndroidActivityCommitBar(", page_activity)
        self.assertIn("AndroidPopupMenuSurface(", page_activity)

    def test_reader_help_uses_an_android_dialog_not_a_generic_sheet(self) -> None:
        """BibleView help reuses Android's shared in-place dialog owner and palette."""
        pane_source = BIBLE_WINDOW_PANE.read_text(encoding="utf-8")
        dialog_source = AI_READER_HELP_PRESENTATION.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(item: $readerHelpPresentation)", pane_source)
        self.assertIn("if let readerHelpPresentation", pane_source)
        self.assertIn("AIReaderHelpDialog(", pane_source)
        self.assertIn("onDismiss: { self.readerHelpPresentation = nil }", pane_source)
        self.assertNotIn("@Environment(\\.dismiss)", dialog_source)
        self.assertNotIn(".presentationDetents", dialog_source)
        self.assertIn("AndroidDialogWindow(", dialog_source)
        self.assertIn('accessibilityIdentifier: "androidAIReaderHelpDialog"', dialog_source)
        self.assertIn("AndroidDialogScaffold(", dialog_source)
        self.assertIn("AndroidDialogTextAction(", dialog_source)
        self.assertNotIn("Color.black.opacity", dialog_source)
        self.assertNotIn(".regularMaterial", dialog_source)

    def test_reader_ai_prompt_selection_uses_coordinator_owned_app_surfaces(self) -> None:
        """AI routes remain pane-owned without regressing to adaptive iOS sheets."""
        source = AI_READER_RUN_VIEWS.read_text(encoding="utf-8")
        dialog_source = AI_READER_TRANSIENT_DIALOGS.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(item: $coordinator.presentation)", source)
        self.assertNotIn(".fullScreenCover(item: $rawLogSnapshot)", source)
        self.assertNotIn("AIReaderAppOwnedOverlay", source)
        self.assertIn("struct AIReaderCoordinatorHost: View", source)
        self.assertIn("switch coordinator.presentation", source)
        self.assertIn("case .promptChooser:", source)
        self.assertIn("AIReaderPromptChooserDialog(coordinator: coordinator)", source)
        self.assertIn("AIReaderPromptPreparationDialog(coordinator: coordinator)", source)
        self.assertIn("AIReaderRegenerationDialog(coordinator: coordinator)", source)
        self.assertIn("AIReaderDocumentMarkerDialog(coordinator: coordinator)", source)
        self.assertIn("AIReaderAgentLogWidget(", source)
        self.assertNotIn("NavigationStack {", source)
        self.assertIn("coordinator.presentation = nil", source)
        self.assertIn("AndroidDialogWindow(", dialog_source)
        self.assertIn("AndroidDialogScaffold(", dialog_source)
        self.assertIn("coordinator.selectPrompt(entry)", dialog_source)

    def test_drawer_progress_restores_android_last_tab_without_reusing_bridge_state(self) -> None:
        """Drawer launches must restore Android's persisted tab while bridge launches remain explicit."""
        source = READER_VIEW.read_text(encoding="utf-8")
        progress_source = READING_PROGRESS_VIEW.read_text(encoding="utf-8")
        drawer_handler = swift_function_body(source, "handleReaderNavigationDrawerAction")
        progress_body = swift_switch_case_body(drawer_handler, "readingProgress")

        self.assertIn("presentReadingProgress(initialTab: nil", progress_body)
        self.assertIn("@AppStorage(\"reading_progress_last_tab\")", progress_source)
        self.assertIn("initialTab ?? persistedTab", progress_source)
        self.assertIn(".onChange(of: selectedTab)", progress_source)

    def test_progress_screen_exposes_android_settings_and_help_actions(self) -> None:
        """The progress activity's Settings and Help actions remain inside its navigation context."""
        source = READER_VIEW.read_text(encoding="utf-8")
        progress_source = READING_PROGRESS_VIEW.read_text(encoding="utf-8")
        activity_source = ANDROID_READING_PROGRESS_ACTIVITY_VIEW.read_text(encoding="utf-8")
        settings_source = ANDROID_READING_PROGRESS_SETTINGS_VIEW.read_text(encoding="utf-8")
        feature_help_source = ANDROID_FEATURE_HELP_DIALOG.read_text(encoding="utf-8")

        self.assertIn("readingProgressSettingsAction", activity_source)
        self.assertIn("readingProgressHelpAction", activity_source)
        self.assertIn("AndroidPopupMenuSurface", activity_source)
        self.assertIn("AndroidFixedTabRow", activity_source)
        self.assertIn("AndroidFeatureHelpDialog(", progress_source)
        self.assertIn("topic: .readingProgress", progress_source)
        self.assertIn('localized: "help_reading_progress_text"', feature_help_source)
        self.assertIn('path = "reading_progress.html"', feature_help_source)
        self.assertIn("ReadingProgressSettingsView(", source)
        self.assertIn("surfacePalette: readerThemeSurfacePalette", source)
        self.assertIn("AndroidSwitchPreferenceRow", settings_source)
        self.assertIn("AndroidSingleChoiceDialog", settings_source)

    def test_progress_activity_and_settings_forbid_native_ios_presentation_primitives(self) -> None:
        """Progress routes must remain app-owned activities/dialogs, not cosmetically adapted forms."""
        progress_source = READING_PROGRESS_VIEW.read_text(encoding="utf-8")
        activity_source = ANDROID_READING_PROGRESS_ACTIVITY_VIEW.read_text(encoding="utf-8")
        settings_source = ANDROID_READING_PROGRESS_SETTINGS_VIEW.read_text(encoding="utf-8")
        combined = "\n".join((progress_source, activity_source, settings_source))

        for forbidden in (
            "Form {",
            "List {",
            "Section(",
            "NavigationStack",
            "NavigationLink",
            "Menu {",
            ".sheet(",
            ".popover(",
            ".regularMaterial",
            ".pickerStyle(.segmented)",
        ):
            self.assertNotIn(forbidden, combined)
        self.assertNotRegex(combined, r"\bPicker\(")
        self.assertNotRegex(combined, r"\bToggle\(")
        self.assertNotRegex(combined, r"\bProgressView\(")

        self.assertIn("AndroidReadingProgressActivityView", progress_source)
        self.assertIn("AndroidDeterminateProgressIndicator", progress_source)
        self.assertIn("AndroidReadHistoryDialog", progress_source)
        self.assertIn("LongPressGesture", progress_source)
        self.assertIn("AndroidActivityScreen(", settings_source)
        self.assertIn("AndroidActivityAccessibilityMarker(", settings_source)
        self.assertNotIn("auto_track_reading", settings_source)

        # Android builds these rows and grids from TextView/GridLayout primitives. Keep the
        # source-backed contracts exact instead of reintroducing iOS symbols or invented state.
        self.assertNotIn("Image(systemName:", progress_source)
        self.assertNotIn("Color.accentColor", progress_source)
        self.assertNotIn("Divider()", progress_source)
        self.assertNotIn("let selectedOsisId", progress_source)
        self.assertNotIn('localized: "old_testament"', progress_source)
        self.assertNotIn('localized: "new_testament"', progress_source)
        self.assertIn('Text("×")', progress_source)
        self.assertIn('localized: "reading_progress_old_testament"', progress_source)
        self.assertIn('localized: "reading_progress_new_testament"', progress_source)
        self.assertIn(
            "private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 10)",
            progress_source,
        )

    def test_destination_owned_reader_routes_cannot_fall_back_to_legacy_ios_presentations(self) -> None:
        """
        Prevent Android app-owned destination screens from regressing into iOS sheet chrome.

        Bookmarks, StudyPads, and Reading Plans can be launched from several reader surfaces:
        drawer, pane menus, overflow callbacks, keyboard shortcuts, and chooser pseudo-documents.
        Android treats each as an app-owned screen, so iOS must keep those routes on
        `ReaderDestination` instead of preserving legacy `ReaderSheet` or nested modal cases.
        A failure means a route was reintroduced through one of the sibling entry points and the
        user will see platform sheet behavior again.
        """
        source = READER_VIEW.read_text(encoding="utf-8")

        sheet_cases = swift_enum_cases(source, "ReaderSheet")
        modal_cases = swift_enum_cases(source, "ReaderModal")

        self.assertNotIn("bookmarks", sheet_cases)
        self.assertNotIn("readingPlans", sheet_cases)
        self.assertNotIn("readingProgress", sheet_cases)
        self.assertNotIn("studyPadSelector", modal_cases)
        self.assertNotIn("importExport", modal_cases)

        self.assertNotIn("presentReaderSheet(.bookmarks", source)
        self.assertNotIn("presentReaderSheet(.readingPlans", source)
        self.assertNotRegex(source, r"presentReaderSheet\(\.readingProgress(?!Settings)")
        self.assertNotIn("presentReaderModal(.importExport", source)
        self.assertNotIn("presentReaderModalPreservingPane(.studyPadSelector", source)
        self.assertIn("presentReaderDestination(.bookmarks", source)
        self.assertIn("presentReaderDestination(.readingPlans", source)
        self.assertIn("presentReaderDestination(.readingProgress", source)
        self.assertIn("presentReaderDestination(.importExport", source)
        self.assertIn("onOpenStudyPadSelector: presentStudyPadsDestinationPreservingPane", source)

    def test_known_partial_routes_link_to_their_follow_up_issues(self) -> None:
        """
        Keep incomplete reader modal routes tied to explicit follow-up work.

        Android parity is not satisfied by labeling an iOS sheet as native.
        Routes listed here intentionally remain partial, so their issue
        references must stay visible in the disposition until the owning
        behavior is migrated or completed. Completed chooser routes should not
        remain in this sentinel because that would normalize stale partial-parity
        language.
        """
        expected_issues: dict[str, str] = {}

        for token, issue in expected_issues.items():
            self.assertIn(issue, route_contract(token).disposition)

    def test_contracts_link_back_to_durable_modal_ownership_adrs(self) -> None:
        """The source-backed route contracts stay tied to the durable ownership ADRs."""
        modal_ownership_adr = ADR_0006.read_text(encoding="utf-8")
        documentation_adr = ADR_0008.read_text(encoding="utf-8")

        self.assertIn("Modal Presentation Ownership For Android Parity", modal_ownership_adr)
        self.assertIn("ADR 0006", documentation_adr)


if __name__ == "__main__":
    unittest.main()
