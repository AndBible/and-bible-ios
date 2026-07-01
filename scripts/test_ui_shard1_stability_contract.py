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

    def test_host_process_descriptor_fixture_stays_runtime_smoke(self) -> None:
        """Keep the descriptor-inheritance runtime test out of lifecycle probing.

        The runtime test should only prove that the UI-test host can launch a direct shell child and
        return quickly while a descendant command was started. The stronger descriptor contract is
        guarded against `runHostProcess` itself below, so this smoke must not depend on Python,
        nohup behavior, host temp paths, marker files, or immediate descendant liveness.
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
        self.assertNotIn("nohup", body)
        self.assertNotIn('"UITEST_HOST_TMPDIR"', body)
        self.assertNotIn("FileManager.default.temporaryDirectory", body)
        self.assertNotIn("fileExists(atPath:", body)
        self.assertNotIn("kill(descendantPID, 0)", body)
        self.assertIn('executablePath: "/bin/sh"', body)
        self.assertIn("let startDate = Date()", body)
        self.assertIn("Date().timeIntervalSince(startDate)", body)
        self.assertIn("XCTAssertLessThan", body)
        self.assertIn("sleep 30 &", body)
        self.assertIn('"fixture-ready:%s"', body)

    def test_run_host_process_returns_on_direct_child_waitpid_not_pipe_eof(self) -> None:
        """Guard the real descriptor contract on the helper implementation.

        `runHostProcess` must treat the direct child's exit as completion and avoid waiting for EOF
        from stdout or stderr pipes that descendants may keep open. A failure here means the helper
        can regress to blocking fixture setup when `simctl launch` leaves descriptors inherited by
        the launched app process.
        """
        source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(source, "runHostProcess")

        waitpid_call = "let waitResult = waitpid(pid, &waitStatus, WNOHANG)"
        direct_child_break = "if waitResult == pid {\n                break\n            }"
        timeout_check = "if Date() >= deadline"

        self.assertIn("makeReadDescriptorNonBlocking(stdoutPipe[0])", body)
        self.assertIn("makeReadDescriptorNonBlocking(stderrPipe[0])", body)
        self.assertIn(waitpid_call, body)
        self.assertIn(direct_child_break, body)
        self.assertIn(timeout_check, body)
        self.assertLess(body.find(waitpid_call), body.find(timeout_check))
        self.assertNotIn("readDataToEndOfFile", body)
        self.assertNotIn("availableData", body)
