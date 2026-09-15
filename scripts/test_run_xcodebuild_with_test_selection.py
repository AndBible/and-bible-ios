"""Tests for run_xcodebuild_with_test_selection."""

from __future__ import annotations

import contextlib
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
RUNNER_PATH = pathlib.Path(__file__).resolve().parent / "run_xcodebuild_with_test_selection.py"

from run_xcodebuild_with_test_selection import (
    ResultBundleValidationError,
    UITestApplicationProduct,
    build_xcodebuild_command,
    discover_single_xctestrun_path,
    fixture_service_configuration,
    main,
    parse_test_selection_args,
    patch_xctestrun_ui_test_environment,
    requested_test_identifiers,
    resolve_ui_test_application_product,
    result_bundle_reports_passing_tests,
    selected_xcode_developer_dir_from_link,
    selected_ui_test_developer_dir,
    selection_requests_ui_tests,
    simulator_id_from_destination,
    test_results_from_xcresult_nodes,
    temporary_patched_xctestrun_ui_test_environment,
    ui_test_host_environment_variables,
    ui_test_fixture_service_session,
)
from ui_test_fixture_service import FixtureServiceError


SIMULATOR_ID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"


def test_report_payload(*test_results: tuple[str, str]) -> dict[str, object]:
    """Build an xcresult test-node payload using the documented hierarchy."""
    return {
        "testPlanConfigurations": [],
        "devices": [],
        "testNodes": [
            {
                "nodeType": "Unit test bundle",
                "name": "AndBibleTests.xctest",
                "children": [
                    {
                        "nodeType": "Test Suite",
                        "name": "AndBibleTests",
                        "children": [
                            {
                                "nodeType": "Test Case",
                                "name": f"{method}()",
                                "result": result,
                            }
                            for method, result in test_results
                        ],
                    }
                ],
            }
        ],
    }


