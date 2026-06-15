"""Tests for run_xcodebuild_with_test_selection."""

from __future__ import annotations

import pathlib
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from run_xcodebuild_with_test_selection import (
    build_xcodebuild_command,
    main,
    parse_test_selection_args,
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
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_reads_selection_args_from_environment_when_option_is_omitted(
        self,
        run_mock: mock.Mock,
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
        run_mock.assert_called_once_with(
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
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
