"""Tests for run_xcodebuild_with_test_selection."""

from __future__ import annotations

import pathlib
import json
import os
import signal
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from run_xcodebuild_with_test_selection import (
    build_xcodebuild_command,
    main,
    parse_test_selection_args,
    result_bundle_reports_passing_tests,
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

    def test_build_xcodebuild_command_reports_missing_project_mode_inputs(self) -> None:
        """Keep CI wrapper failures actionable when project-mode arguments are omitted."""
        with self.assertRaisesRegex(
            ValueError,
            "Missing: scheme, derived_data_path",
        ):
            build_xcodebuild_command(
                project="AndBible.xcodeproj",
                scheme=None,
                configuration="Debug",
                destination="id=DEVICE",
                derived_data_path=None,
                result_bundle_path=".artifacts/AndBibleBuild-unit.xcresult",
                code_signing_allowed="NO",
                selection_args_text="",
                action="build-for-testing",
            )

    def test_build_xcodebuild_command_uses_xctestrun_without_project_build_inputs(self) -> None:
        """Protect the reusable-build mode from accidentally invoking a project build."""
        command = build_xcodebuild_command(
            project=None,
            scheme=None,
            configuration=None,
            destination="id=DEVICE",
            derived_data_path=None,
            result_bundle_path=".artifacts/AndBibleTests-ui-reuse.xcresult",
            code_signing_allowed="NO",
            selection_args_text="-only-testing:AndBibleUITests/AndBibleUITests/testAboutScreenOpensFromReaderMenu",
            action="test-without-building",
            xctestrun_path=".derivedData/Build/Products/AndBible_iphonesimulator.xctestrun",
        )

        self.assertEqual(
            command,
            [
                "xcodebuild",
                "-xctestrun",
                ".derivedData/Build/Products/AndBible_iphonesimulator.xctestrun",
                "-destination",
                "id=DEVICE",
                "-resultBundlePath",
                ".artifacts/AndBibleTests-ui-reuse.xcresult",
                "CODE_SIGNING_ALLOWED=NO",
                "-only-testing:AndBibleUITests/AndBibleUITests/testAboutScreenOpensFromReaderMenu",
                "test-without-building",
            ],
        )


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

    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_accepts_xctestrun_path_for_test_without_building(
        self,
        run_mock: mock.Mock,
    ) -> None:
        """Protect CI's restored-product path while preserving selection parsing and SIGSEGV handling."""
        exit_code = main(
            [
                "--xctestrun-path",
                ".derivedData/Build/Products/AndBible_iphonesimulator.xctestrun",
                "--destination",
                "id=DEVICE",
                "--result-bundle-path",
                ".artifacts/AndBibleTests-ui-reuse.xcresult",
                "--test-selection-args=-only-testing:AndBibleUITests/AndBibleUITests/testAboutScreenOpensFromReaderMenu",
                "--action",
                "test-without-building",
            ]
        )

        self.assertEqual(exit_code, 0)
        run_mock.assert_called_once_with(
            [
                "xcodebuild",
                "-xctestrun",
                ".derivedData/Build/Products/AndBible_iphonesimulator.xctestrun",
                "-destination",
                "id=DEVICE",
                "-resultBundlePath",
                ".artifacts/AndBibleTests-ui-reuse.xcresult",
                "CODE_SIGNING_ALLOWED=NO",
                "-only-testing:AndBibleUITests/AndBibleUITests/testAboutScreenOpensFromReaderMenu",
                "test-without-building",
            ],
            check=True,
        )

    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_treats_sigsegv_after_passing_result_bundle_as_success(
        self,
        run_mock: mock.Mock,
    ) -> None:
        passing_summary = {
            "result": "Passed",
            "totalTestCount": 4,
            "passedTests": 4,
            "failedTests": 0,
        }
        run_mock.side_effect = [
            subprocess.CalledProcessError(
                returncode=-signal.SIGSEGV,
                cmd=["xcodebuild", "test-without-building"],
            ),
            subprocess.CompletedProcess(
                args=["xcrun", "xcresulttool"],
                returncode=0,
                stdout=json.dumps(passing_summary),
                stderr="",
            ),
        ]

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
        self.assertEqual(run_mock.call_count, 2)
        self.assertEqual(
            run_mock.call_args_list[1].args[0],
            [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "summary",
                "--path",
                ".artifacts/AndBibleTests-ui.xcresult",
                "--compact",
            ],
        )
        self.assertEqual(
            run_mock.call_args_list[1].kwargs,
            {"check": True, "capture_output": True, "text": True},
        )

    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_reraises_sigsegv_when_result_bundle_reports_failures(
        self,
        run_mock: mock.Mock,
    ) -> None:
        failing_summary = {
            "result": "Failed",
            "totalTestCount": 4,
            "passedTests": 3,
            "failedTests": 1,
        }
        run_mock.side_effect = [
            subprocess.CalledProcessError(
                returncode=-signal.SIGSEGV,
                cmd=["xcodebuild", "test-without-building"],
            ),
            subprocess.CompletedProcess(
                args=["xcrun", "xcresulttool"],
                returncode=0,
                stdout=json.dumps(failing_summary),
                stderr="",
            ),
        ]

        with self.assertRaises(subprocess.CalledProcessError):
            main(
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

    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_reraises_original_sigsegv_when_result_bundle_is_unreadable(
        self,
        run_mock: mock.Mock,
    ) -> None:
        xcodebuild_error = subprocess.CalledProcessError(
            returncode=-signal.SIGSEGV,
            cmd=["xcodebuild", "test-without-building"],
        )
        run_mock.side_effect = [
            xcodebuild_error,
            subprocess.CalledProcessError(
                returncode=1,
                cmd=["xcrun", "xcresulttool"],
            ),
        ]

        with self.assertRaises(subprocess.CalledProcessError) as raised:
            main(
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

        self.assertIs(raised.exception, xcodebuild_error)


class ResultBundleSummaryTests(unittest.TestCase):
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_result_bundle_reports_passing_tests_requires_passed_nonempty_bundle(
        self,
        run_mock: mock.Mock,
    ) -> None:
        run_mock.return_value = subprocess.CompletedProcess(
            args=["xcrun", "xcresulttool"],
            returncode=0,
            stdout=json.dumps(
                {
                    "result": "Passed",
                    "totalTestCount": 4,
                    "passedTests": 4,
                    "failedTests": 0,
                }
            ),
            stderr="",
        )

        self.assertTrue(result_bundle_reports_passing_tests("result.xcresult"))

    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_result_bundle_reports_passing_tests_rejects_empty_passed_bundle(
        self,
        run_mock: mock.Mock,
    ) -> None:
        run_mock.return_value = subprocess.CompletedProcess(
            args=["xcrun", "xcresulttool"],
            returncode=0,
            stdout=json.dumps(
                {
                    "result": "Passed",
                    "totalTestCount": 0,
                    "passedTests": 0,
                    "failedTests": 0,
                }
            ),
            stderr="",
        )

        self.assertFalse(result_bundle_reports_passing_tests("result.xcresult"))


if __name__ == "__main__":
    unittest.main()
