"""Tests for run_ui_test_groups."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from run_ui_test_groups import (
    DEFAULT_BUNDLE_IDENTIFIER,
    create_group_simulator,
    create_argument_parser,
    derive_group_result_bundle_path,
    group_selection_args_by_fixture,
    install_app_with_retry,
    infer_app_path,
    load_fixture_manifest,
    main,
    read_simctl_json,
    run_grouped_ui_tests,
    selection_arg_to_identifier,
    terminate_app_if_running,
)


class SelectionArgTests(unittest.TestCase):
    def test_selection_arg_to_identifier_extracts_xctest_identifier(self) -> None:
        self.assertEqual(
            selection_arg_to_identifier(
                "-only-testing:AndBibleUITests/AndBibleUITests/testBookmarkSelectionNavigatesReaderToSeededReference"
            ),
            "AndBibleUITests/AndBibleUITests/testBookmarkSelectionNavigatesReaderToSeededReference",
        )

    def test_selection_arg_to_identifier_rejects_non_only_testing_argument(self) -> None:
        with self.assertRaises(ValueError):
            selection_arg_to_identifier("-skip-testing:AndBibleUITests/AndBibleUITests/testOne")


class FixtureManifestTests(unittest.TestCase):
    def test_load_fixture_manifest_requires_non_empty_string_values(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = pathlib.Path(temp_dir) / "manifest.json"
            manifest_path.write_text(json.dumps({"AndBibleUITests/AndBibleUITests/testOne": ""}))
            with self.assertRaises(ValueError):
                load_fixture_manifest(manifest_path)

    def test_group_selection_args_by_fixture_preserves_selection_order_within_scenarios(self) -> None:
        selection_args = [
            "-only-testing:AndBibleUITests/AndBibleUITests/testBookmarkSelectionNavigatesReaderToSeededReference",
            "-only-testing:AndBibleUITests/AndBibleUITests/testHistorySelectionNavigatesReaderToSeededReference",
            "-only-testing:AndBibleUITests/AndBibleUITests/testBookmarkRowDeletePreservesOtherRowsAcrossReopen",
        ]
        manifest = {
            "AndBibleUITests/AndBibleUITests/testBookmarkSelectionNavigatesReaderToSeededReference": "bookmark-navigation",
            "AndBibleUITests/AndBibleUITests/testHistorySelectionNavigatesReaderToSeededReference": "history-single",
            "AndBibleUITests/AndBibleUITests/testBookmarkRowDeletePreservesOtherRowsAcrossReopen": "bookmark-multirow",
        }
        self.assertEqual(
            group_selection_args_by_fixture(selection_args, manifest),
            [
                (
                    "bookmark-navigation",
                    [
                        "-only-testing:AndBibleUITests/AndBibleUITests/testBookmarkSelectionNavigatesReaderToSeededReference"
                    ],
                ),
                (
                    "history-single",
                    [
                        "-only-testing:AndBibleUITests/AndBibleUITests/testHistorySelectionNavigatesReaderToSeededReference"
                    ],
                ),
                (
                    "bookmark-multirow",
                    [
                        "-only-testing:AndBibleUITests/AndBibleUITests/testBookmarkRowDeletePreservesOtherRowsAcrossReopen"
                    ],
                ),
            ],
        )

    def test_group_selection_args_by_fixture_requires_manifest_entry_for_every_selected_test(self) -> None:
        with self.assertRaises(ValueError):
            group_selection_args_by_fixture(
                ["-only-testing:AndBibleUITests/AndBibleUITests/testOne"],
                {},
            )


class PathDerivationTests(unittest.TestCase):
    def test_derive_group_result_bundle_path_suffixes_multi_group_paths(self) -> None:
        derived = derive_group_result_bundle_path(
            pathlib.Path(".artifacts/AndBibleTests-ui.xcresult"),
            scenario="bookmark-filter",
            group_index=2,
            total_groups=3,
        )
        self.assertEqual(
            derived,
            pathlib.Path(".artifacts/AndBibleTests-ui-group-02-bookmark-filter.xcresult"),
        )

    def test_infer_app_path_uses_configuration_and_scheme(self) -> None:
        self.assertEqual(
            infer_app_path(
                derived_data_path=pathlib.Path(".derivedData"),
                configuration="Debug",
                scheme="AndBible",
            ),
            pathlib.Path(".derivedData/Build/Products/Debug-iphonesimulator/AndBible.app"),
        )


class SimctlTerminationTests(unittest.TestCase):
    def test_create_group_simulator_uses_device_type_identifier_from_base_simulator(self) -> None:
        with mock.patch(
            "run_ui_test_groups.read_simctl_json",
            return_value={
                "devices": {
                    "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                        {
                            "udid": "BASE",
                            "name": "AndBible CI UI iPhone 17",
                            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                        }
                    ]
                }
            },
        ):
            with mock.patch(
                "run_ui_test_groups.run_command",
                return_value=subprocess.CompletedProcess(
                    args=["xcrun", "simctl", "create"],
                    returncode=0,
                    stdout="SIM-GROUP-1\n",
                    stderr="",
                ),
            ) as run_command_mock:
                simulator_id, destination = create_group_simulator(
                    base_simulator_id="BASE",
                    scenario="baseline",
                    group_index=1,
                )

        self.assertEqual(simulator_id, "SIM-GROUP-1")
        self.assertEqual(destination, "id=SIM-GROUP-1")
        run_command_mock.assert_called_once_with(
            [
                "xcrun",
                "simctl",
                "create",
                "AndBible Group 1 baseline iPhone 17",
                "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
            ],
            capture_output=True,
            timeout_seconds=30,
        )

    def test_read_simctl_json_retries_after_transient_failure(self) -> None:
        success = subprocess.CompletedProcess(
            args=["xcrun", "simctl", "list", "devices", "available", "-j"],
            returncode=0,
            stdout='{"devices": {}}',
            stderr="",
        )
        failure = subprocess.CompletedProcess(
            args=["xcrun", "simctl", "list", "devices", "available", "-j"],
            returncode=1,
            stdout="",
            stderr="Connection invalid",
        )
        with mock.patch("run_ui_test_groups.subprocess.run", side_effect=[failure, success]) as run_mock:
            with mock.patch("run_ui_test_groups.time.sleep") as sleep_mock:
                payload = read_simctl_json("devices", "available")

        self.assertEqual(payload, {"devices": {}})
        self.assertEqual(run_mock.call_count, 2)
        sleep_mock.assert_called_once()

    def test_terminate_app_if_running_continues_after_timeout(self) -> None:
        with mock.patch(
            "run_ui_test_groups.subprocess.run",
            side_effect=subprocess.TimeoutExpired(cmd=["xcrun", "simctl", "terminate"], timeout=15),
        ) as run_mock:
            with mock.patch("run_ui_test_groups.print") as print_mock:
                terminate_app_if_running(
                    simulator_id="SIM-1",
                    bundle_identifier="org.andbible.ios",
                    timeout_seconds=15,
                )

        run_mock.assert_called_once()
        print_mock.assert_any_call(
            "Running: xcrun simctl terminate SIM-1 org.andbible.ios (best-effort)",
            flush=True,
        )
        print_mock.assert_any_call(
            "simctl terminate timed out after 15s for org.andbible.ios; continuing.",
            flush=True,
        )

    def test_install_app_with_retry_retries_after_timeout(self) -> None:
        with mock.patch(
            "run_ui_test_groups.run_command",
            side_effect=[
                subprocess.TimeoutExpired(cmd=["xcrun", "simctl", "install"], timeout=120),
                mock.Mock(),
            ],
        ) as run_command_mock:
            with mock.patch("run_ui_test_groups.terminate_app_if_running") as terminate_mock:
                with mock.patch("run_ui_test_groups.uninstall_app_if_installed") as uninstall_mock:
                    install_app_with_retry(
                        simulator_id="SIM-1",
                        app_path=pathlib.Path("/tmp/AndBible.app"),
                        bundle_identifier="org.andbible.ios",
                    )

        self.assertEqual(run_command_mock.call_count, 2)
        terminate_mock.assert_called_once_with(
            simulator_id="SIM-1",
            bundle_identifier="org.andbible.ios",
        )
        uninstall_mock.assert_called_once_with(
            simulator_id="SIM-1",
            bundle_identifier="org.andbible.ios",
        )

    def test_install_app_with_retry_raises_after_second_failure(self) -> None:
        failure = subprocess.CalledProcessError(
            returncode=1,
            cmd=["xcrun", "simctl", "install"],
        )
        with mock.patch(
            "run_ui_test_groups.run_command",
            side_effect=[failure, failure],
        ):
            with mock.patch("run_ui_test_groups.terminate_app_if_running"):
                with mock.patch("run_ui_test_groups.uninstall_app_if_installed"):
                    with self.assertRaises(subprocess.CalledProcessError):
                        install_app_with_retry(
                            simulator_id="SIM-1",
                            app_path=pathlib.Path("/tmp/AndBible.app"),
                            bundle_identifier="org.andbible.ios",
                        )


class CliTests(unittest.TestCase):
    def test_main_reads_selection_args_from_environment_when_flag_is_omitted(self) -> None:
        argv = [
            "--project", "AndBible.xcodeproj",
            "--scheme", "AndBible",
            "--configuration", "Debug",
            "--destination", "id=SIM-1",
            "--simulator-id", "SIM-1",
            "--derived-data-path", ".derivedData",
            "--result-bundle-path", ".artifacts/AndBibleTests-ui.xcresult",
            "--fixture-manifest", "scripts/ui_test_fixture_manifest.json",
            "--fixture-tool-path", ".build/debug/UITestFixtureTool",
        ]
        with mock.patch.dict(os.environ, {"TEST_SELECTION_ARGS": "-only-testing:AndBibleUITests/AndBibleUITests/testOne"}):
            with mock.patch("run_ui_test_groups.run_grouped_ui_tests", return_value=0) as runner:
                self.assertEqual(main(argv), 0)

        runner.assert_called_once()
        self.assertEqual(
            runner.call_args.kwargs["selection_args_text"],
            "-only-testing:AndBibleUITests/AndBibleUITests/testOne",
        )

    def test_parser_defaults_bundle_identifier(self) -> None:
        parser = create_argument_parser()
        args = parser.parse_args(
            [
                "--project", "AndBible.xcodeproj",
                "--scheme", "AndBible",
                "--configuration", "Debug",
                "--destination", "id=SIM-1",
                "--simulator-id", "SIM-1",
                "--derived-data-path", ".derivedData",
                "--result-bundle-path", ".artifacts/AndBibleTests-ui.xcresult",
                "--fixture-manifest", "scripts/ui_test_fixture_manifest.json",
                "--fixture-tool-path", ".build/debug/UITestFixtureTool",
            ]
        )
        self.assertEqual(args.bundle_id, DEFAULT_BUNDLE_IDENTIFIER)


class GroupedExecutionTests(unittest.TestCase):
    def test_run_grouped_ui_tests_waits_between_groups_and_terminates_apps(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = pathlib.Path(temp_dir) / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "AndBibleUITests/AndBibleUITests/testOne": "alpha",
                        "AndBibleUITests/AndBibleUITests/testTwo": "beta",
                    }
                ),
                encoding="utf-8",
            )
            fixture_tool_path = pathlib.Path(temp_dir) / "UITestFixtureTool"
            fixture_tool_path.write_text("", encoding="utf-8")

            with mock.patch("run_ui_test_groups.build_xcodebuild_command", side_effect=[["xcodebuild", "alpha"], ["xcodebuild", "beta"]]):
                with mock.patch("run_ui_test_groups.run_command") as run_command_mock:
                    with mock.patch("run_ui_test_groups.terminate_app_if_running") as terminate_mock:
                        with mock.patch("run_ui_test_groups.time.sleep") as sleep_mock:
                            result = run_grouped_ui_tests(
                                project="AndBible.xcodeproj",
                                scheme="AndBible",
                                configuration="Debug",
                                destination="id=SIM-1",
                                simulator_id="SIM-1",
                                derived_data_path=pathlib.Path(".derivedData"),
                                result_bundle_path=pathlib.Path(".artifacts/AndBibleTests-ui.xcresult"),
                                code_signing_allowed="NO",
                                selection_args_text=(
                                    "-only-testing:AndBibleUITests/AndBibleUITests/testOne\n"
                                    "-only-testing:AndBibleUITests/AndBibleUITests/testTwo"
                                ),
                                fixture_manifest_path=manifest_path,
                                fixture_tool_path=fixture_tool_path,
                                bundle_identifier="org.andbible.ios",
                                app_path=None,
                            )

        self.assertEqual(result, 0)
        self.assertEqual(run_command_mock.call_count, 2)
        self.assertEqual(
            terminate_mock.call_args_list,
            [
                mock.call(simulator_id="SIM-1", bundle_identifier="org.andbible.ios"),
                mock.call(simulator_id="SIM-1", bundle_identifier="org.andbible.AndBibleUITests.xctrunner"),
                mock.call(simulator_id="SIM-1", bundle_identifier="org.andbible.ios"),
                mock.call(simulator_id="SIM-1", bundle_identifier="org.andbible.AndBibleUITests.xctrunner"),
            ],
        )
        sleep_mock.assert_called_once_with(15)

    def test_run_grouped_ui_tests_continues_after_group_failure_and_returns_one(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = pathlib.Path(temp_dir) / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "AndBibleUITests/AndBibleUITests/testOne": "alpha",
                        "AndBibleUITests/AndBibleUITests/testTwo": "beta",
                    }
                ),
                encoding="utf-8",
            )
            fixture_tool_path = pathlib.Path(temp_dir) / "UITestFixtureTool"
            fixture_tool_path.write_text("", encoding="utf-8")

            with mock.patch(
                "run_ui_test_groups.build_xcodebuild_command",
                side_effect=[["xcodebuild", "alpha"], ["xcodebuild", "beta"]],
            ):
                with mock.patch(
                    "run_ui_test_groups.run_command",
                    side_effect=[
                        subprocess.CalledProcessError(returncode=65, cmd=["xcodebuild", "alpha"]),
                        subprocess.CompletedProcess(args=["xcodebuild", "beta"], returncode=0),
                    ],
                ) as run_command_mock:
                    with mock.patch("run_ui_test_groups.terminate_app_if_running") as terminate_mock:
                        with mock.patch("run_ui_test_groups.time.sleep") as sleep_mock:
                            result = run_grouped_ui_tests(
                                project="AndBible.xcodeproj",
                                scheme="AndBible",
                                configuration="Debug",
                                destination="id=SIM-1",
                                simulator_id="SIM-1",
                                derived_data_path=pathlib.Path(".derivedData"),
                                result_bundle_path=pathlib.Path(".artifacts/AndBibleTests-ui.xcresult"),
                                code_signing_allowed="NO",
                                selection_args_text=(
                                    "-only-testing:AndBibleUITests/AndBibleUITests/testOne\n"
                                    "-only-testing:AndBibleUITests/AndBibleUITests/testTwo"
                                ),
                                fixture_manifest_path=manifest_path,
                                fixture_tool_path=fixture_tool_path,
                                bundle_identifier="org.andbible.ios",
                                app_path=None,
                            )

        self.assertEqual(result, 1)
        self.assertEqual(run_command_mock.call_count, 2)
        self.assertEqual(
            terminate_mock.call_args_list,
            [
                mock.call(simulator_id="SIM-1", bundle_identifier="org.andbible.ios"),
                mock.call(simulator_id="SIM-1", bundle_identifier="org.andbible.AndBibleUITests.xctrunner"),
                mock.call(simulator_id="SIM-1", bundle_identifier="org.andbible.ios"),
                mock.call(simulator_id="SIM-1", bundle_identifier="org.andbible.AndBibleUITests.xctrunner"),
            ],
        )
        sleep_mock.assert_called_once_with(15)

    def test_run_grouped_ui_tests_can_create_fresh_simulator_per_group(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = pathlib.Path(temp_dir) / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "AndBibleUITests/AndBibleUITests/testOne": "alpha",
                        "AndBibleUITests/AndBibleUITests/testTwo": "beta",
                    }
                ),
                encoding="utf-8",
            )
            fixture_tool_path = pathlib.Path(temp_dir) / "UITestFixtureTool"
            fixture_tool_path.write_text("", encoding="utf-8")

            with mock.patch(
                "run_ui_test_groups.build_xcodebuild_command",
                side_effect=[["xcodebuild", "alpha"], ["xcodebuild", "beta"]],
            ):
                with mock.patch("run_ui_test_groups.create_group_simulator", side_effect=[("SIM-A", "id=SIM-A"), ("SIM-B", "id=SIM-B")]) as create_mock:
                    with mock.patch("run_ui_test_groups.run_command") as run_command_mock:
                        with mock.patch("run_ui_test_groups.terminate_app_if_running") as terminate_mock:
                            with mock.patch("run_ui_test_groups.shutdown_simulator_if_running") as shutdown_mock:
                                with mock.patch("run_ui_test_groups.delete_simulator_if_present") as delete_mock:
                                    with mock.patch("run_ui_test_groups.time.sleep") as sleep_mock:
                                        result = run_grouped_ui_tests(
                                            project="AndBible.xcodeproj",
                                            scheme="AndBible",
                                            configuration="Debug",
                                            destination="id=BASE",
                                            simulator_id="BASE",
                                            derived_data_path=pathlib.Path(".derivedData"),
                                            result_bundle_path=pathlib.Path(".artifacts/AndBibleTests-ui.xcresult"),
                                            code_signing_allowed="NO",
                                            selection_args_text=(
                                                "-only-testing:AndBibleUITests/AndBibleUITests/testOne\n"
                                                "-only-testing:AndBibleUITests/AndBibleUITests/testTwo"
                                            ),
                                            fixture_manifest_path=manifest_path,
                                            fixture_tool_path=fixture_tool_path,
                                            bundle_identifier="org.andbible.ios",
                                            app_path=None,
                                            fresh_simulator_per_group=True,
                                        )

        self.assertEqual(result, 0)
        self.assertEqual(create_mock.call_count, 2)
        self.assertEqual(run_command_mock.call_count, 2)
        terminate_mock.assert_has_calls(
            [
                mock.call(simulator_id="SIM-A", bundle_identifier="org.andbible.ios"),
                mock.call(simulator_id="SIM-A", bundle_identifier="org.andbible.AndBibleUITests.xctrunner"),
                mock.call(simulator_id="SIM-B", bundle_identifier="org.andbible.ios"),
                mock.call(simulator_id="SIM-B", bundle_identifier="org.andbible.AndBibleUITests.xctrunner"),
            ]
        )
        shutdown_mock.assert_has_calls(
            [
                mock.call(simulator_id="SIM-A"),
                mock.call(simulator_id="SIM-B"),
            ]
        )
        delete_mock.assert_has_calls(
            [
                mock.call(simulator_id="SIM-A"),
                mock.call(simulator_id="SIM-B"),
            ]
        )
        sleep_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