def write_ui_test_application_product(
    products_path: pathlib.Path,
    *,
    bundle_identifier: str = "org.andbible.ios",
    supported_platforms: list[str] | None = None,
) -> pathlib.Path:
    """Write the minimal verified simulator app used by wrapper unit tests."""
    application_path = products_path / "Debug-iphonesimulator" / "AndBible.app"
    application_path.mkdir(parents=True)
    executable_path = application_path / "AndBible"
    executable_path.write_bytes(b"simulator executable")
    with (application_path / "Info.plist").open("wb") as plist_file:
        plistlib.dump(
            {
                "CFBundleIdentifier": bundle_identifier,
                "CFBundleExecutable": "AndBible",
                "CFBundleSupportedPlatforms": supported_platforms or ["iPhoneSimulator"],
                "DTPlatformName": "iphonesimulator",
            },
            plist_file,
        )
    return application_path


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

    def test_requested_test_identifiers_reconciles_target_selection_and_skips(self) -> None:
        discovered = [
            "AndBibleTests/AndBibleTests/testAlpha",
            "AndBibleTests/AndBibleTests/testBeta",
            "OtherTests/OtherTests/testGamma",
        ]

        self.assertEqual(
            requested_test_identifiers(
                "-only-testing:AndBibleTests\n"
                "-skip-testing:AndBibleTests/AndBibleTests/testBeta",
                discovered,
            ),
            ["AndBibleTests/AndBibleTests/testAlpha"],
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
            selection_args_text="-only-testing:AndBibleUITests/AndBibleUITests/testSettingsApplicationShortcutsOpenGlobalTextOptions",
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
                "-only-testing:AndBibleUITests/AndBibleUITests/testSettingsApplicationShortcutsOpenGlobalTextOptions",
                "test-without-building",
            ],
        )

    def test_test_without_building_can_disable_diagnostic_collection_explicitly(self) -> None:
        """Forward only the public per-run Xcode policy while retaining result output."""
        command = build_xcodebuild_command(
            project=None,
            scheme=None,
            configuration=None,
            destination="id=DEVICE",
            derived_data_path=None,
            result_bundle_path=".artifacts/KnownFailure.xcresult",
            code_signing_allowed="NO",
            selection_args_text=(
                "-only-testing:BibleCoreTests/SettingsStoreTests/testKnownFailure"
            ),
            action="test-without-building",
            xctestrun_path=".derivedData/Build/Products/AndBible_iphonesimulator.xctestrun",
            collect_test_diagnostics="never",
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
                ".artifacts/KnownFailure.xcresult",
                "-collect-test-diagnostics",
                "never",
                "CODE_SIGNING_ALLOWED=NO",
                "-only-testing:BibleCoreTests/SettingsStoreTests/testKnownFailure",
                "test-without-building",
            ],
        )

    def test_diagnostic_collection_policy_is_rejected_for_build_only_action(self) -> None:
        """Avoid presenting a test-only diagnostic control on a build-only operation."""
        with self.assertRaisesRegex(
            ValueError,
            "can only be used with test-without-building",
        ):
            build_xcodebuild_command(
                project="AndBible.xcodeproj",
                scheme="AndBible",
                configuration="Debug",
                destination="id=DEVICE",
                derived_data_path=".derivedData",
                result_bundle_path=".artifacts/AndBibleBuild.xcresult",
                code_signing_allowed="NO",
                selection_args_text="",
                action="build-for-testing",
                collect_test_diagnostics="never",
            )

    def test_diagnostic_collection_policy_rejects_nonpublic_values(self) -> None:
        """Keep arbitrary or private xcodebuild flags out of the wrapper contract."""
        with self.assertRaisesRegex(
            ValueError,
            "must be on-failure, never, or omitted",
        ):
            build_xcodebuild_command(
                project=None,
                scheme=None,
                configuration=None,
                destination="id=DEVICE",
                derived_data_path=None,
                result_bundle_path=".artifacts/Tests.xcresult",
                code_signing_allowed="NO",
                selection_args_text="",
                action="test-without-building",
                xctestrun_path=".derivedData/Build/Products/AndBible_iphonesimulator.xctestrun",
                collect_test_diagnostics="automatic",
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
    def test_simulator_id_from_destination_requires_one_canonical_uuid(self) -> None:
        self.assertEqual(
            simulator_id_from_destination(
                f"platform=iOS Simulator,id={SIMULATOR_ID},OS=17.5"
            ),
            SIMULATOR_ID,
        )
        with self.assertRaisesRegex(ValueError, "one explicit simulator id"):
            simulator_id_from_destination("platform=iOS Simulator,name=iPhone SE")
        with self.assertRaisesRegex(ValueError, "must be a simulator UUID"):
            simulator_id_from_destination("id=DEVICE")

    def test_fixture_service_configuration_allows_only_the_configured_performance_scale(
        self,
    ) -> None:
        configuration = fixture_service_configuration(
            directory=pathlib.Path("/private/tmp/service"),
            destination=f"platform=iOS Simulator,id={SIMULATOR_ID}",
            environment={
                "UITEST_SIMULATOR_ID": SIMULATOR_ID,
                "UITEST_BUNDLE_ID": "org.andbible.ios",
                "UITEST_FIXTURE_TOOL_PATH": "/fixtures/UITestFixtureTool",
                "UITEST_FIXTURE_MANIFEST_PATH": "/fixtures/manifest.json",
                "UITEST_SWORD_FIXTURE_PATH": "/fixtures/sword",
                "PERFORMANCE_LIBRARY_SCALE": "10000",
            },
        )

        self.assertEqual(
            configuration.additional_allowed_scenarios,
            frozenset({"performance-bookmarks-10000"}),
        )
        small_configuration = fixture_service_configuration(
            directory=pathlib.Path("/private/tmp/service"),
            destination=f"id={SIMULATOR_ID}",
            environment={
                "UITEST_SIMULATOR_ID": SIMULATOR_ID,
                "UITEST_BUNDLE_ID": "org.andbible.ios",
                "UITEST_FIXTURE_TOOL_PATH": "/fixtures/UITestFixtureTool",
                "UITEST_FIXTURE_MANIFEST_PATH": "/fixtures/manifest.json",
                "UITEST_SWORD_FIXTURE_PATH": "/fixtures/sword",
                "PERFORMANCE_LIBRARY_SCALE": "small",
            },
        )
        self.assertEqual(small_configuration.additional_allowed_scenarios, frozenset())

        with self.assertRaisesRegex(ValueError, "must be small, 10, 1000, or 10000"):
            fixture_service_configuration(
                directory=pathlib.Path("/private/tmp/service"),
                destination=f"id={SIMULATOR_ID}",
                environment={
                    "UITEST_SIMULATOR_ID": SIMULATOR_ID,
                    "UITEST_BUNDLE_ID": "org.andbible.ios",
                    "UITEST_FIXTURE_TOOL_PATH": "/fixtures/UITestFixtureTool",
                    "UITEST_FIXTURE_MANIFEST_PATH": "/fixtures/manifest.json",
                    "UITEST_SWORD_FIXTURE_PATH": "/fixtures/sword",
                    "PERFORMANCE_LIBRARY_SCALE": "all",
                },
            )

    def test_fixture_service_session_cleans_directory_and_restores_environment_on_failure(
        self,
    ) -> None:
        captured: dict[str, object] = {}
        events: list[str] = []

        class FakeService:
            def __init__(self, configuration) -> None:
                captured["configuration"] = configuration
                self.configuration = configuration

            def start(self) -> None:
                events.append("start")
                self.configuration.directory.mkdir(mode=0o700)
                captured["started"] = True

            def stop(self) -> None:
                events.append("stop")
                captured["stopped"] = True

        def fake_installer(**arguments) -> None:
            events.append("install")
            captured["install_arguments"] = arguments

        environment = {
            "UITEST_SIMULATOR_ID": SIMULATOR_ID,
            "UITEST_BUNDLE_ID": "org.andbible.ios",
            "UITEST_FIXTURE_TOOL_PATH": "/fixtures/UITestFixtureTool",
            "UITEST_FIXTURE_MANIFEST_PATH": "/fixtures/manifest.json",
            "UITEST_SWORD_FIXTURE_PATH": "/fixtures/sword",
        }
        service_directory: pathlib.Path | None = None
        with self.assertRaisesRegex(RuntimeError, "xcodebuild failed"):
            with ui_test_fixture_service_session(
                destination=f"id={SIMULATOR_ID}",
                environment=environment,
                application_path=pathlib.Path("/products/AndBible.app"),
                service_factory=FakeService,
                application_installer=fake_installer,
            ) as directory:
                service_directory = directory
                self.assertEqual(
                    environment["UITEST_FIXTURE_SERVICE_DIRECTORY"],
                    str(directory),
                )
                self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
                raise RuntimeError("xcodebuild failed")

        self.assertTrue(captured["started"])
        self.assertTrue(captured["stopped"])
        self.assertEqual(events, ["install", "start", "stop"])
        self.assertEqual(
            captured["install_arguments"],
            {
                "simulator_id": SIMULATOR_ID,
                "application_path": pathlib.Path("/products/AndBible.app"),
            },
        )
        self.assertNotIn("UITEST_FIXTURE_SERVICE_DIRECTORY", environment)
        self.assertIsNotNone(service_directory)
        self.assertFalse(service_directory.exists())

    def test_fixture_service_session_does_not_start_service_after_install_failure(self) -> None:
        events: list[str] = []

        class FakeService:
            def __init__(self, _configuration) -> None:
                events.append("validated")

            def start(self) -> None:
                events.append("start")

            def stop(self) -> None:
                events.append("stop")

        def failing_installer(**_arguments) -> None:
            events.append("install")
            raise FixtureServiceError("CoreSimulator install failed")

        environment = {
            "UITEST_SIMULATOR_ID": SIMULATOR_ID,
            "UITEST_BUNDLE_ID": "org.andbible.ios",
            "UITEST_FIXTURE_TOOL_PATH": "/fixtures/UITestFixtureTool",
            "UITEST_FIXTURE_MANIFEST_PATH": "/fixtures/manifest.json",
            "UITEST_SWORD_FIXTURE_PATH": "/fixtures/sword",
        }
        with self.assertRaisesRegex(FixtureServiceError, "install failed"):
            with ui_test_fixture_service_session(
                destination=f"id={SIMULATOR_ID}",
                environment=environment,
                application_path=pathlib.Path("/products/AndBible.app"),
                service_factory=FakeService,
                application_installer=failing_installer,
            ):
                self.fail("session must not start after an install failure")

        self.assertEqual(events, ["validated", "install"])
        self.assertNotIn("UITEST_FIXTURE_SERVICE_DIRECTORY", environment)

    def test_ui_test_host_environment_variables_forwards_only_client_inputs(self) -> None:
        self.assertEqual(
            ui_test_host_environment_variables(
                {
                    "HOME": "/Users/runner",
                    "TMPDIR": "/var/folders/ci/T/",
                    "USER": "runner",
                    "LOGNAME": "runner",
                    "__CF_USER_TEXT_ENCODING": "501:0:0",
                    "UITEST_FIXTURE_MANIFEST_PATH": "/fixtures/manifest.json",
                    "UITEST_FIXTURE_SERVICE_DIRECTORY": "/private/tmp/service",
                    "UITEST_BUNDLE_ID": "org.andbible.ios",
                    "UITEST_FIXTURE_TOOL_PATH": "/fixtures/UITestFixtureTool",
                }
            ),
            {
                "UITEST_FIXTURE_MANIFEST_PATH": "/fixtures/manifest.json",
                "UITEST_FIXTURE_SERVICE_DIRECTORY": "/private/tmp/service",
                "UITEST_BUNDLE_ID": "org.andbible.ios",
            },
        )

    def test_relative_fixture_paths_survive_xctest_working_directory_change(self) -> None:
        """The generated XCTest environment locates host fixtures from another directory."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            checkout = root / "checkout"
            checkout.mkdir()
            manifest = checkout / "manifest.json"
            manifest.write_text('{"scenario":"reader"}')
            service = checkout / "service"
            service.mkdir()
            (service / "ready").write_text("ready")
            xctestrun = checkout / "AndBible.xctestrun"
            with xctestrun.open("wb") as output:
                plistlib.dump({"UI": {"IsUITestBundle": True}}, output)
            with contextlib.chdir(checkout):
                patch_xctestrun_ui_test_environment(str(xctestrun), {
                    "UITEST_FIXTURE_MANIFEST_PATH": "manifest.json",
                    "UITEST_FIXTURE_SERVICE_DIRECTORY": "service",
                })
            with xctestrun.open("rb") as source:
                target = plistlib.load(source)["UI"]
            for environment_key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
                script = (
                    "import json,pathlib,sys; e=json.loads(sys.argv[1]); "
                    "print(pathlib.Path(e['UITEST_FIXTURE_MANIFEST_PATH']).read_text()); "
                    "print((pathlib.Path(e['UITEST_FIXTURE_SERVICE_DIRECTORY'])/'ready').read_text())"
                )
                result = subprocess.run(
                    [sys.executable, "-c", script, json.dumps(target[environment_key])],
                    cwd=root, capture_output=True, text=True, check=True,
                )
                self.assertEqual(result.stdout.splitlines(), ['{"scenario":"reader"}', "ready"])

    def test_selection_requests_ui_tests_for_only_testing_ui_target(self) -> None:
        selection = """
        -only-testing:AndBibleUITests/AndBibleUITests/testSettingsApplicationShortcutsOpenGlobalTextOptions
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
            temporary_path = pathlib.Path(temporary_directory)
            products_path = temporary_path / "Build" / "Products"
            products_path.mkdir(parents=True)
            xctestrun_path = products_path / "AndBible_iphonesimulator.xctestrun"
            xctestrun_path.write_bytes(b"")

            self.assertEqual(
                discover_single_xctestrun_path(temporary_directory),
                str(xctestrun_path),
            )

            (products_path / "Other_iphonesimulator.xctestrun").write_bytes(b"")
            self.assertIsNone(discover_single_xctestrun_path(temporary_directory))

    def test_resolve_ui_test_application_product_uses_testroot_and_app_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            products_path = pathlib.Path(temporary_directory)
            application_path = write_ui_test_application_product(products_path)
            xctestrun_path = products_path / "AndBible.xctestrun"
            with xctestrun_path.open("wb") as plist_file:
                plistlib.dump(
                    {
                        "AndBibleUITests": {
                            "IsUITestBundle": True,
                            "UITargetAppPath": (
                                "__TESTROOT__/Debug-iphonesimulator/AndBible.app"
                            ),
                        }
                    },
                    plist_file,
                )

            product = resolve_ui_test_application_product(
                str(xctestrun_path),
                expected_bundle_identifier="org.andbible.ios",
            )

            self.assertEqual(
                product,
                UITestApplicationProduct(
                    path=application_path.resolve(),
                    bundle_identifier="org.andbible.ios",
                ),
            )

    def test_resolve_ui_test_application_product_supports_format_two(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            products_path = pathlib.Path(temporary_directory)
            application_path = write_ui_test_application_product(products_path)
            xctestrun_path = products_path / "AndBible.xctestrun"
            with xctestrun_path.open("wb") as plist_file:
                plistlib.dump(
                    {
                        "TestConfigurations": [
                            {
                                "TestTargets": [
                                    {
                                        "IsUITestBundle": True,
                                        "UITargetAppPath": (
                                            "__TESTROOT__/Debug-iphonesimulator/AndBible.app"
                                        ),
                                        "UITargetAppBundleIdentifier": "org.andbible.ios",
                                    }
                                ]
                            }
                        ]
                    },
                    plist_file,
                )

            product = resolve_ui_test_application_product(
                str(xctestrun_path),
                expected_bundle_identifier="org.andbible.ios",
            )

            self.assertEqual(product.path, application_path.resolve())

    def test_resolve_ui_test_application_product_rejects_untrusted_or_wrong_product(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            products_path = pathlib.Path(temporary_directory)
            write_ui_test_application_product(
                products_path,
                bundle_identifier="org.example.wrong",
            )
            xctestrun_path = products_path / "AndBible.xctestrun"
            with xctestrun_path.open("wb") as plist_file:
                plistlib.dump(
                    {
                        "AndBibleUITests": {
                            "IsUITestBundle": True,
                            "UITargetAppPath": (
                                "__TESTROOT__/Debug-iphonesimulator/AndBible.app"
                            ),
                        }
                    },
                    plist_file,
                )
            with self.assertRaisesRegex(ValueError, "bundle identifier does not match"):
                resolve_ui_test_application_product(
                    str(xctestrun_path),
                    expected_bundle_identifier="org.andbible.ios",
                )

            with xctestrun_path.open("wb") as plist_file:
                plistlib.dump(
                    {
                        "AndBibleUITests": {
                            "IsUITestBundle": True,
                            "UITargetAppPath": "/tmp/untrusted/AndBible.app",
                        }
                    },
                    plist_file,
                )
            with self.assertRaisesRegex(ValueError, "rooted at __TESTROOT__"):
                resolve_ui_test_application_product(
                    str(xctestrun_path),
                    expected_bundle_identifier="org.andbible.ios",
                )

    def test_resolve_ui_test_application_product_rejects_device_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            products_path = pathlib.Path(temporary_directory)
            write_ui_test_application_product(
                products_path,
                supported_platforms=["iPhoneOS"],
            )
            xctestrun_path = products_path / "AndBible.xctestrun"
            with xctestrun_path.open("wb") as plist_file:
                plistlib.dump(
                    {
                        "AndBibleUITests": {
                            "IsUITestBundle": True,
                            "UITargetAppPath": (
                                "__TESTROOT__/Debug-iphonesimulator/AndBible.app"
                            ),
                        }
                    },
                    plist_file,
                )

            with self.assertRaisesRegex(ValueError, "not an iOS Simulator product"):
                resolve_ui_test_application_product(
                    str(xctestrun_path),
                    expected_bundle_identifier="org.andbible.ios",
                )

    def test_patch_xctestrun_ui_test_environment_updates_only_ui_test_bundle(self) -> None:
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

            patched = patch_xctestrun_ui_test_environment(
                str(xctestrun_path),
                host_environment={
                    "HOME": "/Users/runner",
                    "TMPDIR": "/var/folders/ci/T/",
                    "USER": "runner",
                    "LOGNAME": "runner",
                    "__CF_USER_TEXT_ENCODING": "501:0:0",
                    "UITEST_FIXTURE_TOOL_PATH": "/consumer/.build/debug/UITestFixtureTool",
                    "UITEST_FIXTURE_MANIFEST_PATH": "/consumer/.ui-test/fixtures/ui_test_fixture_manifest.json",
                    "UITEST_SWORD_FIXTURE_PATH": "/consumer/.ui-test/fixtures/sword",
                    "UITEST_SIMULATOR_ID": "SIMULATOR-UDID",
                    "UITEST_BUNDLE_ID": "org.andbible.ios",
                    "UITEST_FIXTURE_SERVICE_DIRECTORY": "/private/tmp/service",
                    "UNRELATED_SECRET": "must-not-be-forwarded",
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
            expected_fixture_inputs = {
                "UITEST_FIXTURE_MANIFEST_PATH": "/consumer/.ui-test/fixtures/ui_test_fixture_manifest.json",
                "UITEST_SIMULATOR_ID": "SIMULATOR-UDID",
                "UITEST_BUNDLE_ID": "org.andbible.ios",
                "UITEST_FIXTURE_SERVICE_DIRECTORY": "/private/tmp/service",
            }
            for key, value in expected_fixture_inputs.items():
                self.assertEqual(ui_environment[key], value)
                self.assertEqual(ui_testing_environment[key], value)
            self.assertNotIn("UNRELATED_SECRET", ui_environment)
            self.assertNotIn("UNRELATED_SECRET", ui_testing_environment)
            self.assertNotIn("UITEST_FIXTURE_TOOL_PATH", ui_environment)
            self.assertNotIn("UITEST_SWORD_FIXTURE_PATH", ui_environment)
            self.assertNotIn("UITEST_HOST_HOME", ui_environment)
            self.assertNotIn(
                "DEVELOPER_DIR",
                patched_xctestrun["AndBibleTests"]["EnvironmentVariables"],
            )

    def test_patch_xctestrun_supports_format_two_test_targets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            xctestrun_path = pathlib.Path(temporary_directory) / "PackageTests.xctestrun"
            with xctestrun_path.open("wb") as plist_file:
                plistlib.dump(
                    {
                        "TestConfigurations": [
                            {
                                "Name": "Test Scheme Action",
                                "TestTargets": [
                                    {
                                        "BlueprintName": "AndBibleUITests",
                                        "IsUITestBundle": True,
                                        "EnvironmentVariables": {},
                                        "TestingEnvironmentVariables": {},
                                    }
                                ],
                            }
                        ]
                    },
                    plist_file,
                )

            self.assertTrue(
                patch_xctestrun_ui_test_environment(
                    str(xctestrun_path),
                    host_environment={
                        "UITEST_FIXTURE_SERVICE_DIRECTORY": "/private/tmp/service"
                    },
                )
            )
            with xctestrun_path.open("rb") as plist_file:
                patched = plistlib.load(plist_file)
            target = patched["TestConfigurations"][0]["TestTargets"][0]
            self.assertEqual(
                target["TestingEnvironmentVariables"]["UITEST_FIXTURE_SERVICE_DIRECTORY"],
                "/private/tmp/service",
            )

    def test_temporary_patch_preserves_original_and_cleans_same_directory_copy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            products_path = pathlib.Path(temporary_directory)
            xctestrun_path = products_path / "AndBible.xctestrun"
            with xctestrun_path.open("wb") as plist_file:
                plistlib.dump(
                    {
                        "AndBibleUITests": {
                            "IsUITestBundle": True,
                            "EnvironmentVariables": {"PORTABLE": "true"},
                            "TestingEnvironmentVariables": {},
                        }
                    },
                    plist_file,
                )
            original_bytes = xctestrun_path.read_bytes()

            with temporary_patched_xctestrun_ui_test_environment(
                str(xctestrun_path),
                host_environment={
                    "UITEST_FIXTURE_SERVICE_DIRECTORY": "/private/tmp/run-private-service"
                },
            ) as temporary_name:
                temporary_path = pathlib.Path(temporary_name)
                self.assertEqual(temporary_path.parent, products_path)
                self.assertTrue(temporary_path.name.startswith(".AndBible-ui-environment-"))
                self.assertTrue(temporary_path.exists())
                with temporary_path.open("rb") as plist_file:
                    temporary_xctestrun = plistlib.load(plist_file)
                self.assertEqual(
                    temporary_xctestrun["AndBibleUITests"]["EnvironmentVariables"][
                        "UITEST_FIXTURE_SERVICE_DIRECTORY"
                    ],
                    "/private/tmp/run-private-service",
                )
                self.assertEqual(xctestrun_path.read_bytes(), original_bytes)

            self.assertFalse(temporary_path.exists())
            self.assertEqual(xctestrun_path.read_bytes(), original_bytes)

    def test_temporary_patch_cleans_copy_when_xcodebuild_scope_raises(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            xctestrun_path = pathlib.Path(temporary_directory) / "AndBible.xctestrun"
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

            temporary_path: pathlib.Path | None = None
            with self.assertRaisesRegex(RuntimeError, "xcodebuild failed"):
                with temporary_patched_xctestrun_ui_test_environment(
                    str(xctestrun_path),
                    host_environment={
                        "UITEST_FIXTURE_SERVICE_DIRECTORY": "/private/tmp/run-private-service"
                    },
                ) as temporary_name:
                    temporary_path = pathlib.Path(temporary_name)
                    raise RuntimeError("xcodebuild failed")

            self.assertIsNotNone(temporary_path)
            self.assertFalse(temporary_path.exists())

    def test_temporary_patch_failure_leaves_no_copy_or_original_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            products_path = pathlib.Path(temporary_directory)
            xctestrun_path = products_path / "AndBible.xctestrun"
            with xctestrun_path.open("wb") as plist_file:
                plistlib.dump(
                    {"AndBibleTests": {"EnvironmentVariables": {"PORTABLE": "true"}}},
                    plist_file,
                )
            original_bytes = xctestrun_path.read_bytes()

            with self.assertRaisesRegex(ValueError, "contains no UI-test bundle"):
                with temporary_patched_xctestrun_ui_test_environment(
                    str(xctestrun_path),
                    host_environment={
                        "UITEST_FIXTURE_SERVICE_DIRECTORY": "/private/tmp/run-private-service"
                    },
                ):
                    self.fail("A non-UI xctestrun must fail before entering the run scope")

            self.assertEqual(list(products_path.iterdir()), [xctestrun_path])
            self.assertEqual(xctestrun_path.read_bytes(), original_bytes)


class MainTests(unittest.TestCase):
    @mock.patch(
        "run_xcodebuild_with_test_selection.result_bundle_reports_passing_tests",
        return_value=True,
    )
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_forwards_explicit_test_diagnostic_policy_without_changing_reconciliation(
        self,
        run_mock: mock.Mock,
        result_bundle_mock: mock.Mock,
    ) -> None:
        """Forward one public policy and still reconcile the exact selected identity."""
        selection = "-only-testing:AndBibleTests/AndBibleTests/testKnownFailure"
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
                ".artifacts/KnownFailure.xcresult",
                f"--test-selection-args={selection}",
                "--collect-test-diagnostics",
                "never",
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
                ".artifacts/KnownFailure.xcresult",
                "-collect-test-diagnostics",
                "never",
                "CODE_SIGNING_ALLOWED=NO",
                selection,
                "test-without-building",
            ],
            check=True,
        )
        result_bundle_mock.assert_called_once_with(
            ".artifacts/KnownFailure.xcresult",
            ["AndBibleTests/AndBibleTests/testKnownFailure"],
        )

    @mock.patch(
        "run_xcodebuild_with_test_selection.result_bundle_reports_passing_tests",
        return_value=True,
    )
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_reads_selection_args_from_environment_when_option_is_omitted(
        self,
        run_mock: mock.Mock,
        result_bundle_mock: mock.Mock,
    ) -> None:
        """Read environment selections without depending on local derived-data contents."""
        with mock.patch(
            "run_xcodebuild_with_test_selection.discover_single_xctestrun_path",
            return_value=None,
        ), mock.patch.dict(
            os.environ,
            {
                "TEST_SELECTION_ARGS": (
                    "-only-testing:AndBibleTests/AndBibleTests/testOne\n"
                    "-only-testing:AndBibleTests/AndBibleTests/testTwo\n"
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
        result_bundle_mock.assert_called_once_with(
            ".artifacts/AndBibleTests-ui.xcresult",
            [
                "AndBibleTests/AndBibleTests/testOne",
                "AndBibleTests/AndBibleTests/testTwo",
            ],
        )
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
                "-only-testing:AndBibleTests/AndBibleTests/testOne",
                "-only-testing:AndBibleTests/AndBibleTests/testTwo",
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

    @mock.patch(
        "run_xcodebuild_with_test_selection.result_bundle_reports_passing_tests",
        return_value=True,
    )
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_patches_discovered_xctestrun_for_project_mode_ui_tests(
        self,
        run_mock: mock.Mock,
        result_bundle_mock: mock.Mock,
    ) -> None:
        """Pass selected Xcode into the XCTest runner, not only the xcodebuild wrapper."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = pathlib.Path(temporary_directory)
            products_path = temporary_path / "Build" / "Products"
            products_path.mkdir(parents=True)
            application_path = write_ui_test_application_product(products_path)
            xctestrun_path = products_path / "AndBible_iphonesimulator.xctestrun"
            with xctestrun_path.open("wb") as plist_file:
                plistlib.dump(
                    {
                        "AndBibleUITests": {
                            "IsUITestBundle": True,
                            "UITargetAppPath": (
                                "__TESTROOT__/Debug-iphonesimulator/AndBible.app"
                            ),
                            "EnvironmentVariables": {},
                            "TestingEnvironmentVariables": {},
                        }
                    },
                    plist_file,
                )
            original_xctestrun_bytes = xctestrun_path.read_bytes()

            fixture_tool = temporary_path / "UITestFixtureTool"
            fixture_tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fixture_tool.chmod(0o755)
            fixture_manifest = temporary_path / "manifest.json"
            fixture_manifest.write_text(
                json.dumps({"AndBibleUITests/AndBibleUITests/testOne": "baseline"}),
                encoding="utf-8",
            )
            sword_fixture = temporary_path / "sword"
            (sword_fixture / "mods.d").mkdir(parents=True)
            (sword_fixture / "mods.d" / "kjv.conf").write_text("[KJV]\n", encoding="utf-8")

            invocation: dict[str, object] = {}

            def capture_xcodebuild(
                command: list[str],
                *,
                check: bool,
            ) -> subprocess.CompletedProcess[str]:
                invocation["command"] = command
                invocation["check"] = check
                temporary_xctestrun_path = pathlib.Path(command[2])
                invocation["temporary_path"] = temporary_xctestrun_path
                with temporary_xctestrun_path.open("rb") as plist_file:
                    invocation["xctestrun"] = plistlib.load(plist_file)
                return subprocess.CompletedProcess(command, 0)

            run_mock.side_effect = capture_xcodebuild

            with mock.patch.dict(
                os.environ,
                {
                    "MD_APPLE_SDK_ROOT": "/Applications/Xcode_26.3.app",
                    "UITEST_FIXTURE_TOOL_PATH": str(fixture_tool),
                    "UITEST_FIXTURE_MANIFEST_PATH": str(fixture_manifest),
                    "UITEST_SWORD_FIXTURE_PATH": str(sword_fixture),
                    "UITEST_SIMULATOR_ID": SIMULATOR_ID,
                    "UITEST_BUNDLE_ID": "org.andbible.ios",
                },
                clear=True,
            ), mock.patch(
                "run_xcodebuild_with_test_selection.install_simulator_application"
            ) as install_mock:
                exit_code = main(
                    [
                        "--project",
                        "AndBible.xcodeproj",
                        "--scheme",
                        "AndBible",
                        "--configuration",
                        "Debug",
                        "--destination",
                        f"platform=iOS Simulator,id={SIMULATOR_ID}",
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
            install_mock.assert_called_once_with(
                simulator_id=SIMULATOR_ID,
                application_path=application_path.resolve(),
            )
            result_bundle_mock.assert_called_once_with(
                ".artifacts/AndBibleTests-ui.xcresult",
                ["AndBibleUITests/AndBibleUITests/testOne"],
            )
            run_mock.assert_called_once()
            temporary_xctestrun_path = invocation["temporary_path"]
            self.assertIsInstance(temporary_xctestrun_path, pathlib.Path)
            assert isinstance(temporary_xctestrun_path, pathlib.Path)
            self.assertEqual(temporary_xctestrun_path.parent, products_path)
            self.assertTrue(
                temporary_xctestrun_path.name.startswith(
                    ".AndBible_iphonesimulator-ui-environment-"
                )
            )
            expected_command = [
                "xcodebuild",
                "-xctestrun",
                str(temporary_xctestrun_path),
                "-destination",
                f"platform=iOS Simulator,id={SIMULATOR_ID}",
                "-resultBundlePath",
                ".artifacts/AndBibleTests-ui.xcresult",
                "CODE_SIGNING_ALLOWED=NO",
                "-only-testing:AndBibleUITests/AndBibleUITests/testOne",
                "test-without-building",
            ]
            self.assertEqual(invocation["command"], expected_command)
            self.assertTrue(invocation["check"])
            xctestrun = invocation["xctestrun"]
            assert isinstance(xctestrun, dict)
            service_directory = xctestrun["AndBibleUITests"]["EnvironmentVariables"][
                "UITEST_FIXTURE_SERVICE_DIRECTORY"
            ]
            self.assertEqual(
                xctestrun["AndBibleUITests"]["TestingEnvironmentVariables"][
                    "UITEST_FIXTURE_SERVICE_DIRECTORY"
                ],
                service_directory,
            )
            self.assertFalse(pathlib.Path(service_directory).exists())
            self.assertFalse(temporary_xctestrun_path.exists())
            self.assertEqual(xctestrun_path.read_bytes(), original_xctestrun_bytes)

    @mock.patch(
        "run_xcodebuild_with_test_selection.result_bundle_reports_passing_tests",
        return_value=True,
    )
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_accepts_xctestrun_path_for_test_without_building(
        self,
        run_mock: mock.Mock,
        result_bundle_mock: mock.Mock,
    ) -> None:
        """Protect CI's restored-product path while preserving selection parsing and SIGSEGV handling."""
        with mock.patch(
            "run_xcodebuild_with_test_selection.selected_ui_test_developer_dir",
            return_value="/Applications/TestXcode.app/Contents/Developer",
        ), mock.patch(
            "run_xcodebuild_with_test_selection.ui_test_fixture_service_session",
            return_value=contextlib.nullcontext(),
        ), mock.patch(
            "run_xcodebuild_with_test_selection.os.path.exists",
            return_value=True,
        ), mock.patch(
            "run_xcodebuild_with_test_selection.temporary_patched_xctestrun_ui_test_environment",
            return_value=contextlib.nullcontext(
                ".derivedData/Build/Products/AndBible_iphonesimulator.xctestrun"
            ),
        ), mock.patch(
            "run_xcodebuild_with_test_selection.resolve_ui_test_application_product",
            return_value=UITestApplicationProduct(
                path=pathlib.Path("/products/AndBible.app"),
                bundle_identifier="org.andbible.ios",
            ),
        ):
            exit_code = main(
                [
                    "--xctestrun-path",
                    ".derivedData/Build/Products/AndBible_iphonesimulator.xctestrun",
                    "--destination",
                    "id=DEVICE",
                    "--result-bundle-path",
                    ".artifacts/AndBibleTests-ui-reuse.xcresult",
                    "--test-selection-args=-only-testing:AndBibleUITests/AndBibleUITests/testSettingsApplicationShortcutsOpenGlobalTextOptions",
                    "--action",
                    "test-without-building",
                ]
            )

        self.assertEqual(exit_code, 0)
        result_bundle_mock.assert_called_once_with(
            ".artifacts/AndBibleTests-ui-reuse.xcresult",
            [
                "AndBibleUITests/AndBibleUITests/"
                "testSettingsApplicationShortcutsOpenGlobalTextOptions"
            ],
        )
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
                "-only-testing:AndBibleUITests/AndBibleUITests/testSettingsApplicationShortcutsOpenGlobalTextOptions",
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

    @mock.patch(
        "run_xcodebuild_with_test_selection.result_bundle_reports_passing_tests",
        return_value=True,
    )
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_treats_sigsegv_after_passing_result_bundle_as_success(
        self,
        run_mock: mock.Mock,
        result_bundle_mock: mock.Mock,
    ) -> None:
        run_mock.side_effect = subprocess.CalledProcessError(
            returncode=-signal.SIGSEGV,
            cmd=["xcodebuild", "test-without-building"],
        )

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
                "--test-selection-args=-only-testing:AndBibleTests/AndBibleTests/testOne",
                "--action",
                "test-without-building",
            ]
        )

        self.assertEqual(exit_code, 0)
        result_bundle_mock.assert_called_once_with(
            ".artifacts/AndBibleTests-ui.xcresult",
            ["AndBibleTests/AndBibleTests/testOne"],
        )

    @mock.patch(
        "run_xcodebuild_with_test_selection.result_bundle_reports_passing_tests",
        return_value=False,
    )
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_reraises_sigsegv_when_result_bundle_reports_failures(
        self,
        run_mock: mock.Mock,
        result_bundle_mock: mock.Mock,
    ) -> None:
        run_mock.side_effect = subprocess.CalledProcessError(
            returncode=-signal.SIGSEGV,
            cmd=["xcodebuild", "test-without-building"],
        )

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
                    "--test-selection-args=-only-testing:AndBibleTests/AndBibleTests/testOne",
                    "--action",
                    "test-without-building",
                ]
            )
        result_bundle_mock.assert_called_once()

    @mock.patch("run_xcodebuild_with_test_selection.result_bundle_reports_passing_tests")
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_reraises_original_sigsegv_when_result_bundle_is_unreadable(
        self,
        run_mock: mock.Mock,
        result_bundle_mock: mock.Mock,
    ) -> None:
        xcodebuild_error = subprocess.CalledProcessError(
            returncode=-signal.SIGSEGV,
            cmd=["xcodebuild", "test-without-building"],
        )
        run_mock.side_effect = xcodebuild_error
        result_bundle_mock.side_effect = subprocess.CalledProcessError(
            returncode=1,
            cmd=["xcrun", "xcresulttool"],
        )

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
                    "--test-selection-args=-only-testing:AndBibleTests/AndBibleTests/testOne",
                    "--action",
                    "test-without-building",
                ]
            )

        self.assertIs(raised.exception, xcodebuild_error)


class ResultBundleSummaryTests(unittest.TestCase):
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_result_bundle_requires_every_selected_test_to_pass(
        self,
        run_mock: mock.Mock,
    ) -> None:
        run_mock.side_effect = [
            subprocess.CompletedProcess(
                args=["xcrun", "xcresulttool"],
                returncode=0,
                stdout=json.dumps(
                    {
                        "result": "Passed",
                        "totalTestCount": 2,
                        "passedTests": 2,
                        "failedTests": 0,
                        "skippedTests": 0,
                        "expectedFailures": 0,
                    }
                ),
                stderr="",
            ),
            subprocess.CompletedProcess(
                args=["xcrun", "xcresulttool"],
                returncode=0,
                stdout=json.dumps(
                    test_report_payload(("testOne", "Passed"), ("testTwo", "Passed"))
                ),
                stderr="",
            ),
        ]

        self.assertTrue(
            result_bundle_reports_passing_tests(
                "result.xcresult",
                [
                    "AndBibleTests/AndBibleTests/testOne",
                    "AndBibleTests/AndBibleTests/testTwo",
                ],
            )
        )
        self.assertEqual(
            [call.args[0][4] for call in run_mock.call_args_list],
            ["summary", "tests"],
        )

    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_result_bundle_rejects_passed_summary_when_one_selected_test_is_missing(
        self,
        run_mock: mock.Mock,
    ) -> None:
        run_mock.side_effect = [
            subprocess.CompletedProcess(
                args=["xcrun", "xcresulttool"],
                returncode=0,
                stdout=json.dumps(
                    {
                        "result": "Passed",
                        "totalTestCount": 1,
                        "passedTests": 1,
                        "failedTests": 0,
                    }
                ),
                stderr="",
            ),
            subprocess.CompletedProcess(
                args=["xcrun", "xcresulttool"],
                returncode=0,
                stdout=json.dumps(test_report_payload(("testOne", "Passed"))),
                stderr="",
            ),
        ]

        self.assertFalse(
            result_bundle_reports_passing_tests(
                "result.xcresult",
                [
                    "AndBibleTests/AndBibleTests/testOne",
                    "AndBibleTests/AndBibleTests/testTwo",
                ],
            )
        )

    def test_test_results_from_xcresult_nodes_uses_documented_node_identifier_url(self) -> None:
        payload = {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "name": "testSelected()",
                    "nodeIdentifierURL": (
                        "test://com.apple.xcode/AndBible/AndBibleTests/"
                        "AndBibleTests/testSelected%28%29"
                    ),
                    "result": "Skipped",
                }
            ]
        }

        self.assertEqual(
            test_results_from_xcresult_nodes(payload),
            {
                "AndBibleTests/AndBibleTests/testSelected": ("Skipped",)
            },
        )

    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_result_bundle_rejects_duplicate_restarted_test_attempts(
        self,
        run_mock: mock.Mock,
    ) -> None:
        run_mock.side_effect = [
            subprocess.CompletedProcess(
                args=["xcrun", "xcresulttool"],
                returncode=0,
                stdout=json.dumps(
                    {
                        "result": "Passed",
                        "totalTestCount": 2,
                        "passedTests": 2,
                        "failedTests": 0,
                    }
                ),
                stderr="",
            ),
            subprocess.CompletedProcess(
                args=["xcrun", "xcresulttool"],
                returncode=0,
                stdout=json.dumps(
                    test_report_payload(("testSelected", "Passed"), ("testSelected", "Passed"))
                ),
                stderr="",
            ),
        ]

        self.assertFalse(
            result_bundle_reports_passing_tests(
                "result.xcresult",
                ["AndBibleTests/AndBibleTests/testSelected"],
            )
        )

    @mock.patch(
        "run_xcodebuild_with_test_selection.result_bundle_reports_passing_tests",
        return_value=False,
    )
    @mock.patch("run_xcodebuild_with_test_selection.subprocess.run")
    def test_main_fails_successful_xcodebuild_when_xcresult_selection_is_incomplete(
        self,
        run_mock: mock.Mock,
        result_bundle_mock: mock.Mock,
    ) -> None:
        with self.assertRaisesRegex(ResultBundleValidationError, "did not exactly match"):
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
                    ".artifacts/AndBibleTests-unit.xcresult",
                    "--test-selection-args=-only-testing:AndBibleTests/AndBibleTests/testOne",
                    "--action",
                    "test-without-building",
                ]
            )

        run_mock.assert_called_once()
        result_bundle_mock.assert_called_once()


