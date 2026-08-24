#!/usr/bin/env python3
"""
Unit tests for repo standards guardrails.
"""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_repo_standards import (
    find_legacy_root_sidebar_shell,
    find_multiline_slash_docblocks,
    find_ios_bundle_version_reads,
    find_unshared_addon_feature_discovery,
    find_unsafe_direct_document_publishers,
    validate_commit_message,
    validate_source_guards,
)


class RepoStandardsTests(unittest.TestCase):
    """Covers commit, docblock, and production-source guard contracts.

    Tests use in-memory snippets plus context-managed temporary repository fixtures where a
    path-sensitive scan is required. Failures mean the guardrails can reject valid source or permit
    a known architecture/parity regression. Temporary fixtures are removed by their context owners.
    """

    def test_valid_commit_message_passes(self) -> None:
        message = "\n".join(
            [
                "docs(sync): document operator workflow",
                "",
                "Why:",
                "- Operators need a stable reference.",
                "",
                "What Changed:",
                "- Added the sync workflow doc.",
                "",
                "Validation:",
                "- Reviewed the existing flow against the app code.",
                "",
                "Impact:",
                "- Reduces operator ambiguity.",
            ]
        )
        self.assertEqual(validate_commit_message("abc123", message), [])

    def test_commit_message_requires_blank_line_and_sections(self) -> None:
        message = "\n".join(
            [
                "docs(sync): document operator workflow",
                "Why:",
                "- Missing blank line.",
            ]
        )
        issues = validate_commit_message("abc123", message)
        messages = [issue.message for issue in issues]
        self.assertIn("subject must be followed by one blank line", messages)
        self.assertIn("missing required section What Changed:", messages)
        self.assertIn("missing required section Validation:", messages)
        self.assertIn("missing required section Impact:", messages)

    def test_commit_message_rejects_invalid_subject(self) -> None:
        message = "\n".join(
            [
                "update sync docs",
                "",
                "Why:",
                "none",
                "",
                "What Changed:",
                "none",
                "",
                "Validation:",
                "none",
                "",
                "Impact:",
                "none",
            ]
        )
        issues = validate_commit_message("abc123", message)
        self.assertTrue(any("subject must match" in issue.message for issue in issues))

    def test_commit_message_rejects_forbidden_coauthor_trailer(self) -> None:
        message = "\n".join(
            [
                "docs(sync): document operator workflow",
                "",
                "Why:",
                "none",
                "",
                "What Changed:",
                "none",
                "",
                "Validation:",
                "none",
                "",
                "Impact:",
                "none",
                "",
                "Co-authored-by: Example <example@example.com>",
            ]
        )
        issues = validate_commit_message("abc123", message)
        self.assertTrue(any("Co-authored-by" in issue.message for issue in issues))

    def test_find_multiline_slash_docblocks_flags_consecutive_lines(self) -> None:
        text = "\n".join(
            [
                "/// First line",
                "/// Second line",
                "func example() {}",
            ]
        )
        self.assertEqual(find_multiline_slash_docblocks(text), [1])

    def test_find_ios_bundle_version_reads_enforces_display_only_owner(self) -> None:
        forbidden = "\n".join(
            [
                'let local = bundle.infoDictionary?["CFBundleVersion"]',
                'let release = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")',
            ]
        )
        self.assertEqual(
            find_ios_bundle_version_reads(
                forbidden,
                "Sources/BibleCore/Sources/BibleCore/Services/AndroidBackupManifestCodec.swift",
            ),
            [1, 2],
        )
        self.assertEqual(
            find_ios_bundle_version_reads(
                forbidden,
                "Sources/BibleUI/Sources/BibleUI/Shared/AndBibleAppVersionMetadata.swift",
            ),
            [],
        )

    def test_find_multiline_slash_docblocks_allows_single_line_comment(self) -> None:
        text = "\n".join(
            [
                "/// Single line",
                "func example() {}",
            ]
        )
        self.assertEqual(find_multiline_slash_docblocks(text), [])

    def test_find_multiline_slash_docblocks_reports_multiple_blocks(self) -> None:
        text = "\n".join(
            [
                "/// One",
                "/// Two",
                "func first() {}",
                "",
                "/// Three",
                "/// Four",
                "/// Five",
                "func second() {}",
            ]
        )
        self.assertEqual(find_multiline_slash_docblocks(text), [1, 5])

    def test_find_legacy_root_sidebar_shell_flags_colocated_sidebar_identifiers(self) -> None:
        text = "\n".join(
            [
                "struct ContentView: View {",
                "    var body: some View {",
                "        NavigationSplitView {",
                "            contentTabBible",
                "            contentSettingsLink",
                "        } detail: {",
                "            BibleReaderView()",
                "        }",
                "    }",
                "}",
            ]
        )
        self.assertEqual(find_legacy_root_sidebar_shell(text), [3])

    def test_find_legacy_root_sidebar_shell_flags_long_colocated_sidebar_block(self) -> None:
        text = "\n".join(
            [
                "NavigationSplitView {",
                "    contentTabBible",
                "    let filler = \"" + ("x" * 2_000) + "\"",
                "    contentSettingsLink",
                "} detail: {",
                "    BibleReaderView()",
                "}",
            ]
        )
        self.assertEqual(find_legacy_root_sidebar_shell(text), [1])

    def test_find_legacy_root_sidebar_shell_allows_separate_navigation_regions(self) -> None:
        text = "\n".join(
            [
                "NavigationSplitView {",
                "    contentTabBible",
                "}",
                "NavigationSplitView {",
                "    contentSettingsLink",
                "}",
            ]
        )
        self.assertEqual(find_legacy_root_sidebar_shell(text), [])

    def test_find_legacy_root_sidebar_shell_ignores_comments_and_strings(self) -> None:
        text = "\n".join(
            [
                "NavigationSplitView {",
                "    contentTabBible",
                "    // contentSettingsLink",
                "    Text(\"contentSettingsLink\")",
                "} detail: {",
                "    BibleReaderView()",
                "}",
            ]
        )
        self.assertEqual(find_legacy_root_sidebar_shell(text), [])

    def test_find_unsafe_direct_document_publishers_flags_bypass_apis(self) -> None:
        text = "\n".join(
            [
                "public static func install(epubURL source: Foundation.URL) throws -> String { fatalError() }",
                "internal func insert(_ graph: BibleCore.MyDocument) -> Bool { true }",
                "public static func installAndroidModuleBackup(_ source: URL) throws -> String { fatalError() }",
            ]
        )
        self.assertEqual(find_unsafe_direct_document_publishers(text), [1, 2, 3])

    def test_find_unsafe_direct_document_publishers_flags_fail_open_dependencies(self) -> None:
        text = "\n".join(
            [
                "public func save() {}",
                "isDocumentInitialsUnavailable: @escaping (String) throws -> Bool = { _ in false },",
                "epubCandidateAdmission: EpubCandidateAdmission? = nil,",
            ]
        )
        self.assertEqual(
            find_unsafe_direct_document_publishers(
                text,
                "Sources/BibleCore/Sources/BibleCore/Database/MyDocumentStore.swift",
            ),
            [1, 2, 3],
        )

    def test_find_unsafe_direct_document_publishers_flags_optional_library_admission(self) -> None:
        text = "\n".join(
            [
                "public func save(",
                "  _ session: inout Session,",
                "  isInitialsUnavailable: ((String) -> Bool)? = nil",
                ") throws {}",
            ]
        )
        self.assertEqual(
            find_unsafe_direct_document_publishers(
                text,
                "Sources/BibleCore/Sources/BibleCore/Database/MyDocumentLibraryStore.swift",
            ),
            [1],
        )

    def test_find_unsafe_direct_document_publishers_enforces_audited_call_sites(self) -> None:
        unsafe_text = "\n".join(
            [
                "_ = try EpubReader.installAndroidModuleBackup(epubDirectoryURL: source, libraryRootURL: root)",
                "_ = try EpubReader.install(epubURL: source, moduleStoreRootURL: root, admittingCandidateWith: check)",
                "let document = MyDocument(name: name, initials: initials)",
            ]
        )
        self.assertEqual(
            find_unsafe_direct_document_publishers(unsafe_text, "Sources/Unsafe.swift"),
            [1, 2, 3],
        )
        audited_text = "\n".join(
            [
                "func validatePublishedState() throws {",
                "  _ = try EpubReader.installAndroidModuleBackup(",
                "    epubDirectoryURL: source, libraryRootURL: root",
                "  )",
                "}",
            ]
        )
        self.assertEqual(
            find_unsafe_direct_document_publishers(
                audited_text,
                "Sources/BibleCore/Sources/BibleCore/Services/AndroidModuleBackupRestoreAvailability.swift",
            ),
            [],
        )

    def test_find_unsafe_direct_document_publishers_rejects_aliases_defaults_and_factories(self) -> None:
        text = "\n".join(
            [
                "typealias Reader = EpubReader",
                "_ = try Reader.install(epubURL: source, moduleStoreRootURL: root, admittingCandidateWith: check)",
                "func install(epubURL: URL, libraryRootURL: URL = defaultRoot) throws {}",
                "func publish(_ graph: MyDocument) { modelContext.insert(graph) }",
                "let document: MyDocument = .init(name: name, initials: initials)",
            ]
        )
        self.assertEqual(
            find_unsafe_direct_document_publishers(text, "AndBible/UnsafePublisher.swift"),
            [1, 3, 4, 5],
        )

    def test_find_unsafe_direct_document_publishers_rejects_extra_call_in_audited_file(self) -> None:
        text = "\n".join(
            [
                "func initForTests() throws {",
                "  _ = try EpubReader.install(",
                "    epubURL: source, moduleStoreRootURL: root, admittingCandidateWith: check",
                "  )",
                "}",
            ]
        )
        self.assertEqual(
            find_unsafe_direct_document_publishers(
                text,
                "Sources/BibleUI/Sources/BibleUI/Shared/ExternalDocumentImportService.swift",
            ),
            [2],
        )

    def test_validate_source_guards_scans_app_host_publishers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app_root = root / "AndBible"
            app_root.mkdir(parents=True)
            (app_root / "ContentView.swift").write_text(
                "struct ContentView {}\n",
                encoding="utf-8",
            )
            (app_root / "UnsafePublisher.swift").write_text(
                "typealias Reader = EpubReader\n",
                encoding="utf-8",
            )

            issues = validate_source_guards(root)

        self.assertEqual(
            [(issue.path, issue.line) for issue in issues],
            [("AndBible/UnsafePublisher.swift", 1)],
        )

    def test_find_unsafe_direct_document_publishers_allows_strict_and_test_calls(self) -> None:
        text = "\n".join(
            [
                "public static func install(",
                "    epubURL: URL,",
                "    moduleStoreRootURL: URL,",
                "    admittingCandidateWith admission: InstallAdmission",
                ") throws -> String { fatalError() }",
                "modelContext.insert(document)",
                "// public static func install(epubURL: URL) throws -> String",
                "let example = \"func insert(_ document: MyDocument)\"",
            ]
        )
        self.assertEqual(find_unsafe_direct_document_publishers(text), [])

    def test_find_unsafe_direct_document_publishers_requires_public_epub_admission(self) -> None:
        text = "public static func install(epubURL: URL, libraryRootURL: URL) throws -> String { fatalError() }"
        self.assertEqual(
            find_unsafe_direct_document_publishers(
                text,
                "Sources/BibleCore/Sources/BibleCore/Formats/EpubReaderLibrary.swift",
            ),
            [1],
        )

    def test_find_unsafe_direct_document_publishers_requires_strict_admission_type(self) -> None:
        text = "\n".join(
            [
                "public static func install(epubURL: URL, moduleStoreRootURL: URL, admittingCandidateWith: Bool) throws {}",
                "public static func install(epubURL: URL, moduleStoreRootURL: URL, admittingCandidateWith: InstallAdmission?) throws {}",
                "public static func install(epubURL: URL, moduleStoreRootURL: URL, admittingCandidateWith: (() -> Void)?) throws {}",
                "public static func install(epubURL: URL, moduleStoreRootURL: URL, admittingCandidateWith: BibleCore.EpubReader.InstallAdmission) throws {}",
            ]
        )
        self.assertEqual(
            find_unsafe_direct_document_publishers(
                text,
                "Sources/BibleCore/Sources/BibleCore/Formats/EpubReader.swift",
            ),
            [1, 2, 3],
        )

    def test_find_unsafe_direct_document_publishers_keeps_backup_root_api_internal(self) -> None:
        text = (
            "public static func installAndroidModuleBackup("
            "epubDirectoryURL: URL, libraryRootURL: URL) throws -> String { fatalError() }"
        )
        self.assertEqual(
            find_unsafe_direct_document_publishers(
                text,
                "Sources/BibleCore/Sources/BibleCore/Formats/EpubAndroidModuleBackup.swift",
            ),
            [1],
        )

    def test_find_unsafe_direct_document_publishers_reads_multiline_public_modifiers(self) -> None:
        epub_text = "\n".join(
            [
                "public",
                "static func install(epubURL: URL, libraryRootURL: URL) throws -> String { fatalError() }",
            ]
        )
        self.assertEqual(
            find_unsafe_direct_document_publishers(
                epub_text,
                "Sources/BibleCore/Sources/BibleCore/Formats/EpubReaderLibrary.swift",
            ),
            [1],
        )
        backup_text = "\n".join(
            [
                "public",
                "static func installAndroidModuleBackup(",
                "  epubDirectoryURL: URL, libraryRootURL: URL",
                ") throws -> String { fatalError() }",
            ]
        )
        self.assertEqual(
            find_unsafe_direct_document_publishers(
                backup_text,
                "Sources/BibleCore/Sources/BibleCore/Formats/EpubAndroidModuleBackup.swift",
            ),
            [1],
        )

    def test_find_unsafe_direct_document_publishers_ignores_unrelated_installers(self) -> None:
        text = "func install(font: Font) throws {}"
        self.assertEqual(find_unsafe_direct_document_publishers(text), [])

    def test_find_unsafe_direct_document_publishers_rejects_qualified_aliases(self) -> None:
        text = "\n".join(
            [
                "typealias Reader = BibleCore.EpubReader",
                "typealias Document = BibleCore.MyDocument",
            ]
        )
        self.assertEqual(find_unsafe_direct_document_publishers(text), [1, 2])

    def test_find_unsafe_direct_document_publishers_rejects_publisher_references(self) -> None:
        text = "\n".join(
            [
                "let publish = EpubReader.install",
                "let makeDocument = MyDocument.init",
            ]
        )
        self.assertEqual(find_unsafe_direct_document_publishers(text), [1, 2])

    def test_find_unsafe_direct_document_publishers_rejects_factory_insertion(self) -> None:
        text = "\n".join(
            [
                "func publish(factory: () -> MyDocument) { modelContext.insert(factory()) }",
                "func publishNamed(factory: (String, String) -> MyDocument) {",
                "  let graph: MyDocument = factory(name, initials)",
                "  modelContext.insert(graph)",
                "}",
                "func publishThrowing(factory: (String, String) throws -> MyDocument) throws {",
                "  modelContext.insert(try factory(name, initials))",
                "}",
            ]
        )
        self.assertEqual(find_unsafe_direct_document_publishers(text), [1, 2, 6])

    def test_find_unsafe_direct_document_publishers_rejects_document_factories(self) -> None:
        text = "\n".join(
            [
                "func makeDocument() -> MyDocument { .init(name: name, initials: initials) }",
                "let make: () -> MyDocument = { .init(name: name, initials: initials) }",
                "let parameterized: (String, String) -> MyDocument = { name, initials in",
                "  .init(name: name, initials: initials)",
                "}",
                "let attributed: @Sendable () -> MyDocument = {",
                "  .init(name: name, initials: initials)",
                "}",
                "extension MyDocument {",
                "  static func make() -> Self { Self(name: name, initials: initials) }",
                "}",
            ]
        )
        self.assertEqual(find_unsafe_direct_document_publishers(text), [1, 2, 3, 6, 10])

    def test_find_unsafe_direct_document_publishers_rejects_noop_audited_admission(self) -> None:
        text = "\n".join(
            [
                "init(moduleStoreRootURL: URL, admission: InstallAdmission) {",
                "  _ = try EpubReader.install(",
                "    epubURL: url, moduleStoreRootURL: moduleStoreRootURL,",
                "    admittingCandidateWith: { _ in }",
                "  )",
                "}",
            ]
        )
        self.assertEqual(
            find_unsafe_direct_document_publishers(
                text,
                "Sources/BibleUI/Sources/BibleUI/Shared/ExternalDocumentImportService.swift",
            ),
            [2],
        )

    def test_find_unsafe_direct_document_publishers_rejects_import_service_bypass(self) -> None:
        text = "\n".join(
            [
                "ExternalDocumentImportService(epubCandidateAdmission: { _ in })",
                "ExternalDocumentImportService.init(epubCandidateAdmission: { _ in })",
                "let service: ExternalDocumentImportService = .init(epubCandidateAdmission: { _ in })",
            ]
        )
        self.assertEqual(
            find_unsafe_direct_document_publishers(text, "AndBible/UnsafeImport.swift"),
            [1, 2, 3],
        )

    def test_find_unsafe_direct_document_publishers_rejects_import_service_self_factory(self) -> None:
        text = "\n".join(
            [
                "extension ExternalDocumentImportService {",
                "  static func unsafe() -> Self {",
                "    Self(epubCandidateAdmission: { _ in })",
                "  }",
                "}",
            ]
        )
        self.assertEqual(find_unsafe_direct_document_publishers(text), [3])

    def test_find_unsafe_direct_document_publishers_requires_strict_import_factory(self) -> None:
        unsafe_text = "\n".join(
            [
                "func androidRegistryAware() -> ExternalDocumentImportService {",
                "  ExternalDocumentImportService(epubCandidateAdmission: { _ in })",
                "}",
            ]
        )
        path = "Sources/BibleUI/Sources/BibleUI/Shared/ExternalDocumentImportService.swift"
        self.assertEqual(find_unsafe_direct_document_publishers(unsafe_text, path), [2])

        ignored_text = "\n".join(
            [
                "func androidRegistryAware() -> ExternalDocumentImportService {",
                "  ExternalDocumentImportService(epubCandidateAdmission: { candidate in",
                "    let snapshot = try? BibleReaderInstalledDocumentRegistrySnapshot.capture()",
                "    _ = snapshot?.admitsEpub(candidate)",
                "  })",
                "}",
            ]
        )
        self.assertEqual(find_unsafe_direct_document_publishers(ignored_text, path), [2])

        strict_text = "\n".join(
            [
                "func androidRegistryAware() -> ExternalDocumentImportService {",
                "  ExternalDocumentImportService(epubCandidateAdmission: { candidate in",
                "    let snapshot = try BibleReaderInstalledDocumentRegistrySnapshot.capture()",
                "    guard snapshot.admitsEpub(candidate) else { throw AdmissionError() }",
                "  })",
                "}",
            ]
        )
        self.assertEqual(find_unsafe_direct_document_publishers(strict_text, path), [])

    def test_find_unshared_addon_feature_discovery_rejects_prompt_rescans(self) -> None:
        path = "Sources/BibleCore/Sources/BibleCore/AI/PromptRepository.swift"
        unsafe_text = "\n".join(
            [
                "func loadPromptPacks() {",
                "  let admitted = swordManager.admittedAddonModules()",
                "  let manager = swordManager",
                "  let rows = manager.installedModules()",
                "    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }",
                "  let raw = SwordModuleConfig.readAll(modulePath: swordManager.modulePath)",
                "  let module = manager.module(named: name)",
                "  let hidden = rescanInstalledAddons(swordManager)",
                "  let discover = manager.installedModules",
                "  _ = discover()",
                "}",
            ]
        )
        self.assertEqual(
            find_unshared_addon_feature_discovery(unsafe_text, path),
            [4, 5, 6, 7, 8, 9],
        )
        self.assertEqual(
            find_unshared_addon_feature_discovery(
                "func loadPromptPacks() {\n"
                "  let addons = swordManager.admittedAddonModules()\n"
                "}",
                path,
            ),
            [],
        )

    def test_find_unshared_addon_feature_discovery_rejects_picker_raw_addons(self) -> None:
        path = "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        self.assertEqual(
            find_unshared_addon_feature_discovery(
                "func selectableAddonModules() {\n"
                "  let shared = manager.admittedAddonModules()\n"
                "  let addons = manager.installedModules(category: .addon)\n"
                "}",
                path,
            ),
            [3],
        )

    def test_find_unshared_addon_feature_discovery_rejects_external_helpers(self) -> None:
        path = "Sources/BibleCore/Sources/BibleCore/AI/AddonRescan.swift"
        self.assertEqual(
            find_unshared_addon_feature_discovery(
                "func rescan(_ manager: SwordManager) {\n"
                "  _ = SwordModuleConfig.readAll(modulePath: manager.modulePath)\n"
                "  _ = manager.installedModules(category: .addon)\n"
                "}",
                path,
            ),
            [2, 3],
        )
        self.assertEqual(
            find_unshared_addon_feature_discovery(
                "func selectableAddonModules() {\n"
                "  let addons = manager.admittedAddonModules()\n"
                "}",
                path,
            ),
            [],
        )
        self.assertEqual(
            find_unshared_addon_feature_discovery(
                "func selectableAddonModules() {\n"
                "  let shared = manager.admittedAddonModules()\n"
                "  let rows = manager.installedModules().filter { $0.category == .addon }\n"
                "}",
                path,
            ),
            [3],
        )

        indirection_text = "\n".join(
            [
                "typealias Reader = SwordModuleConfig",
                "func raw(_ root: String) { _ = Reader.readAll(modulePath: root) }",
                "func choose(_ manager: SwordManager, _ category: ModuleCategory) {",
                "  _ = manager.installedModules(category: category)",
                "}",
                "func alias(_ manager: SwordManager) {",
                "  let get: () -> [ModuleInfo] = manager.installedModules",
                "  _ = get().filter { $0.category == .addon }",
                "}",
            ]
        )
        self.assertEqual(
            find_unshared_addon_feature_discovery(indirection_text, path),
            [2, 4, 7],
        )

    def test_find_unshared_addon_feature_discovery_scopes_infrastructure_exceptions(self) -> None:
        path = "Sources/SwordKit/Sources/SwordKit/TtfFontRepository.swift"
        text = "\n".join(
            [
                "func configuredFontPackPathKeys() {",
                "  _ = SwordModuleConfig.readAll(modulePath: swordPath)",
                "}",
                "func rescanAddons() {",
                "  _ = SwordModuleConfig.readAll(modulePath: swordPath)",
                "}",
            ]
        )
        self.assertEqual(find_unshared_addon_feature_discovery(text, path), [5])


if __name__ == "__main__":
    unittest.main()
