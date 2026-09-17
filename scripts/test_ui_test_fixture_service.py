"""Behavioral tests for the host-owned iOS UI fixture service."""

from __future__ import annotations

import base64
import io
import json
import os
import pathlib
import signal
import socket
import subprocess
import threading
import sys
import tempfile
import time
import unittest
import uuid
import urllib.request
import zipfile
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from ui_test_fixture_service import (
    CommandResult,
    FixtureHostCommandTimeout,
    FixtureServiceConfiguration,
    FixtureServiceError,
    UITestFixtureService,
    DOWNLOAD_FIXTURE_PATH,
    DownloadFixtureController,
    DownloadFixtureHTTPServer,
    build_download_fixture_package,
    install_simulator_application,
    run_command,
)


SIMULATOR_ID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
BUNDLE_ID = "org.andbible.ios"


class RecordingRunner:
    """Deterministic command runner with per-command result overrides."""

    def __init__(self, container: pathlib.Path) -> None:
        self.container = container
        self.commands: list[list[str]] = []
        self.results: dict[str, CommandResult | Exception | list[CommandResult | Exception]] = {}

    def __call__(self, command, _timeout, _cancellation) -> CommandResult:
        command = list(command)
        self.commands.append(command)
        operation = self._operation(command)
        overridden = self.results.get(operation)
        if isinstance(overridden, list):
            overridden = overridden.pop(0)
        if isinstance(overridden, Exception):
            raise overridden
        if overridden is not None:
            return overridden
        if operation == "get_app_container":
            return CommandResult(0, f"{self.container}\n", "")
        if operation == "seed":
            encoded = base64.b64encode(b'{"theme":"night"}').decode("ascii")
            return CommandResult(0, f"seeded fixture\n{encoded}\n", "")
        return CommandResult(0, "", "")

    @staticmethod
    def _operation(command: list[str]) -> str:
        if "terminate" in command:
            return "terminate"
        if "launch" in command:
            return "launch"
        if "get_app_container" in command:
            return "get_app_container"
        if "reset" in command:
            return "reset"
        if "seed" in command:
            return "seed"
        return "unknown"


class FixtureServiceTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary_directory.name)
        self.container = self.root / "data-container"
        self.container.mkdir()
        self.fixture_tool = self.root / "UITestFixtureTool"
        self.fixture_tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.fixture_tool.chmod(0o755)
        self.manifest = self.root / "ui_test_fixture_manifest.json"
        self.manifest.write_text(
            json.dumps(
                {
                    "AndBibleUITests/AndBibleUITests/testOne": "baseline",
                    "AndBibleUITests/AndBibleUITests/testDownloads": "downloads-row-order",
                }
            ),
            encoding="utf-8",
        )
        self.sword_fixture = self.root / "sword"
        (self.sword_fixture / "mods.d").mkdir(parents=True)
        (self.sword_fixture / "mods.d" / "kjv.conf").write_text(
            "[KJV]\n",
            encoding="utf-8",
        )
        fixture_payload = self.sword_fixture / "modules" / "texts" / "ztext" / "kjv"
        fixture_payload.mkdir(parents=True)
        (fixture_payload / "ot.bzs").write_bytes(b"deterministic SWORD fixture payload")
        self.service_directory = self.root / "service"
        self.runner = RecordingRunner(self.container)
        self.configuration = FixtureServiceConfiguration(
            directory=self.service_directory,
            simulator_id=SIMULATOR_ID,
            bundle_identifier=BUNDLE_ID,
            fixture_tool_path=self.fixture_tool,
            fixture_manifest_path=self.manifest,
            sword_fixture_path=self.sword_fixture,
            request_timeout_seconds=2,
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_install_simulator_application_uses_bounded_host_simctl(self) -> None:
        application_path = self.root / "Products" / "AndBible.app"

        install_simulator_application(
            simulator_id=SIMULATOR_ID,
            application_path=application_path,
            timeout_seconds=17,
            command_runner=self.runner,
        )

        self.assertEqual(
            self.runner.commands,
            [["xcrun", "simctl", "install", SIMULATOR_ID, str(application_path)]],
        )

    def test_install_simulator_application_reports_exact_host_failure(self) -> None:
        application_path = self.root / "Products" / "AndBible.app"
        diagnostic_path = self.root / "artifacts" / "ui.fixture-host-diagnostic.json"
        self.runner.results["unknown"] = CommandResult(
            13,
            "",
            "CoreSimulator rejected app architecture",
        )

        with self.assertRaisesRegex(
            FixtureServiceError,
            "exit 13: CoreSimulator rejected app architecture",
        ):
            install_simulator_application(
                simulator_id=SIMULATOR_ID,
                application_path=application_path,
                bundle_identifier=BUNDLE_ID,
                diagnostic_path=diagnostic_path,
                command_runner=self.runner,
            )
        self.assertFalse(diagnostic_path.exists())
        self.assertEqual(
            self.runner.commands,
            [["xcrun", "simctl", "install", SIMULATOR_ID, str(application_path)]],
        )

    def test_command_timeout_reaps_process_and_retains_partial_output(self) -> None:
        with self.assertRaises(FixtureHostCommandTimeout) as captured:
            run_command(
                (
                    sys.executable,
                    "-c",
                    "import sys,time; sys.stdout.write('x' * 40000 + 'TAIL-SENTINEL\\n'); "
                    "sys.stdout.flush(); "
                    "print('partial-error', file=sys.stderr, flush=True); time.sleep(10)",
                ),
                0.5,
                threading.Event(),
            )

        error = captured.exception
        self.assertGreaterEqual(error.elapsed_seconds, 0.5)
        self.assertEqual(error.termination_signals_attempted, ("SIGTERM",))
        self.assertEqual(error.returncode, -signal.SIGTERM)
        self.assertTrue(error.direct_child_reaped)
        self.assertTrue(error.process_group_gone)
        self.assertIsNone(error.cleanup_error)
        self.assertTrue(error.stdout_truncated)
        self.assertEqual(error.stdout_original_byte_count, 40_014)
        self.assertLessEqual(len(error.stdout.encode("utf-8")), 32_768)
        self.assertTrue(error.stdout.endswith("TAIL-SENTINEL\n"))
        self.assertIsNone(error.stdout_capture_error)
        self.assertIn("partial-error", error.stderr)
        with self.assertRaises(ProcessLookupError):
            os.kill(error.pid, 0)

    def test_command_timeout_retains_unreaped_parent_as_diagnostic_state(self) -> None:
        process = mock.Mock(pid=5151, returncode=None)
        process.poll.return_value = None
        process.wait.side_effect = subprocess.TimeoutExpired(["fixture"], 1)

        with mock.patch(
            "ui_test_fixture_service.subprocess.Popen",
            return_value=process,
        ), mock.patch("ui_test_fixture_service.os.killpg") as kill_mock, mock.patch(
            "ui_test_fixture_service._read_bounded_temporary_output",
            side_effect=[OSError("stdout unavailable"), ("stderr", False, 6)],
        ):
            kill_mock.side_effect = lambda _pid, signal_number: (
                None if signal_number != 0 else None
            )
            with self.assertRaises(FixtureHostCommandTimeout) as captured:
                run_command(("fixture",), 0.01, threading.Event())

        error = captured.exception
        self.assertEqual(error.termination_signals_attempted, ("SIGTERM", "SIGKILL"))
        self.assertFalse(error.direct_child_reaped)
        self.assertFalse(error.process_group_gone)
        self.assertIsNone(error.returncode)
        self.assertIn("timed out", error.cleanup_error or "")
        self.assertIn("stdout capture failed: stdout unavailable", error.cleanup_error or "")
        self.assertEqual(error.stdout, "")
        self.assertIsNone(error.stdout_truncated)
        self.assertIsNone(error.stdout_original_byte_count)
        self.assertEqual(error.stdout_capture_error, "stdout capture failed: stdout unavailable")
        self.assertEqual(error.stderr, "stderr")
        self.assertEqual(kill_mock.call_args_list[0], mock.call(5151, signal.SIGTERM))
        self.assertIn(mock.call(5151, signal.SIGKILL), kill_mock.call_args_list)

    def test_install_timeout_writes_exact_bounded_diagnostic_without_retry(self) -> None:
        application_path = self.root / "Products" / "AndBible.app"
        diagnostic_path = self.root / "artifacts" / "ui.fixture-host-diagnostic.json"
        commands: list[list[str]] = []

        def timeout_then_diagnose(command, timeout, _cancellation) -> CommandResult:
            command = list(command)
            commands.append(command)
            if "install" in command:
                raise FixtureHostCommandTimeout(
                    command=command,
                    timeout_seconds=timeout,
                    pid=4242,
                    elapsed_seconds=60.25,
                    returncode=None,
                    termination_signals_attempted=("SIGTERM", "SIGKILL"),
                    direct_child_reaped=False,
                    process_group_gone=False,
                    cleanup_error="Command did not exit after SIGKILL",
                    stdout="start\n" + ("x" * 40_000),
                    stderr="CoreSimulator stalled\n",
                )
            if "listapps" in command:
                raise FixtureServiceError("listapps unavailable")
            return CommandResult(0, f"{SIMULATOR_ID} (Booted)\n", "")

        with self.assertRaisesRegex(
            FixtureServiceError,
            "verified UI target installation timed out after 60.0s",
        ):
            install_simulator_application(
                simulator_id=SIMULATOR_ID,
                application_path=application_path,
                bundle_identifier=BUNDLE_ID,
                diagnostic_path=diagnostic_path,
                command_runner=timeout_then_diagnose,
            )

        payload = json.loads(diagnostic_path.read_text(encoding="utf-8"))
        self.assertEqual(payload["phase"], "ui-target-install")
        self.assertEqual(payload["simulatorID"], SIMULATOR_ID)
        self.assertEqual(payload["bundleIdentifier"], BUNDLE_ID)
        self.assertEqual(payload["applicationPath"], str(application_path))
        self.assertEqual(payload["pid"], 4242)
        self.assertEqual(payload["terminationSignalsAttempted"], ["SIGTERM", "SIGKILL"])
        self.assertFalse(payload["directChildReaped"])
        self.assertFalse(payload["processGroupGone"])
        self.assertEqual(
            payload["cleanupError"]["text"],
            "Command did not exit after SIGKILL",
        )
        self.assertTrue(payload["stdout"]["truncated"])
        self.assertEqual(payload["stdout"]["originalByteCount"], 40_006)
        self.assertEqual(payload["stderr"]["text"], "CoreSimulator stalled\n")
        self.assertEqual(
            payload["postTimeoutProbes"][1]["error"]["text"],
            "listapps unavailable",
        )
        self.assertEqual(
            commands,
            [
                ["xcrun", "simctl", "install", SIMULATOR_ID, str(application_path)],
                ["xcrun", "simctl", "list", "devices", "available"],
                ["xcrun", "simctl", "listapps", SIMULATOR_ID],
            ],
        )

    def test_install_timeout_remains_primary_when_diagnostic_write_fails(self) -> None:
        def timed_out(command, timeout, _cancellation) -> CommandResult:
            raise FixtureHostCommandTimeout(
                command=command,
                timeout_seconds=timeout,
                pid=4343,
                elapsed_seconds=60,
                returncode=-signal.SIGTERM,
                termination_signals_attempted=("SIGTERM",),
                direct_child_reaped=True,
                process_group_gone=True,
                cleanup_error=None,
                stdout="",
                stderr="",
            )

        with mock.patch(
            "ui_test_fixture_service.write_install_timeout_diagnostic",
            side_effect=OSError("artifact volume unavailable"),
        ), self.assertRaises(FixtureServiceError) as captured:
            install_simulator_application(
                simulator_id=SIMULATOR_ID,
                application_path=self.root / "AndBible.app",
                bundle_identifier=BUNDLE_ID,
                diagnostic_path=self.root / "diagnostic.json",
                command_runner=timed_out,
            )

        self.assertIn("installation timed out after 60.0s", str(captured.exception))
        self.assertIn("diagnostic capture failed", str(captured.exception))
        self.assertIsInstance(captured.exception.__cause__, FixtureHostCommandTimeout)

    def publish_request(self, payload: dict[str, object]) -> dict[str, object]:
        request_id = str(payload["requestID"])
        temporary = self.service_directory / f".{request_id}.request.tmp"
        request = self.service_directory / f"{request_id}.request.json"
        temporary.write_text(json.dumps(payload), encoding="utf-8")
        os.replace(temporary, request)
        response = self.service_directory / f"{request_id}.response.json"
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if response.exists():
                return json.loads(response.read_text(encoding="utf-8"))
            time.sleep(0.01)
        self.fail(f"fixture service did not publish {response.name}")

    def request(
        self,
        *,
        operation: str = "prepare",
        scenario: str | None = "baseline",
        simulator_id: str = SIMULATOR_ID,
        bundle_identifier: str = BUNDLE_ID,
        request_id: str | None = None,
    ) -> dict[str, object]:
        request_id = request_id or str(uuid4())
        payload: dict[str, object] = {
            "requestID": request_id,
            "operation": operation,
            "simulatorID": simulator_id,
            "bundleIdentifier": bundle_identifier,
        }
        if scenario is not None:
            payload["scenario"] = scenario
        return self.publish_request(payload)

    def test_service_lifecycle_creates_private_directory_and_stops_worker(self) -> None:
        service = UITestFixtureService(self.configuration, command_runner=self.runner)
        with service:
            self.assertEqual(self.service_directory.stat().st_mode & 0o777, 0o700)
            self.assertTrue(service._thread and service._thread.is_alive())
        self.assertIsNone(service._thread)

    def test_service_context_stops_worker_when_test_body_fails(self) -> None:
        """A failed lifecycle assertion cannot leak the non-daemon worker into shutdown."""
        service = UITestFixtureService(self.configuration, command_runner=self.runner)

        with self.assertRaisesRegex(AssertionError, "synthetic lifecycle failure"):
            with service:
                self.assertTrue(service._thread and service._thread.is_alive())
                worker = service._thread
                raise AssertionError("synthetic lifecycle failure")

        self.assertIsNone(service._thread)
        self.assertIsNotNone(worker)
        self.assertFalse(worker.is_alive())

    def test_stop_owns_server_that_finishes_starting_after_teardown_begins(self) -> None:
        """A late request worker cannot publish or leak a server after ``stop``."""
        original_start = DownloadFixtureHTTPServer.start
        server_started = threading.Event()
        allow_start_to_return = threading.Event()

        def delayed_start(server: DownloadFixtureHTTPServer) -> None:
            original_start(server)
            server_started.set()
            if not allow_start_to_return.wait(timeout=2):
                raise AssertionError("test did not release delayed server start")

        service = UITestFixtureService(self.configuration, command_runner=self.runner)
        stop_errors: list[Exception] = []
        stop_thread: threading.Thread | None = None
        stop_completed_within_timeout = False

        def stop_service() -> None:
            try:
                service.stop()
            except Exception as error:  # pragma: no cover - asserted below
                stop_errors.append(error)

        with mock.patch.object(DownloadFixtureHTTPServer, "start", delayed_start):
            with service:
                try:
                    request_id = str(uuid4()).upper()
                    payload = {
                        "requestID": request_id,
                        "operation": "prepare",
                        "scenario": "downloads-row-order",
                        "simulatorID": SIMULATOR_ID,
                        "bundleIdentifier": BUNDLE_ID,
                    }
                    temporary = self.service_directory / f".{request_id}.request.tmp"
                    request = self.service_directory / f"{request_id}.request.json"
                    temporary.write_text(json.dumps(payload), encoding="utf-8")
                    os.replace(temporary, request)
                    self.assertTrue(server_started.wait(timeout=2))

                    stop_thread = threading.Thread(target=stop_service)
                    stop_thread.start()
                    self.assertTrue(service._stop_event.wait(timeout=1))
                    allow_start_to_return.set()
                    stop_thread.join(timeout=2)
                    stop_completed_within_timeout = not stop_thread.is_alive()
                finally:
                    allow_start_to_return.set()
                    if stop_thread is not None and stop_thread.ident is not None:
                        stop_thread.join()

        self.assertIsNotNone(stop_thread)
        self.assertTrue(stop_completed_within_timeout)
        self.assertFalse(stop_thread.is_alive())
        self.assertEqual(stop_errors, [])
        self.assertIsNone(service._thread)
        self.assertIsNone(service.download_server)
        self.assertIsNone(service.download_fixture)
        self.assertEqual(
            [
                thread.name
                for thread in threading.enumerate()
                if thread.name == "AndBibleUITestDownloadFixtureServer"
            ],
            [],
        )

    def test_stop_cancels_worker_waiting_for_download_transport_state(self) -> None:
        """A control request cannot keep the service worker alive during teardown."""
        service = UITestFixtureService(self.configuration, command_runner=self.runner)
        service.start()
        try:
            prepared = self.request(scenario="downloads-row-order")
            self.assertTrue(prepared["succeeded"])
            request_id = str(uuid4()).upper()
            payload = {
                "requestID": request_id,
                "operation": "awaitDownloadConnected",
                "simulatorID": SIMULATOR_ID,
                "bundleIdentifier": BUNDLE_ID,
            }
            temporary = self.service_directory / f".{request_id}.request.tmp"
            request = self.service_directory / f"{request_id}.request.json"
            temporary.write_text(json.dumps(payload), encoding="utf-8")
            os.replace(temporary, request)
            deadline = time.monotonic() + 2
            while request.name not in service._processed_names and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertIn(request.name, service._processed_names)

            service.stop()

            response = json.loads(
                (self.service_directory / f"{request_id}.response.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertFalse(response["succeeded"])
            self.assertEqual(
                response["error"],
                "fixture service stopped while waiting for Downloads transport state",
            )
            self.assertIsNone(service._thread)
        finally:
            service.stop()

    def test_valid_prepare_runs_stop_lookup_reset_seed_and_returns_preferences(self) -> None:
        request_id = str(uuid4()).upper()
        with UITestFixtureService(self.configuration, command_runner=self.runner):
            response = self.request(
                request_id=request_id,
                simulator_id=SIMULATOR_ID.lower(),
            )

        self.assertTrue(response["succeeded"])
        self.assertEqual(response["requestID"], request_id)
        self.assertEqual(response["dataContainerPath"], str(self.container))
        self.assertEqual(
            base64.b64decode(str(response["encodedPreferences"])),
            b'{"theme":"night"}',
        )
        self.assertEqual(
            [RecordingRunner._operation(command) for command in self.runner.commands],
            ["terminate", "get_app_container", "reset", "seed"],
        )
        for fixture_command in self.runner.commands[-2:]:
            self.assertEqual(fixture_command[:2], [
                "/usr/bin/env",
                f"CFFIXED_USER_HOME={self.container}",
            ])
            self.assertEqual(fixture_command[2], str(self.fixture_tool))
        seed_command = self.runner.commands[-1]
        self.assertEqual(seed_command[seed_command.index("--scenario") + 1], "baseline")
        self.assertEqual(
            seed_command[seed_command.index("--sword-fixture-path") + 1],
            str(self.sword_fixture),
        )

    def test_download_fixture_package_is_deterministic_and_owns_expected_paths(self) -> None:
        first = build_download_fixture_package(self.sword_fixture)
        second = build_download_fixture_package(self.sword_fixture)

        self.assertEqual(first, second)
        with zipfile.ZipFile(io.BytesIO(first)) as archive:
            self.assertEqual(
                archive.namelist(),
                [
                    "mods.d/uitestdlwarn.conf",
                    "modules/texts/ztext/uitestdlwarn/ot.bzs",
                ],
            )
            configuration = archive.read("mods.d/uitestdlwarn.conf").decode("utf-8")
            self.assertIn("[UITESTDLWARN]", configuration)
            self.assertIn("DataPath=./modules/texts/ztext/uitestdlwarn/", configuration)
            self.assertTrue(
                all(entry.compress_type == zipfile.ZIP_STORED for entry in archive.infolist())
            )

    def test_download_fixture_release_serves_real_package_and_reports_completion(self) -> None:
        received: dict[str, object] = {}
        with UITestFixtureService(self.configuration, command_runner=self.runner) as service:
            prepared = self.request(scenario="downloads-row-order")
            expected_package = service.download_fixture.package
            self.assertTrue(prepared["succeeded"])
            self.assertEqual(
                prepared["downloadFixtureEndpoint"], service.download_server.endpoint
            )

            def download() -> None:
                try:
                    with urllib.request.urlopen(
                        service.download_server.endpoint + DOWNLOAD_FIXTURE_PATH,
                        timeout=5,
                    ) as response:
                        received["data"] = response.read()
                except Exception as error:  # pragma: no cover - asserted below
                    received["error"] = error

            thread = threading.Thread(target=download)
            thread.start()
            connected = self.request(operation="awaitDownloadConnected", scenario=None)
            self.assertEqual(connected["downloadFixtureAttempt"], 1)
            self.assertGreater(connected["downloadFixtureBytesSent"], 0)
            self.assertLess(
                connected["downloadFixtureBytesSent"],
                connected["downloadFixturePackageByteCount"],
            )
            released = self.request(operation="releaseDownload", scenario=None)
            self.assertEqual(released["downloadFixtureState"], "released")
            completed = self.request(operation="awaitDownloadCompleted", scenario=None)
            thread.join(timeout=5)

        self.assertFalse(thread.is_alive())
        self.assertNotIn("error", received)
        self.assertEqual(received["data"], expected_package)
        self.assertEqual(completed["downloadFixtureState"], "completed")
        self.assertEqual(
            completed["downloadFixtureBytesSent"],
            completed["downloadFixturePackageByteCount"],
        )

    def test_download_fixture_detects_cancelled_client_before_release(self) -> None:
        stop_event = threading.Event()
        controller = DownloadFixtureController(b"package", stop_event)
        server_socket, client_socket = socket.socketpair()
        try:
            attempt = controller.begin()
            controller.mark_connected(attempt, 3)
            client_socket.close()
            self.assertFalse(
                controller.wait_until_released_or_cancelled(server_socket, attempt)
            )
            self.assertEqual(
                controller.snapshot(),
                {
                    "downloadFixtureAttempt": 1,
                    "downloadFixtureState": "cancelled",
                    "downloadFixtureBytesSent": 3,
                    "downloadFixturePackageByteCount": 7,
                },
            )
        finally:
            server_socket.close()

    def test_download_fixture_http_transfer_reports_partial_bytes_then_client_cancellation(self) -> None:
        with UITestFixtureService(self.configuration, command_runner=self.runner) as service:
            prepared = self.request(scenario="downloads-row-order")
            response = urllib.request.urlopen(
                prepared["downloadFixtureEndpoint"] + DOWNLOAD_FIXTURE_PATH,
                timeout=5,
            )
            self.assertTrue(response.read(1))
            connected = self.request(operation="awaitDownloadConnected", scenario=None)
            self.assertGreater(connected["downloadFixtureBytesSent"], 0)
            self.assertLess(
                connected["downloadFixtureBytesSent"],
                connected["downloadFixturePackageByteCount"],
            )
            response.close()
            cancelled = self.request(operation="awaitDownloadCancelled", scenario=None)

        self.assertEqual(cancelled["downloadFixtureAttempt"], 1)
        self.assertEqual(cancelled["downloadFixtureState"], "cancelled")
        self.assertEqual(
            cancelled["downloadFixtureBytesSent"],
            connected["downloadFixtureBytesSent"],
        )

    def test_wrong_target_and_malformed_request_never_run_commands(self) -> None:
        with UITestFixtureService(self.configuration, command_runner=self.runner):
            wrong_target = self.request(simulator_id=str(uuid4()))
            malformed_id = str(uuid4())
            malformed = self.publish_request(
                {
                    "requestID": malformed_id,
                    "operation": "prepare",
                    "scenario": "baseline",
                    "simulatorID": SIMULATOR_ID,
                    "bundleIdentifier": BUNDLE_ID,
                    "command": "/bin/rm",
                }
            )

        self.assertFalse(wrong_target["succeeded"])
        self.assertIn("does not match wrapper destination", wrong_target["error"])
        self.assertFalse(malformed["succeeded"])
        self.assertIn("unsupported keys: command", malformed["error"])
        self.assertEqual(self.runner.commands, [])

    def test_download_control_is_bounded_to_prepared_download_scenario(self) -> None:
        with UITestFixtureService(self.configuration, command_runner=self.runner):
            before_prepare = self.request(operation="awaitDownloadConnected", scenario=None)
            scenario_override = self.request(
                operation="releaseDownload", scenario="downloads-row-order"
            )
            unsupported = self.request(operation="runCommand", scenario=None)

        self.assertFalse(before_prepare["succeeded"])
        self.assertIn("requires the downloads-row-order preparation", before_prepare["error"])
        self.assertFalse(scenario_override["succeeded"])
        self.assertIn("does not accept a scenario", scenario_override["error"])
        self.assertFalse(unsupported["succeeded"])
        self.assertIn("operation is not supported", unsupported["error"])
        self.assertEqual(self.runner.commands, [])

    def test_noncanonical_request_filename_uses_safe_diagnostic_identity(self) -> None:
        with UITestFixtureService(self.configuration, command_runner=self.runner):
            bad_request = self.service_directory / "not-a-uuid.request.json"
            bad_request.write_text("{}", encoding="utf-8")
            deadline = time.monotonic() + 2
            response_paths: list[pathlib.Path] = []
            while time.monotonic() < deadline:
                response_paths = list(self.service_directory.glob("*.response.json"))
                if response_paths:
                    break
                time.sleep(0.01)

        self.assertEqual(len(response_paths), 1)
        response = json.loads(response_paths[0].read_text(encoding="utf-8"))
        self.assertEqual(response_paths[0].name, f"{response['requestID']}.response.json")
        self.assertIsNotNone(uuid.UUID(response["requestID"]))
        self.assertFalse(response["succeeded"])
        self.assertEqual(
            response["error"],
            "rejected fixture request with a noncanonical UUID filename",
        )
        self.assertEqual(self.runner.commands, [])

    def test_reset_failure_reports_exact_output_and_does_not_seed(self) -> None:
        self.runner.results["reset"] = CommandResult(
            7,
            "reset stdout",
            "reset stderr",
        )
        with UITestFixtureService(self.configuration, command_runner=self.runner):
            response = self.request()

        self.assertFalse(response["succeeded"])
        self.assertEqual(
            response["error"],
            "fixture reset failed with exit 7; stdout: reset stdout; stderr: reset stderr",
        )
        self.assertEqual(
            [RecordingRunner._operation(command) for command in self.runner.commands],
            ["terminate", "get_app_container", "reset"],
        )

    def test_confirmed_absent_process_allows_prepare_but_other_stop_failure_blocks_it(self) -> None:
        self.runner.results["terminate"] = CommandResult(
            3,
            "",
            "found nothing to terminate",
        )
        with UITestFixtureService(self.configuration, command_runner=self.runner):
            response = self.request()
        self.assertTrue(response["succeeded"])

        self.runner.commands.clear()
        self.runner.results["terminate"] = CommandResult(4, "", "CoreSimulator unavailable")
        service_directory = self.root / "failed-stop-service"
        configuration = FixtureServiceConfiguration(
            directory=service_directory,
            simulator_id=SIMULATOR_ID,
            bundle_identifier=BUNDLE_ID,
            fixture_tool_path=self.fixture_tool,
            fixture_manifest_path=self.manifest,
            sword_fixture_path=self.sword_fixture,
            request_timeout_seconds=2,
        )
        original_service_directory = self.service_directory
        self.service_directory = service_directory
        try:
            with UITestFixtureService(configuration, command_runner=self.runner):
                failed = self.request()
        finally:
            self.service_directory = original_service_directory

        self.assertFalse(failed["succeeded"])
        self.assertEqual(
            failed["error"],
            "simulator app termination failed with exit 4; "
            "stdout: <empty>; stderr: CoreSimulator unavailable",
        )
        self.assertEqual(
            [RecordingRunner._operation(command) for command in self.runner.commands],
            ["terminate"],
        )

    def test_missing_container_bootstraps_then_stops_app_before_fixture_mutation(self) -> None:
        """A first-run container is created by one launch and stopped before reset and seed."""
        self.runner.results["get_app_container"] = [
            CommandResult(2, "", "container unavailable"),
            CommandResult(0, f"{self.container}\n", ""),
        ]
        with UITestFixtureService(self.configuration, command_runner=self.runner):
            response = self.request()

        self.assertTrue(response["succeeded"])
        self.assertEqual(
            [RecordingRunner._operation(command) for command in self.runner.commands],
            ["terminate", "get_app_container", "launch", "terminate", "get_app_container", "reset", "seed"],
        )

    def test_failed_bootstrap_stop_prevents_container_lookup_and_mutation(self) -> None:
        """A launched bootstrap process must reach the stop boundary before any fixture write."""
        self.runner.results["get_app_container"] = CommandResult(
            2, "", "container unavailable"
        )
        self.runner.results["terminate"] = [
            CommandResult(3, "", "found nothing to terminate"),
            CommandResult(4, "", "CoreSimulator unavailable"),
        ]
        with UITestFixtureService(self.configuration, command_runner=self.runner):
            response = self.request()

        self.assertFalse(response["succeeded"])
        self.assertIn("simulator app termination failed", response["error"])
        self.assertEqual(
            [RecordingRunner._operation(command) for command in self.runner.commands],
            ["terminate", "get_app_container", "launch", "terminate"],
        )

    def test_bootstrap_requires_a_real_container_before_fixture_mutation(self) -> None:
        """A successful launch cannot substitute an invalid or unavailable container path."""
        missing = self.root / "not-created"
        self.runner.results["get_app_container"] = [
            CommandResult(2, "", "container unavailable"),
            CommandResult(0, f"{missing}\n", ""),
        ]
        with UITestFixtureService(self.configuration, command_runner=self.runner):
            response = self.request()

        self.assertFalse(response["succeeded"])
        self.assertIn("did not return one available absolute path", response["error"])
        self.assertEqual(
            [RecordingRunner._operation(command) for command in self.runner.commands],
            ["terminate", "get_app_container", "launch", "terminate", "get_app_container"],
        )

    def test_command_timeout_is_returned_without_later_mutation(self) -> None:
        self.runner.results["get_app_container"] = FixtureServiceError(
            "fixture host command timed out after 0.1s"
        )
        with UITestFixtureService(self.configuration, command_runner=self.runner):
            response = self.request()

        self.assertFalse(response["succeeded"])
        self.assertEqual(response["error"], "fixture host command timed out after 0.1s")
        self.assertEqual(
            [RecordingRunner._operation(command) for command in self.runner.commands],
            ["terminate", "get_app_container"],
        )

    def test_configured_performance_scale_is_allowed_without_opening_request_values(self) -> None:
        configuration = FixtureServiceConfiguration(
            directory=self.service_directory,
            simulator_id=SIMULATOR_ID,
            bundle_identifier=BUNDLE_ID,
            fixture_tool_path=self.fixture_tool,
            fixture_manifest_path=self.manifest,
            sword_fixture_path=self.sword_fixture,
            additional_allowed_scenarios=frozenset({"performance-bookmarks-1000"}),
            request_timeout_seconds=2,
        )
        with UITestFixtureService(configuration, command_runner=self.runner):
            response = self.request(scenario="performance-bookmarks-1000")

        self.assertTrue(response["succeeded"])

    def test_arbitrary_additional_scenario_is_rejected_before_service_start(self) -> None:
        configuration = FixtureServiceConfiguration(
            directory=self.service_directory,
            simulator_id=SIMULATOR_ID,
            bundle_identifier=BUNDLE_ID,
            fixture_tool_path=self.fixture_tool,
            fixture_manifest_path=self.manifest,
            sword_fixture_path=self.sword_fixture,
            additional_allowed_scenarios=frozenset({"../../other"}),
        )

        with self.assertRaisesRegex(
            FixtureServiceError,
            "unsupported configured fixture scenarios: \\.\\./\\.\\./other",
        ):
            UITestFixtureService(configuration, command_runner=self.runner)
        self.assertFalse(self.service_directory.exists())


class BoundedCommandTestCase(unittest.TestCase):
    def test_direct_child_completion_does_not_wait_for_descendant_file_descriptors(self) -> None:
        started = time.monotonic()
        result = run_command(
            ["/bin/sh", "-c", "sleep 2 & printf direct-output"],
            1,
            threading.Event(),
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "direct-output")
        self.assertLess(time.monotonic() - started, 0.75)

    def test_timeout_terminates_descendants_before_they_can_mutate_later(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            marker = pathlib.Path(temporary_directory) / "late-mutation"
            with self.assertRaisesRegex(
                FixtureServiceError,
                "fixture host command timed out after 0.1s",
            ):
                run_command(
                    [
                        "/bin/sh",
                        "-c",
                        f"(sleep 0.4; touch {marker}) & wait",
                    ],
                    0.1,
                    threading.Event(),
                )
            time.sleep(0.5)
            self.assertFalse(marker.exists())


def uuid4() -> str:
    """Return one canonical request UUID without exposing mutable test state."""
    import uuid

    return str(uuid.uuid4())


if __name__ == "__main__":
    unittest.main()
