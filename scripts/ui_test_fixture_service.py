#!/usr/bin/env python3
"""Host-owned fixture service for iOS UI-test shards.

The XCTest runner publishes bounded JSON requests into a private directory. This
macOS process performs the corresponding CoreSimulator and fixture-tool work so
the simulator test process never spawns ``simctl`` or mutates an unconfirmed app
container.
"""

from __future__ import annotations

import base64
import io
import json
import os
import select
import signal
import socket
import subprocess
import tempfile
import threading
import time
import uuid
import zipfile
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer


class FixtureServiceError(RuntimeError):
    """Raised when a request cannot satisfy the host fixture contract."""


class FixtureServiceCancelled(FixtureServiceError):
    """Raised when wrapper teardown cancels active fixture work."""


@dataclass(frozen=True)
class CommandResult:
    """Bounded subprocess result captured through temporary files."""

    returncode: int
    stdout: str
    stderr: str


CommandRunner = Callable[[Sequence[str], float, threading.Event], CommandResult]

DOWNLOAD_FIXTURE_MODULE = "UITESTDLWARN"
DOWNLOAD_FIXTURE_HOST = "uitest-download.invalid"
DOWNLOAD_FIXTURE_PATH = f"/catalog/packages/{DOWNLOAD_FIXTURE_MODULE}.zip"


def download_fixture_module_configuration() -> str:
    """Return the catalog/package configuration shared by the deterministic install."""
    return (
        f"[{DOWNLOAD_FIXTURE_MODULE}]\n"
        "Description=UI Test Downloads Warning\n"
        "DataPath=./modules/texts/ztext/uitestdlwarn/\n"
        "ModDrv=zText\n"
        "Category=Biblical Texts\n"
        "Encoding=UTF-8\n"
        "CompressType=ZIP\n"
        "BlockType=BOOK\n"
        "Versification=KJV\n"
        "Lang=en\n"
        "Version=1.0\n"
    )