class ExecutableWorkflowPathTests(unittest.TestCase):
    def test_cli_runs_command_and_reconciles_structured_xcresult_reports(self) -> None:
        """Exercise the same process boundary used by the workflow without a simulator."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = pathlib.Path(temporary_directory)
            fake_bin = temporary_path / "bin"
            fake_bin.mkdir()
            fake_xcodebuild = fake_bin / "xcodebuild"
            fake_xcodebuild.write_text("#!/bin/sh\nexit 0\n")
            fake_xcodebuild.chmod(0o755)

            summary = {
                "result": "Passed",
                "totalTestCount": 1,
                "passedTests": 1,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
            }
            tests = test_report_payload(("testSelected", "Passed"))
            fake_xcrun = fake_bin / "xcrun"
            fake_xcrun.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                f"summary = {json.dumps(summary)!r}\n"
                f"tests = {json.dumps(tests)!r}\n"
                "print(summary if 'summary' in sys.argv else tests)\n"
            )
            fake_xcrun.chmod(0o755)

            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(RUNNER_PATH),
                    "--project",
                    "AndBible.xcodeproj",
                    "--scheme",
                    "AndBibleUnitTests",
                    "--configuration",
                    "Debug",
                    "--destination",
                    "id=TEST-DEVICE",
                    "--derived-data-path",
                    str(temporary_path / "DerivedData"),
                    "--result-bundle-path",
                    str(temporary_path / "result.xcresult"),
                    "--test-selection-args=-only-testing:AndBibleTests/AndBibleTests/testSelected",
                    "--action",
                    "test-without-building",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("-only-testing:AndBibleTests/AndBibleTests/testSelected", completed.stdout)


if __name__ == "__main__":
    unittest.main()
