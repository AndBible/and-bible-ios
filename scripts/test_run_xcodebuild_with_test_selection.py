"""Tests for run_xcodebuild_with_test_selection."""

from __future__ import annotations

import io
import json
import os
import pathlib
import plistlib
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from run_xcodebuild_with_test_selection import (
    build_xcodebuild_command,
    discover_single_xctestrun_path,
    main,
    parse_test_selection_args,
    patch_xctestrun_ui_test_developer_dir,
    result_bundle_reports_passing_tests,
    selected_xcode_developer_dir_from_link,
    selected_ui_test_developer_dir,
    selection_requests_ui_tests,
    ui_test_host_environment_variables,
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


class SelectedUITestDeveloperDirTests(unittest.TestCase):
    @mock.patch("run_xcodebuild_with_test_selection.os.readlink")
    def test_selected_xcode_developer_dir_from_link_normalizes_xcode_app_root(
        self,
        readlink_mock: mock.Mock,
    ) -> None:
        readlink_mock.return_value = "/Applications/Xcode_26.3.app"

        self.assertEqual(
            selected_xcode_developer_dir_from_link(),
            "/Applications/Xcode_26.3.app/Contents/Developer",
        )

    @mock.patch("run_xcodebuild_with_test_selection.os.readlink")
    def test_selected_xcode_developer_dir_from_link_uses_developer_dir_link(
        self,
        readlink_mock: mock.Mock,
    ) -> None:
        readlink_mock.return_value = "/Applications/Xcode_26.3.app/Contents/Developer"

        self.assertEqual(
            selected_xcode_developer_dir_from_link(),
            "/Applications/Xcode_26.3.app/Contents/Developer",
        )

    def test_selected_ui_test_developer_dir_prefers_existing_ui_test_override(self) -> None:
        environment = {
            "UITEST_DEVELOPER_DIR": "/Applications/Custom.app/Contents/Developer",
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
            "MD_APPLE_SDK_ROOT": "/Applications/Xcode_26.3.app",
        }

        self.assertEqual(
            selected_ui_test_developer_dir(environment),
            "/Applications/Custom.app/Contents/Developer",
        )

    def test_selected_ui_test_developer_dir_uses_developer_dir(self) -> None:
        environment = {"DEVELOPER_DIR": "/Applications/Xcode_26.3.app/Contents/Developer"}

        self.assertEqual(
            selected_ui_test_developer_dir(
                environment,
                selected_xcode_developer_dir=lambda: None,
            ),
            "/Applications/Xcode_26.3.app/Contents/Developer",
        )

    def test_selected_ui_test_developer_dir_derives_from_md_apple_sdk_root(self) -> None:
        environment = {"MD_APPLE_SDK_ROOT": "/Applications/Xcode_26.3.app"}

        self.assertEqual(
            selected_ui_test_developer_dir(environment),
            "/Applications/Xcode_26.3.app/Contents/Developer",
        )

    def test_selected_ui_test_developer_dir_prefers_xcode_select_link_over_stale_developer_dir(
        self,
    ) -> None:
        environment = {"DEVELOPER_DIR": "/Applications/Xcode_16.4.app/Contents/Developer"}

        self.assertEqual(
            selected_ui_test_developer_dir(
                environment,
                selected_xcode_developer_dir=(
                    lambda: "/Applications/Xcode_26.3.app/Contents/Developer"
                ),
            ),
            "/Applications/Xcode_26.3.app/Contents/Developer",
        )

    def test_selected_ui_test_developer_dir_prefers_sdk_root_over_stale_developer_dir(self) -> None:
        """Keep CI host tools on the selected Xcode when runners inherit an old DEVELOPER_DIR."""
        environment = {
            "DEVELOPER_DIR": "/Applications/Xcode_16.4.app/Contents/Developer",
            "MD_APPLE_SDK_ROOT": "/Applications/Xcode_26.3.app",
        }

        self.assertEqual(
            selected_ui_test_developer_dir(environment),
            "/Applications/Xcode_26.3.app/Contents/Developer",
        )


class XctestrunEnvironmentTests(unittest.TestCase):
    def test_ui_test_host_environment_variables_maps_runner_user_directories(self) -> None:
        self.assertEqual(
            ui_test_host_environment_variables(
                {
                    "HOME": "/Users/runner",
                    "TMPDIR": "/var/folders/ci/T/",
                    "USER": "runner",
                    "LOGNAME": "runner",
                    "__CF_USER_TEXT_ENCODING": "501:0:0",
                    "EMPTY": "",
                }
            ),
            {
                "UITEST_HOST_HOME": "/Users/runner",
                "UITEST_HOST_TMPDIR": "/var/folders/ci/T/",
                "UITEST_HOST_USER": "runner",
                "UITEST_HOST_LOGNAME": "runner",
                "UITEST_HOST_CF_USER_TEXT_ENCODING": "501:0:0",
            },
        )

    def test_selection_requests_ui_tests_for_only_testing_ui_target(self) -> None:
        selection = """
        -only-testing:AndBibleUITests/AndBibleUITests/testAboutScreenOpensFromReaderMenu
        -skip-testing:AndBibleTests/AndBibleTests/testSlowUnit
        """

        self.assertTrue(selection_requests_ui_tests(selection))

    def test_selection_requests_ui_tests_ignores_unit_only_selection(self) -> None:
        selection = """
        -skip-testing:AndBibleUITests
        -only-testing:AndBibleTests/AndBibleTests/testSettings
        """

        self.assertFalse(selection_requests_ui_tests(selection))

    def test_discover_single_xctestrun_path_requires_one_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            products_path = pathlib.Path(temporary_directory) / "Build" / "Products"
            products_path.mkdir(parents=True)
            xctestrun_path = products_path / "AndBible_iphonesimulator.xctestrun"
            xctestrun_path.write_bytes(b"")

            self.assertEqual(
                discover_single_xctestrun_path(temporary_directory),
                str(xctestrun_path),
            )

            (products_path / "Other_iphonesimulator.xctestrun").write_bytes(b"")
            self.assertIsNone(discover_single_xctestrun_path(temporary_directory))

    def test_patch_xctestrun_ui_test_developer_dir_updates_only_ui_test_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            xctestrun_path = pathlib.Path(temporary_directory) / "AndBible.xctestrun"
            xctestrun = {
                "AndBibleTests": {
                    "EnvironmentVariables": {},
                    "TestingEnvironmentVariables": {},
                },
                "AndBibleUITests": {
                    "IsUITestBundle": True,
                    "EnvironmentVariables": {"EXISTING": "1"},
                    "TestingEnvironmentVariables": {},
                },
            }
            with xctestrun_path.open("wb") as plist_file:
                plistlib.dump(xctestrun, plist_file)

            patched = patch_xctestrun_ui_test_developer_dir(
                str(xctestrun_path),
                "/Applications/Xcode_26.3.app/Contents/Developer",
                host_environment={
                    "HOME": "/Users/runner",
                    "TMPDIR": "/var/folders/ci/T/",
                    "USER": "runner",
                    "LOGNAME": "runner",
                    "__CF_USER_TEXT_ENCODING": "501:0:0",
                },
            )

            self.assertTrue(patched)
            with xctestrun_path.open("rb") as plist_file:
                patched_xctestrun = plistlib.load(plist_file)
            ui_environment = patched_xctestrun["AndBibleUITests"]["EnvironmentVariables"]
            ui_testing_environment = patched_xctestrun["AndBibleUITests"][
                "TestingEnvironmentVariables"
            ]
            self.assertEqual(ui_environment["EXISTING"], "1")
            self.assertEqual(
                ui_environment["DEVELOPER_DIR"],
                "/Applications/Xcode_26.3.app/Contents/Developer",
            )
            self.assertEqual(
                ui_environment["UITEST_DEVELOPER_DIR"],
                "/Applications/Xcode_26.3.app/Contents/Developer",
            )
            self.assertEqual(
                ui_testing_environment["DEVELOPER_DIR"],
                "/Applications/Xcode_26.3.app/Contents/Developer",
            )
            self.assertEqual(ui_environment["UITEST_HOST_HOME"], "/Users/runner")
            self.assertEqual(ui_environment["UITEST_HOST_TMPDIR"], "/var/folders/ci/T/")
            self.assertEqual(ui_environment["UITEST_HOST_USER"], "runner")
            self.assertEqual(ui_environment["UITEST_HOST_LOGNAME"], "runner")
            self.assertEqual(
                ui_environment["UITEST_HOST_CF_USER_TEXT_ENCODING"],
                "501:0:0",
            )
            self.assertEqual(
                ui_testing_environment["UITEST_HOST_HOME"],
                "/Users/runner",
            )
            self.assertNotIn(
                "DEVELOPER_DIR",
                patched_xctestrun["AndBibleTests"]["EnvironmentVariables"],
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
    def test_main_exports_ui_test_developer_dir_from_selected_xcode(
        self,
        run_mock: mock.Mock,
    ) -> None:
        """Pass the selected Xcode into UI tests for host-side xcrun/simctl calls."""
        with mock.patch.dict(
            os.environ,
            {"MD_APPLE_SDK_ROOT": "/Applications/Xcode_26.3.app"},
            clear=True,
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
            self.assertEqual(
                os.environ["UITEST_DEVELOPER_DIR"],
                "/Applications/Xcode_26.3.app/Contents/Developer",
            )
            self.assertEqual(
                os.environ["DEVELOPER_DIR"],
                "/Applications/Xcode_26.3.app/Contents/Developer",
            )

        self.assertEqual(exit_code, 0)
        run_mock.assert_called_once()

    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_overwrites_stale_developer_dir_with_selected_xcode(
        self,
        run_mock: mock.Mock,
    ) -> None:
        """Prevent shard host tools from falling back to a stale inherited Xcode path."""
        with mock.patch.dict(
            os.environ,
            {
                "DEVELOPER_DIR": "/Applications/Xcode_16.4.app/Contents/Developer",
                "MD_APPLE_SDK_ROOT": "/Applications/Xcode_26.3.app",
            },
            clear=True,
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
            self.assertEqual(
                os.environ["UITEST_DEVELOPER_DIR"],
                "/Applications/Xcode_26.3.app/Contents/Developer",
            )
            self.assertEqual(
                os.environ["DEVELOPER_DIR"],
                "/Applications/Xcode_26.3.app/Contents/Developer",
            )

        self.assertEqual(exit_code, 0)
        run_mock.assert_called_once()

    @mock.patch("run_xcodebuild_with_test_selection.os.readlink")
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_overwrites_stale_developer_dir_from_xcode_select_link(
        self,
        run_mock: mock.Mock,
        readlink_mock: mock.Mock,
    ) -> None:
        """Keep UI-test host tools on selected Xcode when SDK env is not exported."""
        readlink_mock.return_value = "/Applications/Xcode_26.3.app/Contents/Developer"
        with mock.patch.dict(
            os.environ,
            {"DEVELOPER_DIR": "/Applications/Xcode_16.4.app/Contents/Developer"},
            clear=True,
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
            self.assertEqual(
                os.environ["UITEST_DEVELOPER_DIR"],
                "/Applications/Xcode_26.3.app/Contents/Developer",
            )
            self.assertEqual(
                os.environ["DEVELOPER_DIR"],
                "/Applications/Xcode_26.3.app/Contents/Developer",
            )

        self.assertEqual(exit_code, 0)
        run_mock.assert_called_once()

    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_patches_discovered_xctestrun_for_project_mode_ui_tests(
        self,
        run_mock: mock.Mock,
    ) -> None:
        """Pass selected Xcode into the XCTest runner, not only the xcodebuild wrapper."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            products_path = pathlib.Path(temporary_directory) / "Build" / "Products"
            products_path.mkdir(parents=True)
            xctestrun_path = products_path / "AndBible_iphonesimulator.xctestrun"
            with xctestrun_path.open("wb") as plist_file:
                plistlib.dump(
                    {
                        "AndBibleUITests": {
                            "IsUITestBundle": True,
                            "EnvironmentVariables": {},
                            "TestingEnvironmentVariables": {},
                        }
                    },
                    plist_file,
                )

            with mock.patch.dict(
                os.environ,
                {"MD_APPLE_SDK_ROOT": "/Applications/Xcode_26.3.app"},
                clear=True,
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
                        temporary_directory,
                        "--result-bundle-path",
                        ".artifacts/AndBibleTests-ui.xcresult",
                        "--test-selection-args=-only-testing:AndBibleUITests/AndBibleUITests/testOne",
                        "--action",
                        "test-without-building",
                    ]
                )

            self.assertEqual(exit_code, 0)
            run_mock.assert_called_once_with(
                [
                    "xcodebuild",
                    "-xctestrun",
                    str(xctestrun_path),
                    "-destination",
                    "id=DEVICE",
                    "-resultBundlePath",
                    ".artifacts/AndBibleTests-ui.xcresult",
                    "CODE_SIGNING_ALLOWED=NO",
                    "-only-testing:AndBibleUITests/AndBibleUITests/testOne",
                    "test-without-building",
                ],
                check=True,
            )
            with xctestrun_path.open("rb") as plist_file:
                xctestrun = plistlib.load(plist_file)
            self.assertEqual(
                xctestrun["AndBibleUITests"]["EnvironmentVariables"]["UITEST_DEVELOPER_DIR"],
                "/Applications/Xcode_26.3.app/Contents/Developer",
            )
            self.assertEqual(
                xctestrun["AndBibleUITests"]["TestingEnvironmentVariables"]["DEVELOPER_DIR"],
                "/Applications/Xcode_26.3.app/Contents/Developer",
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
    def test_main_rejects_xctestrun_path_for_build_for_testing_before_running_xcodebuild(
        self,
        run_mock: mock.Mock,
    ) -> None:
        """Protect .xctestrun mode from silently falling back to project-mode builds."""
        with mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            with self.assertRaises(SystemExit) as raised:
                main(
                    [
                        "--xctestrun-path",
                        ".derivedData/Build/Products/AndBible_iphonesimulator.xctestrun",
                        "--destination",
                        "id=DEVICE",
                        "--result-bundle-path",
                        ".artifacts/AndBibleTests-ui-reuse.xcresult",
                        "--action",
                        "build-for-testing",
                    ]
                )

        self.assertEqual(raised.exception.code, 2)
        self.assertIn(
            "--xctestrun-path can only be used with --action test-without-building",
            stderr.getvalue(),
        )
        run_mock.assert_not_called()

    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_rejects_project_mode_inputs_with_xctestrun_path_before_running_xcodebuild(
        self,
        run_mock: mock.Mock,
    ) -> None:
        """Keep .xctestrun mode command shape unambiguous for CI reuse jobs."""
        with mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            with self.assertRaises(SystemExit) as raised:
                main(
                    [
                        "--xctestrun-path",
                        ".derivedData/Build/Products/AndBible_iphonesimulator.xctestrun",
                        "--project",
                        "AndBible.xcodeproj",
                        "--scheme",
                        "AndBible",
                        "--destination",
                        "id=DEVICE",
                        "--result-bundle-path",
                        ".artifacts/AndBibleTests-ui-reuse.xcresult",
                        "--action",
                        "test-without-building",
                    ]
                )

        self.assertEqual(raised.exception.code, 2)
        self.assertIn(
            "the following arguments cannot be used with --xctestrun-path: --project, --scheme",
            stderr.getvalue(),
        )
        run_mock.assert_not_called()

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
