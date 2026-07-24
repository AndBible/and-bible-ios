#!/usr/bin/env python3
"""Android full-help and compact feature-help source-contract tests."""

from __future__ import annotations

from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
BIBLE_UI = REPO_ROOT / "Sources" / "BibleUI" / "Sources" / "BibleUI"


def source(relative_path: str) -> str:
    """Return one BibleUI production source file without mutating the checkout."""
    return (BIBLE_UI / relative_path).read_text(encoding="utf-8")


class AndroidHelpDialogContractTests(unittest.TestCase):
    """Prevents Android Help behavior from diverging into iOS-only presentations."""

    def test_adaptive_body_measures_intrinsically_before_enabling_scroll(self) -> None:
        """Short help must fit naturally while overflow retains a scroll path."""
        adaptive_source = source("Shared/AndroidAdaptiveDialogScrollView.swift")

        self.assertIn("ViewThatFits(in: .vertical)", adaptive_source)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", adaptive_source)
        self.assertIn("ScrollView {", adaptive_source)

    def test_every_app_owned_help_body_uses_shared_adaptive_measurement(self) -> None:
        """Feature help surfaces must not restore greedy, screen-height ScrollViews."""
        help_sources = (
            "AI/AIReaderHelpPresentation.swift",
            "Bookmarks/AndroidManageLabelsComponents.swift",
            "Search/AndroidSearchHelpDialog.swift",
            "Settings/AndroidTextDisplayHelpDialog.swift",
            "Settings/HelpView.swift",
            "Shared/AndroidDecisionDialog.swift",
            "Shared/AndroidFeatureHelpDialog.swift",
            "Speak/AndroidSpeakHelpDialog.swift",
        )

        for relative_path in help_sources:
            help_source = source(relative_path)
            self.assertIn(
                "AndroidAdaptiveDialogScrollView",
                help_source,
                relative_path,
            )

    def test_ai_help_entry_points_use_typed_android_topics(self) -> None:
        """AI screens must not invent local titles, messages, or documentation URLs."""
        expected_topics_by_file = {
            "AI/AISettingsView.swift": (".help(.aiSettings)",),
            "AI/AIConnectionSettingsView.swift": (
                ".help(.aiConnection)",
                ".help(.aiProviders)",
            ),
            "AI/AIModelsView.swift": (".help(.aiModels)",),
            "AI/AIPromptManagementView.swift": (
                ".help(.aiSettings)",
                ".help(.promptEditor)",
            ),
            "AI/AIPromptToolInfoView.swift": (".help(.toolInfo)",),
            "AI/AIToolAndDocumentSettingsViews.swift": (
                ".help(.globalToolPermissions)",
                ".help(.aiDocumentFilter)",
            ),
        }

        for relative_path, expected_topics in expected_topics_by_file.items():
            help_source = source(relative_path)
            for expected_topic in expected_topics:
                self.assertIn(expected_topic, help_source, relative_path)

    def test_full_and_compact_help_keep_distinct_android_content_contracts(self) -> None:
        """Study Pads keeps logo/support content while compact AI Help keeps one manual link."""
        full_help = source("Shared/AndroidHelpDialog.swift")
        compact_help = source("Shared/AndroidFeatureHelpDialog.swift")

        self.assertIn('Image("DrawerLogo", bundle: .module)', full_help)
        self.assertIn("HelpView(topics: topics, showsVersion: showsVersion)", full_help)
        self.assertIn('"help_read_more_link"', compact_help)
        self.assertNotIn('"DrawerLogo"', compact_help)
        self.assertNotIn('"buy_development"', compact_help)

    def test_reader_feature_help_reuses_the_shared_compact_renderer(self) -> None:
        """Memorize help must not reconstruct Android's compact-help UI or resources."""
        reader_help = source("AI/AIReaderHelpPresentation.swift")

        self.assertIn(".androidFeature(.memorize)", reader_help)
        self.assertIn(
            "AndroidFeatureHelpDialog(topic: featureTopic, onDismiss: onDismiss)",
            reader_help,
        )
        self.assertNotIn("memorizeDocumentationURL", reader_help)

    def test_modal_hyperlinks_reuse_android_url_span_visuals(self) -> None:
        """Dialog links must be underlined and share the positive-action accent."""
        link_source = source("Shared/AndroidDialogLink.swift")
        action_source = source("Shared/AndroidDialogScaffold.swift")
        linked_dialog_sources = (
            "AI/AIProviderDialogs.swift",
            "AI/AIQuickSetupDialogs.swift",
            "AI/AIReaderHelpPresentation.swift",
            "Bookmarks/AndroidManageLabelsComponents.swift",
            "Settings/AndroidTextDisplayHelpDialog.swift",
            "Settings/HelpView.swift",
            "Shared/AndroidFeatureHelpDialog.swift",
            "Speak/AndroidSpeakHelpDialog.swift",
        )

        self.assertIn("Text(title).underline()", link_source)
        self.assertIn("AndroidDialogSurfacePalette.accent(for: colorScheme)", link_source)
        self.assertIn("AndroidDialogSurfacePalette.accent(for: colorScheme)", action_source)

        for relative_path in linked_dialog_sources:
            dialog_source = source(relative_path)
            self.assertIn("AndroidDialogLink(", dialog_source, relative_path)
            self.assertIsNone(
                re.search(r"(?<!AndroidDialog)\bLink\(", dialog_source),
                relative_path,
            )


if __name__ == "__main__":
    unittest.main()
