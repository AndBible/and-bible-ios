"""Tests for run_xcodebuild_with_test_selection."""

from __future__ import annotations

import pathlib
import os
import sys
import subprocess
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from run_xcodebuild_with_test_selection import (
    build_xcodebuild_command,
    main,
    parse_test_selection_args,
    run_xcodebuild_command,
)


class ParseTestSelectionArgsTests(unittest.TestCase):
    def test_parse_test_selection_args_filters_blank_lines(self) -> None:
        selection = """
        -only-testing:AndBibleUITests/AndBibleUITests/testOne

          -only-testing:AndBibleUITests/AndBibleUITests/testTwo
        """
        self.assertEqual(
            parse_test_selection_args(selection),
            [
                "-only-testing:AndBibleUITests/AndBibleUITests/testOne",
                "-only-testing:AndBibleUITests/AndBibleUITests/testTwo",
            ],
        )


class BuildXcodebuildCommandTests(unittest.TestCase):
    def test_build_xcodebuild_command_appends_selection_args_before_action(self) -> None:
        command = build_xcodebuild_command(
            project="AndBible.xcodeproj",
            scheme="AndBible",
            configuration="Debug",
            destination="id=DEVICE",
            derived_data_path=".derivedData",
            result_bundle_path=".artifacts/AndBibleTests-ui.xcresult",
            code_signing_allowed="NO",
            selection_args_text=(
                "-only-testing:AndBibleUITests/AndBibleUITests/testOne\n"
                "-only-testing:AndBibleUITests/AndBibleUITests/testTwo\n"
            ),
            action="test-without-building",
        )
        self.assertEqual(
            command,
            [
                "xcodebuild",
                "-project",
                "AndBible.xcodeproj",
                "-scheme",
                "AndBible",
                "-configuration",
                "Debug",
                "-destination",
                "id=DEVICE",
                "-derivedDataPath",
                ".derivedData",
                "-resultBundlePath",
                ".artifacts/AndBibleTests-ui.xcresult",
                "CODE_SIGNING_ALLOWED=NO",
                "-only-testing:AndBibleUITests/AndBibleUITests/testOne",
                "-only-testing:AndBibleUITests/AndBibleUITests/testTwo",
                "test-without-building",
            ],
        )

    def test_build_xcodebuild_command_handles_empty_selection_args(self) -> None:
        command = build_xcodebuild_command(
            project="AndBible.xcodeproj",
            scheme="AndBible",
            configuration="Debug",
            destination="id=DEVICE",
            derived_data_path=".derivedData",
            result_bundle_path=".artifacts/AndBibleBuild-unit.xcresult",
            code_signing_allowed="NO",
            selection_args_text="",
            action="build-for-testing",
        )
        self.assertEqual(command[-1], "build-for-testing")
        self.assertNotIn("", command)


class MainTests(unittest.TestCase):
    @mock.patch("run_xcodebuild_with_test_selection.run_xcodebuild_command", return_value=0)
    def test_main_reads_selection_args_from_environment_when_option_is_omitted(
        self,
        runner_mock: mock.Mock,
    ) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "TEST_SELECTION_ARGS": (
                    "-only-testing:AndBibleUITests/AndBibleUITests/testOne\n"
                    "-only-testing:AndBibleUITests/AndBibleUITests/testTwo\n"
                )
            },
            clear=False,
        ):
            exit_code = main(
                [
                    "--project",
                    "AndBible.xcodeproj",
                    "--scheme",
                    "AndBible",
                    "--configuration",
                    "Debug",
                    "--destination",
                    "id=DEVICE",
                    "--derived-data-path",
                    ".derivedData",
                    "--result-bundle-path",
                    ".artifacts/AndBibleTests-ui.xcresult",
                    "--action",
                    "test-without-building",
                ]
            )
        self.assertEqual(exit_code, 0)
        runner_mock.assert_called_once_with(
            [
                "xcodebuild",
                "-project",
                "AndBible.xcodeproj",
                "-scheme",
                "AndBible",
                "-configuration",
                "Debug",
                "-destination",
                "id=DEVICE",
                "-derivedDataPath",
                ".derivedData",
                "-resultBundlePath",
                ".artifacts/AndBibleTests-ui.xcresult",
                "CODE_SIGNING_ALLOWED=NO",
                "-only-testing:AndBibleUITests/AndBibleUITests/testOne",
                "-only-testing:AndBibleUITests/AndBibleUITests/testTwo",
                "test-without-building",
            ],
            timeout_seconds=None,
        )

    @mock.patch("run_xcodebuild_with_test_selection.os.killpg")
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.Popen")
    def test_run_xcodebuild_command_terminates_process_group_after_timeout(
        self,
        popen_mock: mock.Mock,
        killpg_mock: mock.Mock,
    ) -> None:
        process = mock.Mock()
        process.pid = 12345
        process.wait.side_effect = [
            subprocess.TimeoutExpired(cmd=["xcodebuild"], timeout=30),
            0,
        ]
        popen_mock.return_value = process

        exit_code = run_xcodebuild_command(["xcodebuild", "test"], timeout_seconds=30)

        self.assertEqual(exit_code, 124)
        popen_mock.assert_called_once_with(["xcodebuild", "test"], start_new_session=True)
        killpg_mock.assert_called_once()
        self.assertEqual(killpg_mock.call_args.args[0], 12345)


if __name__ == "__main__":
    unittest.main()
