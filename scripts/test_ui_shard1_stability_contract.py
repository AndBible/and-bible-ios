"""Shard-one UI-test stability guardrails.

These checks keep route smoke tests focused on the user contract they own and
keep host-process descriptor fixtures independent of hosted-runner Python
startup behavior.
"""

from __future__ import annotations

from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


def swift_function_body(source: str, name: str) -> str:
    """Return the Swift function body for focused source-contract checks."""
    match = re.search(rf"\bfunc\s+{re.escape(name)}\b", source)
    if match is None:
        raise AssertionError(f"Expected Swift function {name} to exist.")

    brace_index = source.find("{", match.end())
    if brace_index == -1:
        raise AssertionError(f"Expected Swift function {name} to have a body.")

    depth = 0
    for index in range(brace_index, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace_index + 1 : index]

    raise AssertionError(f"Expected Swift function {name} body to close.")


class UIShardOneStabilityContractTests(unittest.TestCase):
    """Protects the CI shard-one UI smoke tests from unrelated fixture stalls."""

    def test_downloads_repository_smoke_does_not_create_workspace_prompt(self) -> None:
        """Keep the Downloads route smoke scoped to Downloads and repository management.

        Workspace prompt creation is covered by prompt-specific contract tests and package-level
        workspace persistence tests. Coupling that prompt to the Downloads route smoke means a
        hosted XCTest prompt snapshot stall can fail the repository manager route before the route
        under test is opened.
        """
        source = (
            REPO_ROOT
            / "Tests/UI/AndBibleUITests/AndBibleUITests+PlansDownloadsWorkspace.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(source, "testDownloadsRepositoryManagerOpensFromOverflow")

        self.assertNotIn("openWorkspaceCreatePrompt", body)
        self.assertNotIn("typeWorkspaceNamePromptText", body)
        self.assertNotIn("workspaceNamePromptConfirmButton", body)
        self.assertNotIn("openWorkspaceSelector", body)
        self.assertIn("openDownloads(in: app)", body)
        self.assertIn('"moduleBrowserRepositoriesButton"', body)
        self.assertIn('"repositoryManagerScreen"', body)
        self.assertIn('"repositoryManagerAddButton"', body)

    def test_host_process_descriptor_fixture_uses_shell_not_python_fork(self) -> None:
        """Keep the descriptor-inheritance fixture out of hosted-runner Python startup paths.

        The contract under test is `runHostProcess` returning when the direct child exits while a
        descendant still holds stdout open. A shell background `sleep` proves that descriptor
        behavior without depending on Python import, fork, and sleep scheduling under CI load.
        """
        source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITests.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(
            source,
            "testHostProcessCaptureReturnsAfterChildExitWhenDescendantKeepsPipeOpen",
        )

        self.assertNotIn('executablePath: "/usr/bin/python3"', body)
        self.assertNotIn("os.fork", body)
        self.assertNotIn("time.sleep", body)
        self.assertIn('executablePath: "/bin/sh"', body)
        self.assertIn("FileManager.default.temporaryDirectory", body)
        self.assertIn("nohup /bin/sh -c", body)
        self.assertIn("sleep 2; printf alive", body)
        self.assertIn("sleep 30", body)
        self.assertIn('"fixture-ready:%s"', body)
        self.assertIn("fileExists(atPath: markerURL.path)", body)
