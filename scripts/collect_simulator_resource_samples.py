#!/usr/bin/env python3
"""Collect UI-test resources and bounded simulator pre-exec stall stacks.

The collector preserves the existing ten-second resource log. Diagnostics are
taken only after the same direct ``launchd_sim`` child remains ``xpcproxy_sim``
in two snapshots at least five seconds apart. One boot control, one WebKit user
sample, and one WebKit kernel-aware spindump are bounded and fail-soft. Shutdown
may signal only diagnostic children started by this collector.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Mapping, Sequence


PROCESS_ROW_PATTERN = re.compile(
    r"^\s*(?P<pid>\d+)\s+(?P<ppid>\d+)\s+"
    r"(?P<weekday>\S+)\s+(?P<month>\S+)\s+(?P<day>\d+)\s+"
    r"(?P<clock>\d{2}:\d{2}:\d{2})\s+(?P<year>\d{4})\s+"
    r"(?P<state>\S+)\s+(?P<wchan>\S+)\s+(?P<command>.+?)\s*$"
)
PROCESS_ARGUMENT_ROW_PATTERN = re.compile(r"^\s*(?P<pid>\d+)\s+(?P<arguments>.*?)\s*$")
WEBKIT_SERVICE_LABEL_PATTERN = re.compile(
    r"^com\.apple\.WebKit\."
    r"(?:WebContent(?:\.EnhancedSecurity)?|GPU|Networking)"
    r"(?:\.[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})?$"
)
INITIAL_RESOURCE_COMMANDS = (
    ("sysctl", "-n", "hw.memsize"),
    ("sysctl", "-n", "hw.ncpu"),
)
RESOURCE_COMMANDS = (
    ("sysctl", "-n", "vm.loadavg"),
    ("sysctl", "vm.swapusage"),
    ("vm_stat",),
    ("ps", "-axo", "pid=,ppid=,%cpu=,rss=,comm="),
)
PROVENANCE_ENVIRONMENT_KEYS = (
    "GITHUB_JOB",
    "GITHUB_RUN_ATTEMPT",
    "GITHUB_RUN_ID",
    "ImageOS",
    "ImageVersion",
    "RUNNER_ARCH",
    "RUNNER_NAME",
    "RUNNER_OS",
    "UITEST_SIMULATOR_NAME",
    "UITEST_SIMULATOR_OS_VERSION",
    "XCODE_VERSION",
)


@dataclass(frozen=True)
class ProcessSnapshot:
    """One read-only process observation; state and wait channel are not identity."""

    pid: int
    ppid: int
    started_at: str
    state: str
    wait_channel: str
    command: str

    def is_same_process(self, other: ProcessSnapshot | None) -> bool:
        """Compare stable identity without I/O; command changes expose an exec."""

        return other is not None and (
            self.pid,
            self.ppid,
            self.started_at,
            self.command,
        ) == (
            other.pid,
            other.ppid,
            other.started_at,
            other.command,
        )

    def as_dict(self) -> dict[str, object]:
        """Return stable identity plus scheduler state as JSON-safe metadata."""

        return {
            "pid": self.pid,
            "ppid": self.ppid,
            "started_at": self.started_at,
            "state": self.state,
            "wait_channel": self.wait_channel,
            "command": self.command,
        }


@dataclass
class ProcessObservation:
    """Continuous first/latest observations for one process incarnation."""

    first_seen_monotonic: float
    first_seen_at: str
    latest: ProcessSnapshot


@dataclass(frozen=True)
class StallCandidate:
    """A reserved capture target with its demonstrated stall interval."""

    process: ProcessSnapshot
    first_observed_monotonic: float
    first_observed_at: str
    qualified_at: str
    observed_elapsed_seconds: float


@dataclass(frozen=True)
class OwnedToolResult:
    """Terminal state of one bounded collector-owned diagnostic command."""

    returncode: int | None
    timed_out: bool
    launch_error: str | None
    cleanup_error: str | None
    launched: bool


def run_bounded_owned_tool(
    command: Sequence[str],
    *,
    tool_output_path: Path,
    timeout: float,
    process_started: Callable[[subprocess.Popen[str]], None] | None = None,
    process_finished: Callable[[subprocess.Popen[str]], None] | None = None,
) -> OwnedToolResult:
    """Launch, bound, and reap one exact tool command owned by the caller."""

    process: subprocess.Popen[str] | None = None
    returncode: int | None = None
    timed_out = False
    launch_error: str | None = None
    cleanup_error: str | None = None
    try:
        with tool_output_path.open("w", encoding="utf-8") as tool_output:
            process = subprocess.Popen(
                command,
                stdout=tool_output,
                stderr=subprocess.STDOUT,
                text=True,
            )
            if process_started is not None:
                process_started(process)
            try:
                returncode = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                process.terminate()
                try:
                    returncode = process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    try:
                        returncode = process.wait(timeout=0.5)
                    except subprocess.TimeoutExpired as error:
                        cleanup_error = repr(error)
    except OSError as error:
        launch_error = repr(error)
    finally:
        if process is not None and process_finished is not None:
            process_finished(process)
    return OwnedToolResult(returncode, timed_out, launch_error, cleanup_error, process is not None)


class XPCProxyStallDetector:
    """Reserve continuously observed xpcproxy PIDs for collector classification."""

    def __init__(self, *, minimum_stall_seconds: float = 5.0, capture_limit: int = 64) -> None:
        """Create detector state; invalid negative bounds raise ``ValueError``."""

        if minimum_stall_seconds < 0 or capture_limit < 0:
            raise ValueError("stall duration and capture limit must be non-negative")
        self.minimum_stall_seconds = minimum_stall_seconds
        self.capture_limit = capture_limit
        self._observations: dict[int, ProcessObservation] = {}
        self._reserved_pids: set[int] = set()

    def observe(
        self,
        snapshots: Sequence[ProcessSnapshot],
        *,
        manager_pid: int,
        observed_at_monotonic: float,
        observed_at: str,
    ) -> list[StallCandidate]:
        """Update lifetimes and return newly reserved same-parent candidates.

        Disappearance or PID reuse resets the interval. Returned PIDs stay
        reserved even if their one capture attempt fails. This mutates only
        single-threaded in-memory state.
        """

        eligible = {
            item.pid: item
            for item in snapshots
            if item.ppid == manager_pid
            and Path(item.command).name == "xpcproxy_sim"
            and item.pid not in self._reserved_pids
        }
        self._observations = {
            pid: observation
            for pid, observation in self._observations.items()
            if pid in eligible and observation.latest.is_same_process(eligible[pid])
        }
        candidates: list[StallCandidate] = []
        for pid in sorted(eligible):
            process = eligible[pid]
            observation = self._observations.get(pid)
            if observation is None:
                self._observations[pid] = ProcessObservation(
                    observed_at_monotonic,
                    observed_at,
                    process,
                )
                continue
            observation.latest = process
            elapsed = observed_at_monotonic - observation.first_seen_monotonic
            if elapsed < self.minimum_stall_seconds or len(self._reserved_pids) >= self.capture_limit:
                continue
            self._reserved_pids.add(pid)
            self._observations.pop(pid, None)
            candidates.append(
                StallCandidate(
                    process,
                    observation.first_seen_monotonic,
                    observation.first_seen_at,
                    observed_at,
                    elapsed,
                )
            )
        return candidates

    def release(self, candidate: StallCandidate) -> None:
        """Retry classification next cadence without discarding the proven continuous interval."""

        self._reserved_pids.discard(candidate.process.pid)
        self._observations[candidate.process.pid] = ProcessObservation(
            candidate.first_observed_monotonic,
            candidate.first_observed_at,
            candidate.process,
        )


def utc_timestamp() -> str:
    """Read the wall clock once and return a microsecond UTC ISO-8601 value."""

    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_process_snapshots(output: str) -> list[ProcessSnapshot]:
    """Parse identity/state ``ps`` rows, ignoring unrecognized lines fail-soft."""

    snapshots: list[ProcessSnapshot] = []
    for line in output.splitlines():
        match = PROCESS_ROW_PATTERN.match(line)
        if match is None:
            continue
        snapshots.append(
            ProcessSnapshot(
                pid=int(match.group("pid")),
                ppid=int(match.group("ppid")),
                started_at=" ".join(
                    match.group(key)
                    for key in ("weekday", "month", "day", "clock", "year")
                ),
                state=match.group("state"),
                wait_channel=match.group("wchan"),
                command=match.group("command"),
            )
        )
    return snapshots


def parse_process_arguments(output: str) -> dict[int, str]:
    """Parse exact PID-to-argv rows from one bounded host ``ps`` query."""

    arguments: dict[int, str] = {}
    for line in output.splitlines():
        match = PROCESS_ARGUMENT_ROW_PATTERN.match(line)
        if match is None:
            continue
        pid = int(match.group("pid"))
        if pid in arguments:
            continue
        arguments[pid] = match.group("arguments")
    return arguments


def webkit_service_label(arguments: str) -> str | None:
    """Return one exact recognized WebKit service-label token without retaining argv."""

    try:
        tokens = shlex.split(arguments)
    except ValueError:
        return None
    labels = [token for token in tokens if WEBKIT_SERVICE_LABEL_PATTERN.fullmatch(token)]
    return labels[0] if len(labels) == 1 else None


class SimulatorResourceCollector:
    """Own one fail-soft resource log and bounded targeted sampling session."""

    def __init__(
        self,
        *,
        simulator_id: str,
        resource_log_path: Path,
        diagnostics_directory: Path,
        interval_seconds: float = 10.0,
        monotonic: Callable[[], float] = time.monotonic,
        environment: Mapping[str, str] = os.environ,
    ) -> None:
        """Store selected simulator, artifacts, and timing; no I/O occurs yet."""

        if not simulator_id.strip() or interval_seconds <= 0:
            raise ValueError("simulator ID and a positive interval are required")
        self.simulator_id = simulator_id
        self.resource_log_path = resource_log_path
        self.diagnostics_directory = diagnostics_directory
        self.metadata_path = diagnostics_directory / "metadata.jsonl"
        self.interval_seconds = interval_seconds
        self.monotonic = monotonic
        self.environment = dict(environment)
        self.detector = XPCProxyStallDetector()
        self.stop_event = threading.Event()
        self.manager_snapshot: ProcessSnapshot | None = None
        self.initial_resource_sample = True
        self._owned_capture_process: subprocess.Popen[str] | None = None
        self._boot_capture_count = 0
        self._webkit_capture_count = 0
        self._kernel_capture_count = 0
        self._classification_deferred_count = 0
        self._unrecognized_service_label_count = 0

    def request_stop(self) -> None:
        """Set the stop flag and terminate only running collector-owned tool children."""

        self.stop_event.set()
        process = self._owned_capture_process
        if process is not None and process.poll() is None:
            try:
                process.terminate()
            except OSError:
                pass

    def run(self) -> None:
        """Collect until stopped; command and iteration errors remain diagnostic.

        Shutdown is checked between commands; one already-running read-only
        resource command may consume its bounded ten-second timeout.
        """

        self.diagnostics_directory.mkdir(parents=True, exist_ok=True)
        self.resource_log_path.parent.mkdir(parents=True, exist_ok=True)
        self._write_event(
            "provenance",
            schema_version=1,
            simulator_id=self.simulator_id,
            environment={
                key: self.environment[key]
                for key in PROVENANCE_ENVIRONMENT_KEYS
                if key in self.environment
            },
        )
        if not self.stop_event.is_set():
            self.manager_snapshot = self._resolve_manager_snapshot()
        try:
            while not self.stop_event.is_set():
                try:
                    self.collect_once()
                except Exception as error:  # Diagnostic collection must not fail xcodebuild.
                    self._write_event("collector_iteration_error", error=repr(error))
                self.stop_event.wait(self.interval_seconds)
        finally:
            self.request_stop()
            self._reap_owned_capture_process()
            self._write_event("collector_stopped")

    def collect_once(self) -> None:
        """Append one resource snapshot, then inspect and sample qualified children."""

        self._append_resource_snapshot()
        if self.stop_event.is_set():
            return
        snapshots = self._all_process_snapshots()
        manager = self.manager_snapshot
        if manager is None:
            self._write_event("stall_scan_skipped", reason="manager_identity_unavailable")
            return
        current_manager = next((item for item in snapshots if item.pid == manager.pid), None)
        if not manager.is_same_process(current_manager):
            self._write_event(
                "stall_scan_skipped",
                reason="manager_identity_changed",
                expected=manager.as_dict(),
                actual=current_manager.as_dict() if current_manager else None,
            )
            return
        children = [
            item
            for item in snapshots
            if item.ppid == manager.pid and Path(item.command).name == "xpcproxy_sim"
        ]
        observed_at = utc_timestamp()
        self._append_resource_line(
            "simulator_process_snapshot="
            + json.dumps(
                {
                    "observed_at": observed_at,
                    "manager": current_manager.as_dict(),
                    "xpcproxy_children": [item.as_dict() for item in children],
                },
                sort_keys=True,
            )
        )
        candidates = self.detector.observe(
            children,
            manager_pid=manager.pid,
            observed_at_monotonic=self.monotonic(),
            observed_at=observed_at,
        )
        self._capture_candidates(candidates, manager)

    def _capture_candidates(
        self,
        candidates: Sequence[StallCandidate],
        manager: ProcessSnapshot,
    ) -> None:
        """Classify owners for one boot sample and two distinct WebKit tools."""

        arguments_by_pid = self._process_arguments([item.process.pid for item in candidates])
        classified: list[tuple[StallCandidate, str | None]] = []
        for candidate in candidates:
            arguments = arguments_by_pid.get(candidate.process.pid)
            if arguments is None:
                self.detector.release(candidate)
                self._classification_deferred_count += 1
                self._write_event(
                    "stall_classification_deferred",
                    reason="arguments_unavailable",
                    deferred_count=self._classification_deferred_count,
                    child_identity=candidate.process.as_dict(),
                )
                continue
            service_label = webkit_service_label(arguments)
            if service_label is None:
                self._unrecognized_service_label_count += 1
                self._write_event(
                    "stall_service_label_unrecognized",
                    unrecognized_count=self._unrecognized_service_label_count,
                    child_identity=candidate.process.as_dict(),
                )
            classified.append((candidate, service_label))

        # WebKit launch stalls are the target observation. Capture them before the single generic
        # boot control so a slow control tool cannot consume the remaining pre-exec interval.
        classified.sort(key=lambda item: item[1] is None)
        for candidate, service_label in classified:
            if self.stop_event.is_set():
                break
            if service_label is not None:
                if self._webkit_capture_count >= 2:
                    self._write_event(
                        "stall_capture_skipped",
                        reason="webkit_capture_limit_reached",
                        service_label=service_label,
                        child_identity=candidate.process.as_dict(),
                    )
                    continue
                if self._kernel_capture_count == 0:
                    if self._capture_kernel_stall(candidate, manager, service_label):
                        self._kernel_capture_count += 1
                        self._webkit_capture_count += 1
                elif self._capture_stall(candidate, manager, service_label=service_label):
                    self._webkit_capture_count += 1
                continue
            if self._boot_capture_count >= 1:
                self._write_event(
                    "stall_capture_skipped",
                    reason="boot_control_already_captured",
                    child_identity=candidate.process.as_dict(),
                )
                continue
            if self._capture_stall(candidate, manager):
                self._boot_capture_count += 1

    def _run_command(
        self,
        command: Sequence[str],
        *,
        timeout: float = 10.0,
    ) -> subprocess.CompletedProcess[str]:
        """Run a read-only command; launch/timeouts become nonzero results."""

        try:
            return subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as error:
            return subprocess.CompletedProcess(command, 124, "", repr(error))

    def _append_resource_snapshot(self) -> None:
        """Append established host metrics, checking shutdown between commands."""

        self._append_resource_line(f"sample_time={utc_timestamp().split('.')[0]}Z")
        commands: Sequence[Sequence[str]] = RESOURCE_COMMANDS
        if self.initial_resource_sample:
            commands = (*INITIAL_RESOURCE_COMMANDS, *RESOURCE_COMMANDS)
            self.initial_resource_sample = False
        for command in commands:
            if self.stop_event.is_set():
                return
            result = self._run_command(command)
            self._append_resource_text(result.stdout)
            self._append_resource_text(result.stderr)
            if result.returncode != 0:
                self._append_resource_line(
                    f"resource_command_status={result.returncode} command={json.dumps(list(command))}"
                )

    def _append_resource_line(self, value: str) -> None:
        """Append one flushed line to the resource artifact."""

        self._append_resource_text(value.rstrip("\n") + "\n")

    def _append_resource_text(self, value: str) -> None:
        """Append raw UTF-8 text; an empty value performs no file write."""

        if not value:
            return
        with self.resource_log_path.open("a", encoding="utf-8") as handle:
            handle.write(value)
            handle.flush()

    def _all_process_snapshots(self) -> list[ProcessSnapshot]:
        """Read all process identity/state rows, recording failure as metadata."""

        result = self._run_command(
            ("ps", "-axo", "pid=,ppid=,lstart=,state=,wchan=,comm=")
        )
        if result.returncode != 0:
            self._write_event(
                "process_snapshot_error",
                returncode=result.returncode,
                stderr=result.stderr,
            )
            return []
        return parse_process_snapshots(result.stdout)

    def _process_snapshot(self, pid: int) -> ProcessSnapshot | None:
        """Read one exact PID, returning ``None`` on disappearance or error."""

        result = self._run_command(
            ("ps", "-p", str(pid), "-o", "pid=,ppid=,lstart=,state=,wchan=,comm=")
        )
        if result.returncode != 0:
            return None
        return next((item for item in parse_process_snapshots(result.stdout) if item.pid == pid), None)

    def _process_arguments(self, pids: Sequence[int]) -> dict[int, str]:
        """Read argv for exact candidate PIDs in one bounded host query, retaining no environment."""

        if not pids:
            return {}
        pid_list = ",".join(str(pid) for pid in sorted(set(pids)))
        result = self._run_command(("ps", "-ww", "-p", pid_list, "-o", "pid=,args="))
        if result.returncode != 0:
            self._write_event(
                "process_arguments_error",
                pids=sorted(set(pids)),
                returncode=result.returncode,
                stderr=result.stderr,
            )
            return {}
        return parse_process_arguments(result.stdout)

    def _resolve_manager_snapshot(self) -> ProcessSnapshot | None:
        """Resolve the exact host service without asking the guest to launch.

        Guest ``simctl spawn`` can block on the same pre-exec dependency this
        collector observes. The host's existing service registration supplies
        the PID; both its exact label and the live executable must agree before
        any child can qualify for capture. Lookup failure disables sampling.
        """

        if self.stop_event.is_set():
            return None
        service_label = f"com.apple.CoreSimulator.SimDevice.{self.simulator_id}"
        result = self._run_command(
            ("/bin/launchctl", "list", service_label)
        )
        labels = re.findall(r'^\s*"Label"\s*=\s*"([^"\r\n]*)";\s*$', result.stdout, re.MULTILINE)
        pids = re.findall(r'^\s*"PID"\s*=\s*([^;\r\n]*);\s*$', result.stdout, re.MULTILINE)
        if (
            result.returncode != 0
            or labels != [service_label]
            or len(pids) != 1
            or not pids[0].strip().isascii()
            or not pids[0].strip().isdigit()
            or int(pids[0].strip()) <= 0
        ):
            self._write_event(
                "manager_identity_error",
                service_label=service_label,
                returncode=result.returncode,
                labels=labels,
                pids=pids,
                stderr=result.stderr,
            )
            return None
        manager_pid = int(pids[0].strip())
        if self.stop_event.is_set():
            return None
        snapshot = self._process_snapshot(manager_pid)
        if snapshot is None or Path(snapshot.command).name != "launchd_sim":
            self._write_event(
                "manager_identity_error",
                manager_pid=manager_pid,
                reason="missing_or_not_launchd_sim",
                actual=snapshot.as_dict() if snapshot else None,
            )
            return None
        self._write_event("manager_identity", identity=snapshot.as_dict())
        return snapshot

    def _run_owned_capture_tool(
        self,
        command: Sequence[str],
        *,
        tool_output_path: Path,
        timeout: float,
    ) -> OwnedToolResult:
        """Run, bound, and reap one tool without ever signaling its observed target."""

        def process_finished(process: subprocess.Popen[str]) -> None:
            if process.poll() is not None:
                self._owned_capture_process = None
            else:
                self.stop_event.set()

        def process_started(process: subprocess.Popen[str]) -> None:
            self._owned_capture_process = process
            if self.stop_event.is_set() and process.poll() is None:
                process.terminate()

        return run_bounded_owned_tool(
            command,
            tool_output_path=tool_output_path,
            timeout=timeout,
            process_started=process_started,
            process_finished=process_finished,
        )

    def _capture_stall(
        self,
        candidate: StallCandidate,
        manager: ProcessSnapshot,
        *,
        service_label: str | None = None,
    ) -> bool:
        """Revalidate identities, then take one bounded targeted sample.

        The owned sample child is terminated after three seconds. The observed
        target is never signaled. A target exec during capture leaves the stack
        artifact available but marks it invalid in metadata.
        """

        expected_child = candidate.process
        manager_before = self._process_snapshot(manager.pid)
        child_before = self._process_snapshot(expected_child.pid)
        common_fields = {
            "first_observed_at": candidate.first_observed_at,
            "qualified_at": candidate.qualified_at,
            "observed_elapsed_seconds": candidate.observed_elapsed_seconds,
            "service_label": service_label,
        }
        if (
            self.stop_event.is_set()
            or not manager.is_same_process(manager_before)
            or not expected_child.is_same_process(child_before)
            or child_before is None
            or child_before.ppid != manager.pid
            or Path(child_before.command).name != "xpcproxy_sim"
        ):
            self._write_event(
                "stall_capture_skipped",
                reason="identity_changed_before_capture",
                expected_manager=manager.as_dict(),
                actual_manager=manager_before.as_dict() if manager_before else None,
                expected_child=expected_child.as_dict(),
                actual_child=child_before.as_dict() if child_before else None,
                **common_fields,
            )
            return False

        filename_time = utc_timestamp().replace(":", "").replace("-", "").replace(".", "")
        self.diagnostics_directory.mkdir(parents=True, exist_ok=True)
        stack_path = self.diagnostics_directory / (
            f"xpcproxy-{expected_child.pid}-{filename_time}.sample.txt"
        )

        tool_output_path = stack_path.with_suffix(".tool.log")
        command = ("/usr/bin/sample", str(expected_child.pid), "1", "5", "-file", str(stack_path))
        sample_started_at = utc_timestamp()
        result = self._run_owned_capture_tool(
            command,
            tool_output_path=tool_output_path,
            timeout=3.0,
        )

        sample_finished_at = utc_timestamp()
        child_after = self._process_snapshot(expected_child.pid)
        identity_unchanged = expected_child.is_same_process(child_after)
        self._write_event(
            "stall_capture",
            sample_started_at=sample_started_at,
            sample_finished_at=sample_finished_at,
            command=list(command),
            stack_path=str(stack_path),
            tool_output_path=str(tool_output_path),
            returncode=result.returncode,
            timed_out=result.timed_out,
            launch_error=result.launch_error,
            cleanup_error=result.cleanup_error,
            manager_identity=manager_before.as_dict() if manager_before else None,
            child_identity_before=child_before.as_dict(),
            child_identity_after=child_after.as_dict() if child_after else None,
            identity_unchanged=identity_unchanged,
            stack_valid=(
                result.launch_error is None
                and not result.timed_out
                and result.returncode == 0
                and identity_unchanged
                and stack_path.is_file()
            ),
            **common_fields,
        )
        return result.launched

    def _capture_kernel_stall(
        self,
        candidate: StallCandidate,
        manager: ProcessSnapshot,
        service_label: str,
    ) -> bool:
        """Capture one bounded kernel-aware stack for an exact WebKit pre-exec owner.

        Non-interactive sudo starts this script's fixed-command helper. The helper owns and bounds
        spindump directly, while the collector retains a longer outer bound around sudo.
        """

        expected_child = candidate.process
        manager_before = self._process_snapshot(manager.pid)
        child_before = self._process_snapshot(expected_child.pid)
        common_fields = {
            "first_observed_at": candidate.first_observed_at,
            "qualified_at": candidate.qualified_at,
            "observed_elapsed_seconds": candidate.observed_elapsed_seconds,
            "service_label": service_label,
        }
        if (
            self.stop_event.is_set()
            or not manager.is_same_process(manager_before)
            or not expected_child.is_same_process(child_before)
            or child_before is None
            or child_before.ppid != manager.pid
            or Path(child_before.command).name != "xpcproxy_sim"
        ):
            self._write_event(
                "kernel_stall_capture_skipped",
                reason="identity_changed_before_capture",
                expected_manager=manager.as_dict(),
                actual_manager=manager_before.as_dict() if manager_before else None,
                expected_child=expected_child.as_dict(),
                actual_child=child_before.as_dict() if child_before else None,
                **common_fields,
            )
            return False

        filename_time = utc_timestamp().replace(":", "").replace("-", "").replace(".", "")
        self.diagnostics_directory.mkdir(parents=True, exist_ok=True)
        stack_path = self.diagnostics_directory / (
            f"xpcproxy-{expected_child.pid}-{filename_time}.spindump.txt"
        )
        tool_output_path = stack_path.with_suffix(".tool.log")
        command = (
            "/usr/bin/sudo",
            "-n",
            sys.executable,
            str(Path(__file__).resolve()),
            "--capture-kernel-spindump",
            "--pid",
            str(expected_child.pid),
            "--diagnostics-directory",
            str(self.diagnostics_directory.resolve()),
            "--output",
            str(stack_path.resolve()),
        )
        capture_started_at = utc_timestamp()
        result = self._run_owned_capture_tool(
            command,
            tool_output_path=tool_output_path,
            timeout=8.0,
        )

        capture_finished_at = utc_timestamp()
        manager_after = self._process_snapshot(manager.pid)
        child_after = self._process_snapshot(expected_child.pid)
        identity_unchanged = manager.is_same_process(manager_after) and expected_child.is_same_process(
            child_after
        )
        self._write_event(
            "kernel_stall_capture",
            capture_started_at=capture_started_at,
            capture_finished_at=capture_finished_at,
            command=list(command),
            stack_path=str(stack_path),
            tool_output_path=str(tool_output_path),
            returncode=result.returncode,
            timed_out=result.timed_out,
            launch_error=result.launch_error,
            cleanup_error=result.cleanup_error,
            manager_identity_before=manager_before.as_dict() if manager_before else None,
            manager_identity_after=manager_after.as_dict() if manager_after else None,
            child_identity_before=child_before.as_dict(),
            child_identity_after=child_after.as_dict() if child_after else None,
            identity_unchanged=identity_unchanged,
            stack_valid=(
                result.launch_error is None
                and not result.timed_out
                and result.returncode == 0
                and identity_unchanged
                and stack_path.is_file()
            ),
            **common_fields,
        )
        return result.launched

    def _reap_owned_capture_process(self) -> None:
        """Reap or terminate only an owned diagnostic child; absorb cleanup errors."""

        process = self._owned_capture_process
        if process is None:
            return
        try:
            process.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            try:
                process.terminate()
                process.wait(timeout=0.5)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    process.kill()
                    process.wait(timeout=0.5)
                except (OSError, subprocess.TimeoutExpired):
                    pass
        finally:
            self._owned_capture_process = None

    def _write_event(self, event: str, **fields: object) -> None:
        """Append one flushed timestamped JSON metadata event."""

        self.diagnostics_directory.mkdir(parents=True, exist_ok=True)
        payload = {"recorded_at": utc_timestamp(), "event": event, **fields}
        with self.metadata_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, sort_keys=True) + "\n")
            handle.flush()


def parse_args(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse required simulator/artifact paths; argparse reports invalid input."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator-id", required=True)
    parser.add_argument("--resource-log", type=Path, required=True)
    parser.add_argument("--diagnostics-directory", type=Path, required=True)
    parser.add_argument("--interval-seconds", type=float, default=10.0)
    return parser.parse_args(arguments)


def run_privileged_spindump_helper(arguments: Sequence[str]) -> int:
    """Run only the fixed kernel-aware command beneath non-interactive sudo.

    The output must be a new direct child of the declared diagnostics directory.
    Signals are forwarded only to the helper-owned spindump process.
    """

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--diagnostics-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(arguments)
    diagnostics_directory = args.diagnostics_directory.resolve()
    output_path = args.output
    if (
        args.pid <= 0
        or not args.diagnostics_directory.is_absolute()
        or not output_path.is_absolute()
        or output_path.parent.resolve() != diagnostics_directory
        or output_path.exists()
        or not diagnostics_directory.is_dir()
    ):
        return 64

    owned_process: subprocess.Popen[str] | None = None
    stop_requested = False

    def remember_process(process: subprocess.Popen[str]) -> None:
        nonlocal owned_process
        owned_process = process
        if stop_requested and process.poll() is None:
            process.terminate()

    def forward_stop(_signum: int, _frame: object) -> None:
        nonlocal stop_requested
        stop_requested = True
        process = owned_process
        if process is not None and process.poll() is None:
            try:
                process.terminate()
            except OSError:
                pass

    previous_term = signal.signal(signal.SIGTERM, forward_stop)
    previous_int = signal.signal(signal.SIGINT, forward_stop)
    try:
        result = run_bounded_owned_tool(
            (
                "/usr/sbin/spindump",
                str(args.pid),
                "1",
                "10",
                "-onlyTarget",
                "-timelimit",
                "3",
                "-o",
                str(output_path),
            ),
            tool_output_path=output_path.with_name(output_path.name + ".native.log"),
            timeout=5.0,
            process_started=remember_process,
        )
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_int)
    if not result.launched:
        return 70
    if result.timed_out or result.cleanup_error is not None:
        return 124
    return result.returncode if result.returncode is not None else 70


def main(arguments: Sequence[str] | None = None) -> int:
    """Run until signaled; after valid arguments every failure returns success."""

    effective_arguments = list(arguments if arguments is not None else sys.argv[1:])
    if effective_arguments[:1] == ["--capture-kernel-spindump"]:
        return run_privileged_spindump_helper(effective_arguments[1:])
    args = parse_args(effective_arguments)
    try:
        collector = SimulatorResourceCollector(
            simulator_id=args.simulator_id,
            resource_log_path=args.resource_log,
            diagnostics_directory=args.diagnostics_directory,
            interval_seconds=args.interval_seconds,
        )
        signal.signal(signal.SIGTERM, lambda _signum, _frame: collector.request_stop())
        signal.signal(signal.SIGINT, lambda _signum, _frame: collector.request_stop())
        collector.run()
    except Exception as error:  # Diagnostic setup must not replace xcodebuild status.
        print(f"Simulator resource collector failed: {error!r}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
