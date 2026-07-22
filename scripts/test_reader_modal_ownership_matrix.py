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
READING_PLAN_START_DATE_DIALOG = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "ReadingPlans"
    / "AndroidReadingPlanStartDateDialog.swift"
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
ANDROID_DATABASE_BACKUP_IMPORT_SHEET = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Settings"
    / "AndroidDatabaseBackupImportSheet.swift"
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
BIBLE_READER_MODULE_PICKER = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Bible"
    / "BibleReaderModulePicker.swift"
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
    "ReaderDestination.syncSettings": (
        "Android app-owned",
        "Android SyncSettingsActivity-equivalent reader navigation route.",
    ),
    "ReaderModal.modulePicker": (
        "Android app-owned",
        "App-owned full-screen route.",
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
    "ReaderDestination.epubLibrary": (
        "Android app-owned",
        "App-owned EPUB library route.",
    ),
    "ReaderDestination.epubSearch": (
        "Android app-owned",
        "Android EpubSearch-equivalent reader navigation route.",
    ),
    "ReaderDestination.labelManager": (
        "Android app-owned",
        "Android ManageLabels-equivalent reader navigation route.",
    ),
    "ReaderModal.chooseDocument": (
        "Android app-owned",
        "App-owned full-screen route.",
    ),
    "helpDialogOverlay": (
        "Android app-owned",
        "Android Help & Tips dialog rendered outside generic adaptive sheet ownership.",
    ),
    "licenseDialogOverlay": (
        "Android app-owned",
        "Android Open Source License dialog renders bundled GPL text without a browser handoff.",
    ),
    "rateReviewDialogOverlay": (
        "Android app-owned plus iOS system boundary",
        "Android explanatory Rate & Review dialog precedes the legitimate iOS review-controller handoff.",
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
ANDROID_MANIFEST = "app/src/main/AndroidManifest.xml"
ANDROID_HISTORY = "app/src/main/java/net/bible/android/view/activity/navigation/History.kt"
ANDROID_PROGRESS = "app/src/main/java/net/bible/android/view/activity/progress/ReadingProgressActivity.kt"
ANDROID_READ_HISTORY = "app/src/main/java/net/bible/android/view/activity/progress/ReadHistoryDialog.kt"
ANDROID_SEARCH = "app/src/main/java/net/bible/android/view/activity/search/Search.kt"
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
        "ReaderDestination.startupDocumentSetup",
        "ReaderDestination.globalTextOptions",
        "ReaderDestination.workspaceTextOptions",
        "ReaderDestination.windowTextOptions",
        "ReaderDestination.windowColorSettings",
        "ReaderDestination.syncSettings",
        source=ANDROID_MAIN_MENU,
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
        "ReaderDestination.epubLibrary",
        "ReaderDestination.mapBrowser",
        "ReaderDestination.epubSearch",
        "ReaderDestination.labelManager",
        source=ANDROID_MANIFEST,
        surface="reader navigation destination",
    ),
    **route_keys(
        "ReaderModal.modulePicker",
        "ReaderModal.chooseDocument",
        source=ANDROID_MAIN_ACTIVITY,
        surface="full-screen app-owned chooser",
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
        "rateReviewDialogOverlay",
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
            "rateReviewDialogOverlay",
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
            "ReaderModal.chooseDocument": "Android app-owned",
            "ReaderModal.modulePicker": "Android app-owned",
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
        """Android's DatePickerDialog must not regress into an adaptive SwiftUI sheet."""
        daily_reading_source = DAILY_READING_VIEW.read_text(encoding="utf-8")
        dialog_source = READING_PLAN_START_DATE_DIALOG.read_text(encoding="utf-8")

        self.assertIn("AndroidReadingPlanStartDateDialog", daily_reading_source)
        self.assertNotIn(".sheet(isPresented: $showStartDatePicker)", daily_reading_source)
        self.assertIn("in: ...Date()", dialog_source)
        self.assertIn("androidReadingPlanStartDateDialog", dialog_source)
        self.assertIn("dailyReadingStartDateCancelButton", dialog_source)
        self.assertIn("dailyReadingStartDateDoneButton", dialog_source)

    def test_read_history_is_a_captured_staged_delete_dialog_not_a_reader_sheet(self) -> None:
        """Read History must retain Android dialog dismissal semantics instead of sheet ownership."""
        source = READER_VIEW.read_text(encoding="utf-8")

        self.assertNotIn("chapterReadHistory", swift_enum_cases(source, "ReaderSheet"))
        self.assertIn("chapterReadHistoryDialogRequest", source)
        self.assertIn("ChapterReadHistoryDialogRequest", source)
        self.assertIn("AndroidChapterReadHistoryDialog", source)
        self.assertIn("presentChapterReadHistoryDialog(target: target, from: window.id)", source)

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

    def test_rate_review_requires_an_android_dialog_before_system_review(self) -> None:
        """Rate & Review must retain Android's support/cancel choice before the system handoff."""
        source = READER_VIEW.read_text(encoding="utf-8")
        drawer_handler = swift_function_body(source, "handleReaderNavigationDrawerAction")
        rate_body = swift_switch_case_body(drawer_handler, "rateApp")
        rate_dialog = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Shared"
            / "AndroidRateReviewDialog.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("presentRateReviewDialog", rate_body)
        self.assertNotIn("SKStoreReviewController", rate_body)
        self.assertIn("rateReviewDialogOverlay", source)
        self.assertIn("AndroidRateReviewDialog", source)
        self.assertIn("proceedToSystemReview", source)
        self.assertIn("SKStoreReviewController.requestReview", source)
        self.assertIn("onContactSupport", rate_dialog)
        self.assertIn("onReportBug", rate_dialog)
        self.assertIn("onDismiss", rate_dialog)

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

        self.assertIn("presentBugReportDialog", report_body)
        self.assertNotIn("openExternalLink", report_body)
        self.assertIn("bugReportDialogOverlay", source)
        self.assertIn("manualBugReportState", source)
        self.assertIn("ProductFeedbackReportPreparation.prepare()", source)
        self.assertIn("presentPreparedBugReport", source)
        self.assertIn("AddressedMailComposer", source)
        self.assertNotIn("shareText = AndroidBugReportDiagnostic.manualReport()", source)
        self.assertIn("App id:", preparation_source)
        self.assertIn("Operating system:", preparation_source)
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

        for route in ["dictionaryBrowser", "generalBookBrowser", "epubLibrary", "mapBrowser", "epubSearch"]:
            self.assertNotIn(route, modal_cases)
            self.assertIn(route, destination_cases)
        self.assertIn("presentReaderDestinationPreservingPane(.dictionaryBrowser)", source)
        self.assertIn("presentReaderDestinationPreservingPane(.generalBookBrowser)", source)
        self.assertIn("presentReaderDestinationPreservingPane(.mapBrowser)", source)
        self.assertIn("presentReaderDestination(.epubLibrary", source)
        self.assertIn("presentReaderDestination(.epubSearch", source)
        self.assertIn("dictionaryBrowserScreen", source)
        self.assertIn("generalBookBrowserScreen", source)
        self.assertIn("epubLibraryScreen", source)
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
        """Android's add/edit-model AlertDialog must stay app-owned on iOS."""
        source = AI_MODELS_VIEW.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(", source)
        self.assertIn("@State private var dialog: AIModelDialog?", source)
        self.assertIn("AIModelDialogOverlay(", source)
        self.assertIn("accessibilityIdentifier(\"aiModelDialogOverlay\")", AI_MODEL_DIALOGS.read_text(encoding="utf-8"))
        self.assertIn("No sheet, navigation editor, menu, or system confirmation participates.", AI_MODEL_DIALOGS.read_text(encoding="utf-8"))

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
        self.assertIn("NavigationLink {", settings_source)
        self.assertIn("AIConnectionSettingsView(", settings_source)
        self.assertIn("NavigationLink {", connection_source)
        self.assertIn("AIModelsView()", connection_source)
        self.assertIn("case disclaimerAcceptance(AIConfigurationEntryRequest)", dialog_source)
        self.assertIn("case .requireAcceptance(let pendingRequest):", dialog_source)
        self.assertIn("return .disclaimerAcceptance(pendingRequest)", dialog_source)

    def test_reader_prompt_editor_uses_navigation_not_a_generic_sheet(self) -> None:
        """Android PromptEditActivity must route from the pane coordinator onto reader navigation."""
        coordinator_source = AI_READER_RUN_VIEWS.read_text(encoding="utf-8")
        pane_source = BIBLE_WINDOW_PANE.read_text(encoding="utf-8")
        reader_source = BIBLE_READER_VIEW.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(item: $coordinator.presentation)", coordinator_source)
        self.assertIn("AIReaderAppOwnedOverlay", coordinator_source)
        self.assertIn("onPresentPromptEditor: (UUID) -> Void", coordinator_source)
        self.assertIn("case .promptEditor(_, let promptID):", coordinator_source)
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
        dialog_source = ANDROID_DATABASE_BACKUP_IMPORT_SHEET.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(item: $androidBackupArchive", import_export_source)
        self.assertIn("AndroidDatabaseBackupImportDialog(", import_export_source)
        self.assertIn("if let archive = androidBackupArchive", import_export_source)
        self.assertIn("struct AndroidDatabaseBackupImportDialog: View", dialog_source)
        self.assertIn("androidDatabaseBackupImportDialog", dialog_source)
        self.assertIn("guard !isApplying else { return }", dialog_source)
        self.assertIn("AndroidDatabaseBackupImportSheet(", dialog_source)

    def test_android_module_backup_multiselect_uses_an_app_owned_dialog(self) -> None:
        """Android's module multiselect must retain ownership in both backup entry points."""
        import_export_source = IMPORT_EXPORT_VIEW.read_text(encoding="utf-8")
        picker_source = BIBLE_READER_MODULE_PICKER.read_text(encoding="utf-8")
        dialog_source = ANDROID_MODULE_BACKUP_EXPORT_SHEET.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(\n            isPresented: $showAndroidModuleBackupExportSheet", import_export_source)
        self.assertNotIn(".sheet(isPresented: $showModuleBackupSelection)", picker_source)
        self.assertIn("AndroidModuleBackupExportDialog(", import_export_source)
        self.assertIn("AndroidModuleBackupExportDialog(", picker_source)
        self.assertIn("struct AndroidModuleBackupExportDialog", dialog_source)
        self.assertIn("androidModuleBackupExportDialog", dialog_source)
        self.assertIn("guard !isExporting else { return }", dialog_source)

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
        Protect Android's in-place Search translation dialog rather than a generic sheet substitute.

        Android `Search.showTranslationSelector` calls `Dialogs.multiselect`, retaining the Search
        activity behind it and committing only a non-empty result. The iOS overlay must keep a
        private draft, discard it on Cancel, and leave the committed translation set unchanged
        when OK follows Select none. A failure means Search would lose Android dialog ownership or
        change its persisted-selection behavior.
        """
        source = SEARCH_VIEW.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(isPresented: $showTranslationPicker)", source)
        self.assertIn("if showTranslationPicker", source)
        self.assertIn("searchTranslationPickerOverlay", source)
        self.assertIn("SearchTranslationPickerDraftState.opened", source)
        self.assertIn("SearchTranslationPickerDraftState(", source)
        self.assertIn(".cancelled()", source)
        self.assertIn("shouldCommitSelection = !pendingTranslationSelection.isEmpty", source)
        self.assertIn("cancelTranslationPicker()", source)
        self.assertIn("commitTranslationPickerSelection()", source)
        self.assertIn("searchTranslationPickerOverlay", source)
        self.assertIn("searchTranslationCancelButton", source)
        self.assertIn("searchTranslationOKButton", source)

    def test_remaining_ios_sheets_are_system_share_handoffs_or_platform_fallbacks(self) -> None:
        """
        Keep the post-migration sheet inventory limited to legitimate system ownership boundaries.

        Android parity forbids substituting adaptive sheets for app activities or dialogs. The only
        remaining reader sheet call is the system ShareSheet handoff. A failure means a new
        app-owned sheet needs an Android source contract and an explicit owner decision before it
        can ship.
        """
        page_list_source = MY_DOCUMENT_PAGES_LIST_VIEW.read_text(encoding="utf-8")
        document_list_source = MY_DOCUMENTS_LIST_VIEW.read_text(encoding="utf-8")
        import_export_source = IMPORT_EXPORT_VIEW.read_text(encoding="utf-8")
        reader_source = READER_VIEW.read_text(encoding="utf-8")
        pane_source = BIBLE_WINDOW_PANE.read_text(encoding="utf-8")

        self.assertIn(".sheet(isPresented: $showsExport)", page_list_source)
        self.assertIn("ShareSheet(items: exportURLs.map", page_list_source)
        self.assertIn(".sheet(isPresented: $showsExport)", document_list_source)
        self.assertIn("ShareSheet(items: exportURLs.map", document_list_source)
        self.assertIn(".sheet(isPresented: $showExportSheet", import_export_source)
        self.assertIn("ShareSheet(items: [url]", import_export_source)
        self.assertIn(".sheet(isPresented: shareSheetBinding)", reader_source)
        self.assertIn("shareSheetContent", reader_source)
        self.assertNotIn(".sheet(item: readerDocumentChooserModalBinding)", reader_source)
        self.assertNotIn(".fullScreenCover(item: readerDocumentChooserModalBinding)", reader_source)
        self.assertNotIn(".sheet(item: $activeReaderLabelAssignmentRoute)", reader_source)
        self.assertNotIn(".fullScreenCover(item: $activeReaderLabelAssignmentRoute)", reader_source)
        self.assertNotIn(".fullScreenCover(item: $refChooserPresentation)", reader_source)
        self.assertIn("ReaderAppOwnedOverlay", reader_source)
        self.assertIn('accessibilityIdentifier("androidReaderAppOwnedOverlay")', reader_source)
        self.assertNotIn(".sheet(item: $historyDialogRequest)", reader_source)
        self.assertNotIn(".sheet(item: $chapterReadHistoryDialogRequest)", reader_source)
        self.assertNotIn("UIActivityViewController", pane_source)
        self.assertIn("ctrl.onShareHtml = { html in onShareText?(html) }", pane_source)

    def test_speak_passage_range_uses_a_navigation_destination_not_a_sheet(self) -> None:
        """Android's GridChoosePassageBook flow must retain full activity-style navigation."""
        source = SPEAK_CONTROL_VIEW.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(isPresented: $showVerseRangeEditor", source)
        self.assertIn(".navigationDestination(isPresented: $showVerseRangeEditor)", source)
        self.assertIn("two `GridChoosePassageBook` passage picks", source)
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

    def test_reader_help_uses_an_android_dialog_not_a_generic_sheet(self) -> None:
        """BibleView help uses Android's in-place dialog owner instead of adaptive sheet chrome."""
        pane_source = BIBLE_WINDOW_PANE.read_text(encoding="utf-8")
        dialog_source = AI_READER_HELP_PRESENTATION.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(item: $readerHelpPresentation)", pane_source)
        self.assertIn("if let readerHelpPresentation", pane_source)
        self.assertIn("AIReaderHelpDialog(", pane_source)
        self.assertIn("onDismiss: { self.readerHelpPresentation = nil }", pane_source)
        self.assertNotIn("@Environment(\\.dismiss)", dialog_source)
        self.assertNotIn(".presentationDetents", dialog_source)
        self.assertIn("androidAIReaderHelpDialog", dialog_source)
        self.assertIn("Color.black.opacity(0.36)", dialog_source)
        self.assertIn("Button(String(localized: \"okay\"), action: onDismiss)", dialog_source)

    def test_reader_ai_prompt_selection_uses_coordinator_owned_app_surfaces(self) -> None:
        """AI routes remain pane-owned without regressing to adaptive iOS sheets."""
        source = AI_READER_RUN_VIEWS.read_text(encoding="utf-8")

        self.assertNotIn(".sheet(item: $coordinator.presentation)", source)
        self.assertNotIn(".fullScreenCover(item: $rawLogSnapshot)", source)
        self.assertIn("AIReaderAppOwnedOverlay", source)
        self.assertIn("switch coordinator.presentation", source)
        self.assertIn("case .promptChooser:", source)
        self.assertIn("AIReaderPromptChooserView(coordinator: coordinator)", source)
        self.assertIn("AIReaderPromptPreparationView(coordinator: coordinator)", source)
        self.assertIn("AIReaderRegenerationView(coordinator: coordinator)", source)
        self.assertIn("AIReaderDocumentMarkerChooserView(coordinator: coordinator)", source)
        self.assertIn("AIReaderRunActivityView(coordinator: coordinator)", source)
        self.assertIn('accessibilityIdentifier("androidAIReaderAppOwnedOverlay")', source)
        self.assertIn("NavigationStack {", source)
        self.assertIn("coordinator.presentation = nil", source)
        self.assertIn("coordinator.selectPrompt(entry)", source)

    def test_drawer_progress_restores_android_last_tab_without_reusing_bridge_state(self) -> None:
        """Drawer launches must restore Android's persisted tab while bridge launches remain explicit."""
        source = READER_VIEW.read_text(encoding="utf-8")
        progress_source = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Bible"
            / "ReadingProgressViews.swift"
        ).read_text(encoding="utf-8")
        drawer_handler = swift_function_body(source, "handleReaderNavigationDrawerAction")
        progress_body = swift_switch_case_body(drawer_handler, "readingProgress")

        self.assertIn("presentReadingProgress(initialTab: nil", progress_body)
        self.assertIn("@AppStorage(\"reading_progress_last_tab\")", progress_source)
        self.assertIn("initialTab ?? persistedTab", progress_source)
        self.assertIn(".onChange(of: selectedTab)", progress_source)

    def test_progress_screen_exposes_android_settings_and_help_actions(self) -> None:
        """The progress activity's Settings and Help actions remain inside its navigation context."""
        source = READER_VIEW.read_text(encoding="utf-8")
        progress_source = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Bible"
            / "ReadingProgressViews.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("readingProgressSettingsAction", progress_source)
        self.assertIn("ReadingProgressSettingsView(controller: settingsController)", progress_source)
        self.assertIn("readingProgressHelpAction", progress_source)
        self.assertIn('localized: "help_reading_progress_text"', progress_source)
        self.assertIn("settingsController: panePresentationController", source)

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