def build_download_fixture_package(
    sword_fixture_path: Path,
    cancellation: threading.Event | None = None,
    deadline: float | None = None,
) -> bytes:
    """Build one deterministic, valid SWORD ZIP from the checked-in KJV payload."""
    def check_boundary() -> None:
        if cancellation is not None and cancellation.is_set():
            raise FixtureServiceCancelled(
                "fixture service stopped during Downloads package construction"
            )
        if deadline is not None and time.monotonic() >= deadline:
            raise FixtureServiceError(
                "fixture request exceeded its total timeout during Downloads package construction"
            )

    check_boundary()
    source_directory = sword_fixture_path / "modules" / "texts" / "ztext" / "kjv"
    if not source_directory.is_dir():
        raise FixtureServiceError(
            f"UI-test SWORD fixture has no KJV payload directory: {source_directory}"
        )
    source_files = sorted(path for path in source_directory.iterdir() if path.is_file())
    if not source_files:
        raise FixtureServiceError(
            f"UI-test SWORD fixture has no KJV payload files: {source_directory}"
        )
    output = io.BytesIO()
    # zText payloads are already compressed. Storing them in the outer package avoids an
    # uninterruptible second compression pass in the fixture-service request boundary.
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        entries: list[tuple[str, bytes]] = [
            ("mods.d/uitestdlwarn.conf", download_fixture_module_configuration().encode("utf-8"))
        ]
        for source_file in source_files:
            check_boundary()
            entries.append(
                (
                    f"modules/texts/ztext/uitestdlwarn/{source_file.name}",
                    source_file.read_bytes(),
                )
            )
        for name, payload in entries:
            check_boundary()
            info = zipfile.ZipInfo(name, date_time=(2024, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = 0o644 << 16
            archive.writestr(info, payload)
    check_boundary()
    return output.getvalue()


class DownloadFixtureController:
    """Own one held transfer at a time and record its real transport outcome."""

    def __init__(self, package: bytes, stop_event: threading.Event) -> None:
        self.package = package
        self.stop_event = stop_event
        self.transfer_stop_event = threading.Event()
        self.condition = threading.Condition()
        self.attempt = 0
        self.state = "idle"
        self.bytes_sent = 0
        self.released_attempt: int | None = None

    def begin(self) -> int:
        with self.condition:
            if self.state in {"starting", "connected", "released"}:
                raise FixtureServiceError("download fixture already has an active transfer")
            self.attempt += 1
            self.state = "starting"
            self.bytes_sent = 0
            self.released_attempt = None
            self.condition.notify_all()
            return self.attempt

    def mark_connected(self, attempt: int, bytes_sent: int) -> None:
        """Publish connected only after a real package prefix reaches the socket."""
        with self.condition:
            if attempt == self.attempt and self.state == "starting":
                self.bytes_sent = bytes_sent
                self.state = "connected"
                self.condition.notify_all()

    def release(self) -> dict[str, object]:
        with self.condition:
            if self.state != "connected":
                raise FixtureServiceError(
                    f"download fixture cannot release while state is {self.state!r}"
                )
            self.released_attempt = self.attempt
            self.state = "released"
            self.condition.notify_all()
            return self.snapshot()

    def mark_cancelled(self, attempt: int) -> None:
        with self.condition:
            if attempt == self.attempt and self.state in {"starting", "connected", "released"}:
                self.state = "cancelled"
                self.condition.notify_all()

    def mark_completed(self, attempt: int) -> None:
        with self.condition:
            if attempt == self.attempt and self.released_attempt == attempt:
                self.bytes_sent = len(self.package)
                self.state = "completed"
                self.condition.notify_all()

    def wait_until_released_or_cancelled(self, connection: socket.socket, attempt: int) -> bool:
        """Return true on release; detect a cancelled HTTP client while held."""
        while not self.stop_event.is_set() and not self.transfer_stop_event.is_set():
            with self.condition:
                if self.released_attempt == attempt:
                    return True
                if attempt != self.attempt:
                    return False
                if self.state == "cancelled":
                    return False
            readable, _, _ = select.select([connection], [], [], 0.05)
            if readable:
                try:
                    if connection.recv(1, socket.MSG_PEEK) == b"":
                        self.mark_cancelled(attempt)
                        return False
                except (ConnectionError, OSError):
                    self.mark_cancelled(attempt)
                    return False
        self.mark_cancelled(attempt)
        return False

    def stop(self) -> None:
        """Release a held handler when its wrapper-owned server is shutting down."""
        self.transfer_stop_event.set()
        with self.condition:
            self.condition.notify_all()

    def snapshot(self) -> dict[str, object]:
        with self.condition:
            return {
                "downloadFixtureAttempt": self.attempt,
                "downloadFixtureState": self.state,
                "downloadFixtureBytesSent": self.bytes_sent,
                "downloadFixturePackageByteCount": len(self.package),
            }

    def wait_for_state(self, expected_state: str, timeout_seconds: float = 15) -> dict[str, object]:
        """Wait for one transport-owned state without client-side request polling."""
        deadline = time.monotonic() + timeout_seconds
        with self.condition:
            while self.state != expected_state:
                if self.stop_event.is_set() or self.transfer_stop_event.is_set():
                    raise FixtureServiceCancelled(
                        "fixture service stopped while waiting for Downloads transport state"
                    )
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise FixtureServiceError(
                        f"download fixture did not reach {expected_state!r}; current state is "
                        f"{self.state!r} on attempt {self.attempt}"
                    )
                self.condition.wait(timeout=min(0.1, remaining))
            return {
                "downloadFixtureAttempt": self.attempt,
                "downloadFixtureState": self.state,
                "downloadFixtureBytesSent": self.bytes_sent,
                "downloadFixturePackageByteCount": len(self.package),
            }


class DownloadFixtureHTTPServer:
    """Loopback package server whose transfer gate is controlled by fixture requests."""

    def __init__(self, controller: DownloadFixtureController) -> None:
        token = uuid.uuid4().hex
        controller_reference = controller

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                if self.path != f"/{token}{DOWNLOAD_FIXTURE_PATH}":
                    self.send_error(404)
                    return
                try:
                    attempt = controller_reference.begin()
                except FixtureServiceError:
                    self.send_error(409)
                    return
                package = controller_reference.package
                prefix_count = max(
                    1,
                    min(max(1, len(package) // 4), 256 * 1024, len(package) - 1),
                )
                try:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/zip")
                    self.send_header("Content-Length", str(len(package)))
                    self.end_headers()
                    self.wfile.write(package[:prefix_count])
                    self.wfile.flush()
                    controller_reference.mark_connected(attempt, prefix_count)
                    if not controller_reference.wait_until_released_or_cancelled(
                        self.connection, attempt
                    ):
                        return
                    self.wfile.write(package[prefix_count:])
                    self.wfile.flush()
                    controller_reference.mark_completed(attempt)
                except (BrokenPipeError, ConnectionError, OSError):
                    controller_reference.mark_cancelled(attempt)

            def log_message(self, _format: str, *_arguments: object) -> None:
                return

        class ReadyThreadingHTTPServer(ThreadingHTTPServer):
            """Bind without DNS and signal once the request loop is active."""

            def __init__(self, *arguments: object, **keyword_arguments: object) -> None:
                self.ready_event = threading.Event()
                super().__init__(*arguments, **keyword_arguments)

            def server_bind(self) -> None:
                # HTTPServer resolves its own numeric bind address through getfqdn(),
                # which can block on host DNS despite this server accepting only loopback.
                TCPServer.server_bind(self)
                self.server_name = str(self.server_address[0])
                self.server_port = int(self.server_address[1])

            def service_actions(self) -> None:
                self.ready_event.set()
                super().service_actions()

        self.server = ReadyThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.controller = controller
        self.server.daemon_threads = False
        port = self.server.server_address[1]
        self.endpoint = f"http://127.0.0.1:{port}/{token}"
        self._lifecycle_lock = threading.Lock()
        self._started = False
        self._stopped = False
        self.thread = threading.Thread(
            target=lambda: self.server.serve_forever(poll_interval=0.05),
            name="AndBibleUITestDownloadFixtureServer",
            daemon=False,
        )

    def start(self) -> None:
        """Start the server and return only after its shutdown handshake is live."""
        with self._lifecycle_lock:
            if self._stopped:
                raise FixtureServiceCancelled(
                    "download fixture server was stopped before it could start"
                )
            if self._started:
                return
            self.thread.start()
            self._started = True
            if not self.server.ready_event.wait(timeout=5):
                self.controller.stop()
                self.server.shutdown()
                self.server.server_close()
                self.thread.join(timeout=5)
                self._stopped = True
                raise FixtureServiceError(
                    "download fixture server did not enter its request loop within 5 seconds"
                )

    def stop(self) -> None:
        """Stop the server exactly once after any concurrent start settles."""
        with self._lifecycle_lock:
            if self._stopped:
                return
            self._stopped = True
            self.controller.stop()
            if self._started:
                self.server.shutdown()
            self.server.server_close()
            if self._started:
                self.thread.join(timeout=5)
                if self.thread.is_alive():
                    raise FixtureServiceError(
                        "download fixture server did not stop within 5 seconds"
                    )


def run_command(
    command: Sequence[str],
    timeout_seconds: float,
    cancellation: threading.Event,
) -> CommandResult:
    """Run one command without pipe EOF dependence and cancel it on teardown."""
    if timeout_seconds <= 0:
        raise FixtureServiceError("fixture request exhausted its command deadline")
    with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
        process = subprocess.Popen(
            list(command),
            stdin=subprocess.DEVNULL,
            stdout=stdout_file,
            stderr=stderr_file,
            text=False,
            close_fds=True,
            start_new_session=True,
        )
        deadline = time.monotonic() + timeout_seconds
        try:
            while process.poll() is None:
                if cancellation.wait(timeout=min(0.05, max(0.0, deadline - time.monotonic()))):
                    raise FixtureServiceCancelled("fixture service stopped during active command")
                if time.monotonic() >= deadline:
                    raise FixtureServiceError(
                        f"fixture host command timed out after {timeout_seconds:.1f}s"
                    )
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=1)
            raise
        stdout_file.seek(0)
        stderr_file.seek(0)
        return CommandResult(
            returncode=process.returncode,
            stdout=stdout_file.read().decode("utf-8", errors="replace"),
            stderr=stderr_file.read().decode("utf-8", errors="replace"),
        )


def install_simulator_application(
    *,
    simulator_id: str,
    application_path: Path,
    timeout_seconds: float = 60,
    command_runner: CommandRunner = run_command,
) -> None:
    """Install the wrapper-validated UI target without launching it.

    A fresh simulator does not have the target application's data container
    until the application is installed. XCTest may defer that installation
    until ``XCUIApplication.launch()``, which is too late for fixture seeding.
    """
    cancellation = threading.Event()
    result = command_runner(
        ("xcrun", "simctl", "install", simulator_id, str(application_path)),
        timeout_seconds,
        cancellation,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or result.stdout.strip() or "no diagnostic output"
        raise FixtureServiceError(
            "cannot install the verified UI target application "
            f"on simulator {simulator_id}: exit {result.returncode}: {diagnostic}"
        )


@dataclass(frozen=True)
class FixtureServiceConfiguration:
    """Fixed wrapper-owned inputs that requests are forbidden to override."""

    directory: Path
    simulator_id: str
    bundle_identifier: str
    fixture_tool_path: Path
    fixture_manifest_path: Path
    sword_fixture_path: Path
    additional_allowed_scenarios: frozenset[str] = frozenset()
    request_timeout_seconds: float = 80

    def validated_scenarios(self) -> frozenset[str]:
        """Validate host paths and return manifest-declared fixture scenarios."""
        try:
            parsed_simulator_id = uuid.UUID(self.simulator_id)
        except ValueError as error:
            raise FixtureServiceError(
                f"invalid UI-test simulator UUID: {self.simulator_id!r}"
            ) from error
        if str(parsed_simulator_id).lower() != self.simulator_id.lower():
            raise FixtureServiceError("UI-test simulator ID must be a canonical UUID")
        if not self.bundle_identifier or any(character.isspace() for character in self.bundle_identifier):
            raise FixtureServiceError("UI-test bundle identifier is missing or invalid")
        if not self.fixture_tool_path.is_file() or not os.access(self.fixture_tool_path, os.X_OK):
            raise FixtureServiceError(
                f"UI-test fixture tool is not executable: {self.fixture_tool_path}"
            )
        if not self.fixture_manifest_path.is_file():
            raise FixtureServiceError(
                f"UI-test fixture manifest is not readable: {self.fixture_manifest_path}"
            )
        required_sword_config = self.sword_fixture_path / "mods.d" / "kjv.conf"
        if not required_sword_config.is_file():
            raise FixtureServiceError(
                f"UI-test SWORD fixture is incomplete: {self.sword_fixture_path}"
            )
        try:
            manifest = json.loads(self.fixture_manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise FixtureServiceError(f"cannot read UI-test fixture manifest: {error}") from error
        if not isinstance(manifest, dict) or not all(
            isinstance(key, str) and isinstance(value, str)
            for key, value in manifest.items()
        ):
            raise FixtureServiceError("UI-test fixture manifest must map test IDs to scenarios")
        supported_additional_scenarios = {
            "performance-bookmarks-10",
            "performance-bookmarks-1000",
            "performance-bookmarks-10000",
        }
        unsupported_additional_scenarios = (
            self.additional_allowed_scenarios - supported_additional_scenarios
        )
        if unsupported_additional_scenarios:
            raise FixtureServiceError(
                "unsupported configured fixture scenarios: "
                + ", ".join(sorted(unsupported_additional_scenarios))
            )
        scenarios = (frozenset(manifest.values()) - {"none"}) | self.additional_allowed_scenarios
        if not scenarios:
            raise FixtureServiceError("UI-test fixture manifest declares no host scenarios")
        return scenarios


@dataclass(frozen=True)
class FixtureRequest:
    """One validated simulator-to-host request."""

    request_id: str
    operation: str
    scenario: str | None


class UITestFixtureService:
    """Sequential request-file service scoped to one wrapper invocation."""

    def __init__(
        self,
        configuration: FixtureServiceConfiguration,
        *,
        command_runner: CommandRunner = run_command,
        poll_interval_seconds: float = 0.02,
    ) -> None:
        self.configuration = configuration
        self.command_runner = command_runner
        self.poll_interval_seconds = poll_interval_seconds
        self.allowed_scenarios = configuration.validated_scenarios()
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._processed_names: set[str] = set()
        self.download_fixture: DownloadFixtureController | None = None
        self.download_server: DownloadFixtureHTTPServer | None = None
        self._download_server_lock = threading.Lock()
        self._prepared_scenario: str | None = None

    def start(self) -> None:
        """Create the private request directory and start one sequential worker."""
        self.configuration.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
        os.chmod(self.configuration.directory, 0o700)
        self._thread = threading.Thread(
            target=self._serve,
            name="AndBibleUITestFixtureService",
            daemon=False,
        )
        self._thread.start()

    def stop(self) -> None:
        """Cancel active work and wait for the worker before the wrapper removes its directory."""
        self._stop_event.set()
        self._stop_download_server()
        if self._thread is not None:
            self._thread.join(timeout=5)
            if self._thread.is_alive():
                raise FixtureServiceError("fixture service did not stop within 5 seconds")
            self._thread = None
        self._stop_download_server()

    def _take_download_server(self) -> DownloadFixtureHTTPServer | None:
        """Atomically remove the currently published download transport, if any."""
        with self._download_server_lock:
            server = self.download_server
            self.download_server = None
            self.download_fixture = None
            return server

    def _stop_download_server(self) -> None:
        """Stop an owned server without holding the publication lock while joining it."""
        server = self._take_download_server()
        if server is not None:
            server.stop()

    def _publish_download_server(
        self,
        fixture: DownloadFixtureController,
        server: DownloadFixtureHTTPServer,
    ) -> bool:
        """Publish a fully started server only while the fixture service remains active."""
        with self._download_server_lock:
            if self._stop_event.is_set():
                return False
            self.download_fixture = fixture
            self.download_server = server
            return True

    def __enter__(self) -> UITestFixtureService:
        self.start()
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.stop()

    def _serve(self) -> None:
        while not self._stop_event.is_set():
            request_paths = sorted(self.configuration.directory.glob("*.request.json"))
            handled = False
            for request_path in request_paths:
                if request_path.name in self._processed_names:
                    continue
                self._processed_names.add(request_path.name)
                handled = True
                self._handle_request_file(request_path)
                if self._stop_event.is_set():
                    break
            if not handled:
                self._stop_event.wait(self.poll_interval_seconds)

    def _handle_request_file(self, request_path: Path) -> None:
        request_id = request_path.name.removesuffix(".request.json")
        try:
            parsed_request_id = uuid.UUID(request_id)
            if str(parsed_request_id).casefold() != request_id.casefold():
                raise ValueError("noncanonical UUID")
        except ValueError:
            diagnostic_id = str(uuid.uuid4()).upper()
            self._write_response(
                diagnostic_id,
                {
                    "requestID": diagnostic_id,
                    "succeeded": False,
                    "error": "rejected fixture request with a noncanonical UUID filename",
                },
            )
            return
        response: dict[str, object] = {"requestID": request_id, "succeeded": False}
        try:
            request = self._read_request(request_path, request_id)
            response = self._perform(request)
        except Exception as error:  # request failures are reported to the waiting XCTest client
            response["error"] = str(error)
        self._write_response(request_id, response)

    def _read_request(self, request_path: Path, file_request_id: str) -> FixtureRequest:
        try:
            payload = json.loads(request_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise FixtureServiceError(f"malformed fixture request JSON: {error}") from error
        if not isinstance(payload, dict):
            raise FixtureServiceError("fixture request must be a JSON object")
        allowed_keys = {
            "requestID",
            "operation",
            "scenario",
            "simulatorID",
            "bundleIdentifier",
        }
        unknown_keys = sorted(set(payload) - allowed_keys)
        if unknown_keys:
            raise FixtureServiceError(
                "fixture request contains unsupported keys: " + ", ".join(unknown_keys)
            )
        request_id = payload.get("requestID")
        if request_id != file_request_id:
            raise FixtureServiceError("fixture request ID does not match its filename")
        operation = payload.get("operation")
        download_operations = {
            "releaseDownload",
            "awaitDownloadConnected",
            "awaitDownloadCancelled",
            "awaitDownloadCompleted",
        }
        if operation != "prepare" and operation not in download_operations:
            raise FixtureServiceError(
                "fixture operation is not supported"
            )
        request_simulator_id = payload.get("simulatorID")
        try:
            parsed_request_simulator_id = uuid.UUID(request_simulator_id)
        except (AttributeError, TypeError, ValueError) as error:
            raise FixtureServiceError("fixture request simulator is not a UUID") from error
        if str(parsed_request_simulator_id).casefold() != str(request_simulator_id).casefold():
            raise FixtureServiceError("fixture request simulator UUID is not canonical")
        if request_simulator_id.casefold() != self.configuration.simulator_id.casefold():
            raise FixtureServiceError("fixture request simulator does not match wrapper destination")
        if payload.get("bundleIdentifier") != self.configuration.bundle_identifier:
            raise FixtureServiceError("fixture request bundle identifier is not authorized")
        scenario = payload.get("scenario")
        if operation == "prepare":
            if not isinstance(scenario, str) or scenario not in self.allowed_scenarios:
                raise FixtureServiceError(f"fixture scenario is not declared: {scenario!r}")
        elif scenario is not None:
            raise FixtureServiceError(f"fixture operation {operation!r} does not accept a scenario")
        return FixtureRequest(
            request_id=file_request_id,
            operation=operation,
            scenario=scenario if isinstance(scenario, str) else None,
        )

    def _perform(self, request: FixtureRequest) -> dict[str, object]:
        if request.operation != "prepare":
            if self._prepared_scenario != "downloads-row-order":
                raise FixtureServiceError(
                    "download fixture control requires the downloads-row-order preparation"
                )
            with self._download_server_lock:
                download_fixture = self.download_fixture
            if download_fixture is None:
                raise FixtureServiceError("download fixture transport is unavailable")
            if request.operation == "releaseDownload":
                snapshot = download_fixture.release()
            else:
                expected_state = {
                    "awaitDownloadConnected": "connected",
                    "awaitDownloadCancelled": "cancelled",
                    "awaitDownloadCompleted": "completed",
                }[request.operation]
                snapshot = download_fixture.wait_for_state(expected_state)
            return {"requestID": request.request_id, "succeeded": True, **snapshot}

        deadline = time.monotonic() + self.configuration.request_timeout_seconds
        self._prepared_scenario = None
        self._stop_download_server()
        self._terminate_app(deadline)
        data_container_path = self._data_container(deadline)
        fixture_tool_prefix = [
            "/usr/bin/env",
            f"CFFIXED_USER_HOME={data_container_path}",
            str(self.configuration.fixture_tool_path),
        ]
        self._require_success(
            "fixture reset",
            fixture_tool_prefix + [
                "reset",
                "--data-container",
                str(data_container_path),
                "--bundle-id",
                self.configuration.bundle_identifier,
            ],
            deadline,
            30,
        )
        seed = self._require_success(
            "fixture seed",
            fixture_tool_prefix + [
                "seed",
                "--data-container",
                str(data_container_path),
                "--scenario",
                request.scenario or "",
                "--bundle-id",
                self.configuration.bundle_identifier,
                "--sword-fixture-path",
                str(self.configuration.sword_fixture_path),
            ],
            deadline,
            60,
        )
        encoded_preferences = next(
            (line.strip() for line in reversed(seed.stdout.splitlines()) if line.strip()),
            "",
        )
        try:
            base64.b64decode(encoded_preferences, validate=True)
        except ValueError as error:
            raise FixtureServiceError(
                "fixture seed did not emit valid base64 preferences on its final line"
            ) from error
        if not encoded_preferences:
            raise FixtureServiceError("fixture seed emitted no preference payload")
        response: dict[str, object] = {
            "requestID": request.request_id,
            "succeeded": True,
            "encodedPreferences": encoded_preferences,
            "dataContainerPath": str(data_container_path),
        }
        if request.scenario == "downloads-row-order":
            package = build_download_fixture_package(
                self.configuration.sword_fixture_path,
                cancellation=self._stop_event,
                deadline=deadline,
            )
            if self._stop_event.is_set():
                raise FixtureServiceCancelled(
                    "fixture service stopped during Downloads transport preparation"
                )
            download_fixture = DownloadFixtureController(package, self._stop_event)
            download_server = DownloadFixtureHTTPServer(download_fixture)
            download_server.start()
            if not self._publish_download_server(download_fixture, download_server):
                download_server.stop()
                raise FixtureServiceCancelled(
                    "fixture service stopped before Downloads transport publication"
                )
            response["downloadFixtureEndpoint"] = download_server.endpoint
        self._prepared_scenario = request.scenario
        return response

    def _terminate_app(self, deadline: float) -> None:
        result = self._run(
            [
                "/usr/bin/xcrun",
                "simctl",
                "terminate",
                self.configuration.simulator_id,
                self.configuration.bundle_identifier,
            ],
            deadline,
            15,
        )
        diagnostic = f"{result.stdout}\n{result.stderr}".lower()
        if result.returncode != 0 and not any(
            marker in diagnostic
            for marker in ("found nothing to terminate", "no such process")
        ):
            raise FixtureServiceError(
                self._command_failure("simulator app termination", result)
            )

    def _data_container(self, deadline: float) -> Path:
        result = self._require_success(
            "installed app data-container lookup",
            [
                "/usr/bin/xcrun",
                "simctl",
                "get_app_container",
                self.configuration.simulator_id,
                self.configuration.bundle_identifier,
                "data",
            ],
            deadline,
            20,
        )
        output_lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if len(output_lines) != 1:
            raise FixtureServiceError(
                "installed app data-container lookup did not return exactly one path"
            )
        container = Path(output_lines[0])
        if not container.is_absolute() or not container.is_dir():
            raise FixtureServiceError(
                f"installed app data-container path is unavailable: {container}"
            )
        return container

    def _require_success(
        self,
        label: str,
        command: Sequence[str],
        deadline: float,
        maximum_seconds: float,
    ) -> CommandResult:
        result = self._run(command, deadline, maximum_seconds)
        if result.returncode != 0:
            raise FixtureServiceError(self._command_failure(label, result))
        return result

    def _run(
        self,
        command: Sequence[str],
        deadline: float,
        maximum_seconds: float,
    ) -> CommandResult:
        if self._stop_event.is_set():
            raise FixtureServiceCancelled("fixture service stopped before command execution")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise FixtureServiceError("fixture request exceeded its total timeout")
        return self.command_runner(command, min(maximum_seconds, remaining), self._stop_event)

    @staticmethod
    def _command_failure(label: str, result: CommandResult) -> str:
        stdout = result.stdout.strip() or "<empty>"
        stderr = result.stderr.strip() or "<empty>"
        return (
            f"{label} failed with exit {result.returncode}; "
            f"stdout: {stdout}; stderr: {stderr}"
        )

    def _write_response(self, request_id: str, response: Mapping[str, object]) -> None:
        final_path = self.configuration.directory / f"{request_id}.response.json"
        temporary_path = self.configuration.directory / f".{request_id}.response.tmp"
        temporary_path.write_text(
            json.dumps(dict(response), sort_keys=True, separators=(",", ":")),
            encoding="utf-8",
        )
        os.replace(temporary_path, final_path)
