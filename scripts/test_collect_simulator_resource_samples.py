from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from collect_simulator_resource_samples import (
    ProcessSnapshot,
    SimulatorResourceCollector,
    StallCandidate,
    XPCProxyStallDetector,
    parse_process_snapshots,
)


def snapshot(
    pid: int,
    *,
    ppid: int = 700,
    started_at: str = "Mon Oct 12 15:57:57 2026",
    state: str = "S",
    wait_channel: str = "waitq",
    command: str = "/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/xpcproxy_sim",
) -> ProcessSnapshot:
    return ProcessSnapshot(pid, ppid, started_at, state, wait_channel, command)


def observe(
    detector: XPCProxyStallDetector,
    processes: list[ProcessSnapshot],
    at: float,
) -> list[StallCandidate]:
    return detector.observe(
        processes,
        manager_pid=700,
        observed_at_monotonic=at,
        observed_at=f"2026-10-12T15:57:{int(at):02d}Z",
    )


def candidate(process: ProcessSnapshot) -> StallCandidate:
    return StallCandidate(
        process=process,
        first_observed_at="2026-10-12T15:57:00Z",
        qualified_at="2026-10-12T15:57:10Z",
        observed_elapsed_seconds=10.0,
    )


class XPCProxyStallDetectorTests(unittest.TestCase):
    def test_requires_two_stable_observations_at_least_five_seconds_apart(self) -> None:
        detector = XPCProxyStallDetector(minimum_stall_seconds=5.0, capture_limit=3)
        first = snapshot(800, state="S", wait_channel="first_wait")
        later = snapshot(800, state="D", wait_channel="later_wait")

        self.assertEqual(observe(detector, [first], 10.0), [])
        self.assertEqual(observe(detector, [later], 14.9), [])

        qualified = observe(detector, [later], 15.0)

        self.assertEqual([item.process for item in qualified], [later])
        self.assertEqual(qualified[0].first_observed_at, "2026-10-12T15:57:10Z")
        self.assertEqual(qualified[0].observed_elapsed_seconds, 5.0)

    def test_pid_reuse_resets_lifetime_and_one_pid_is_reserved_only_once(self) -> None:
        detector = XPCProxyStallDetector(minimum_stall_seconds=5.0, capture_limit=3)
        original = snapshot(800, started_at="Mon Oct 12 15:57:57 2026")
        reused = snapshot(800, started_at="Mon Oct 12 15:58:07 2026")

        self.assertEqual(observe(detector, [original], 0.0), [])
        self.assertEqual(observe(detector, [reused], 6.0), [])
        self.assertEqual([item.process for item in observe(detector, [reused], 11.0)], [reused])
        self.assertEqual(observe(detector, [], 12.0), [])
        self.assertEqual(
            observe(detector, [snapshot(800, started_at="Mon Oct 12 15:59:07 2026")], 20.0),
            [],
        )

    def test_capture_reservations_are_capped_at_three_for_the_job(self) -> None:
        detector = XPCProxyStallDetector(minimum_stall_seconds=5.0, capture_limit=3)
        children = [snapshot(pid) for pid in (801, 802, 803, 804)]

        self.assertEqual(observe(detector, children, 0.0), [])
        self.assertEqual(
            [item.process.pid for item in observe(detector, children, 5.0)],
            [801, 802, 803],
        )
        self.assertEqual(observe(detector, children, 20.0), [])

    def test_disappearance_breaks_continuous_observation(self) -> None:
        detector = XPCProxyStallDetector(minimum_stall_seconds=5.0, capture_limit=3)
        child = snapshot(800)

        observe(detector, [child], 0.0)
        observe(detector, [], 4.0)

        self.assertEqual(observe(detector, [child], 6.0), [])
        self.assertEqual([item.process for item in observe(detector, [child], 11.0)], [child])


class ProcessSnapshotParsingTests(unittest.TestCase):
    def test_parses_launch_identity_state_wait_channel_and_command(self) -> None:
        output = (
            "  42878  61179 Mon Oct 12 15:57:57 2026 S  waitq "
            "/Library/Developer/CoreSimulator/xpcproxy_sim\n"
        )

        self.assertEqual(
            parse_process_snapshots(output),
            [
                snapshot(
                    42878,
                    ppid=61179,
                    state="S",
                    wait_channel="waitq",
                    command="/Library/Developer/CoreSimulator/xpcproxy_sim",
                )
            ],
        )


class SimulatorResourceCollectorCaptureTests(unittest.TestCase):
    def make_collector(self, root: Path) -> SimulatorResourceCollector:
        return SimulatorResourceCollector(
            simulator_id="SIM-1",
            resource_log_path=root / "resources.log",
            diagnostics_directory=root / "stalls",
        )

    def test_nonzero_sample_status_is_recorded_once_without_raising(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            collector = self.make_collector(root)
            manager = snapshot(700, ppid=1, command="/Library/Developer/CoreSimulator/launchd_sim")
            child = snapshot(800)
            process = unittest.mock.MagicMock()
            process.wait.return_value = 7
            process.returncode = 7
            process.poll.return_value = 7

            with patch.object(collector, "_process_snapshot", side_effect=[manager, child, child]):
                with patch("collect_simulator_resource_samples.subprocess.Popen", return_value=process):
                    collector._capture_stall(candidate(child), manager)

            event = json.loads((root / "stalls" / "metadata.jsonl").read_text().splitlines()[-1])
            self.assertEqual(event["event"], "stall_capture")
            self.assertEqual(event["returncode"], 7)
            self.assertFalse(event["stack_valid"])
            self.assertEqual(event["first_observed_at"], "2026-10-12T15:57:00Z")
            self.assertEqual(event["observed_elapsed_seconds"], 10.0)
            process.wait.assert_called_once_with(timeout=3.0)

    def test_timeout_terminates_only_the_owned_sample_child(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            collector = self.make_collector(root)
            manager = snapshot(700, ppid=1, command="/Library/Developer/CoreSimulator/launchd_sim")
            child = snapshot(800)
            process = unittest.mock.MagicMock()
            process.wait.side_effect = [
                subprocess.TimeoutExpired(cmd=["sample"], timeout=3.0),
                -15,
            ]
            process.returncode = -15
            process.poll.return_value = -15

            with patch.object(collector, "_process_snapshot", side_effect=[manager, child, child]):
                with patch("collect_simulator_resource_samples.subprocess.Popen", return_value=process):
                    collector._capture_stall(candidate(child), manager)

            event = json.loads((root / "stalls" / "metadata.jsonl").read_text().splitlines()[-1])
            self.assertTrue(event["timed_out"])
            self.assertFalse(event["stack_valid"])
            process.terminate.assert_called_once_with()
            process.kill.assert_not_called()

    def test_exec_during_capture_invalidates_an_otherwise_successful_stack(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            collector = self.make_collector(root)
            manager = snapshot(700, ppid=1, command="/Library/Developer/CoreSimulator/launchd_sim")
            child = snapshot(800)
            web_content = snapshot(800, command="/System/Library/Frameworks/WebKit/WebContent")
            process = unittest.mock.MagicMock()
            process.wait.return_value = 0
            process.returncode = 0
            process.poll.return_value = 0
            stack_path_holder: list[Path] = []

            def create_stack(command: tuple[str, ...], **_kwargs: object) -> unittest.mock.MagicMock:
                stack_path = Path(command[-1])
                stack_path.parent.mkdir(parents=True, exist_ok=True)
                stack_path.write_text("stack")
                stack_path_holder.append(stack_path)
                return process

            with patch.object(collector, "_process_snapshot", side_effect=[manager, child, web_content]):
                with patch("collect_simulator_resource_samples.subprocess.Popen", side_effect=create_stack):
                    collector._capture_stall(candidate(child), manager)

            event = json.loads((root / "stalls" / "metadata.jsonl").read_text().splitlines()[-1])
            self.assertEqual(len(stack_path_holder), 1)
            self.assertFalse(event["identity_unchanged"])
            self.assertFalse(event["stack_valid"])
            self.assertEqual(event["child_identity_after"]["command"], web_content.command)

    def test_resource_command_errors_are_logged_and_do_not_raise(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            collector = self.make_collector(root)
            failed = subprocess.CompletedProcess(["diagnostic"], 9, "partial\n", "denied\n")

            with patch.object(collector, "_run_command", return_value=failed):
                collector._append_resource_snapshot()

            resource_log = (root / "resources.log").read_text()
            self.assertIn("partial", resource_log)
            self.assertIn("denied", resource_log)
            self.assertIn("resource_command_status=9", resource_log)

    def test_stop_request_prevents_remaining_resource_commands(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            collector = self.make_collector(Path(temporary_directory))
            success = subprocess.CompletedProcess(["diagnostic"], 0, "first\n", "")

            def stop_after_first(_command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
                collector.request_stop()
                return success

            with patch.object(collector, "_run_command", side_effect=stop_after_first) as run:
                collector._append_resource_snapshot()

            self.assertEqual(run.call_count, 1)

    def test_manager_identity_rejects_non_launchd_process(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            collector = self.make_collector(Path(temporary_directory))
            manager_pid = subprocess.CompletedProcess(
                ["launchctl"], 0,
                '"Label" = "com.apple.CoreSimulator.SimDevice.SIM-1";\n"PID" = 700;\n', ""
            )
            wrong_process = snapshot(700, ppid=1, command="/usr/libexec/not-launchd")

            with patch.object(collector, "_run_command", return_value=manager_pid):
                with patch.object(collector, "_process_snapshot", return_value=wrong_process):
                    self.assertIsNone(collector._resolve_manager_snapshot())

    def test_resolves_exact_host_service_without_guest_execution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            collector = self.make_collector(Path(temporary_directory))
            manager = snapshot(700, ppid=1, command="launchd_sim")
            result = subprocess.CompletedProcess(
                ["launchctl"], 0,
                '{\n\t"PID" = 700;\n\t"Label" = "com.apple.CoreSimulator.SimDevice.SIM-1";\n}', ""
            )
            with patch.object(collector, "_run_command", return_value=result) as run:
                with patch.object(collector, "_process_snapshot", return_value=manager) as read_process:
                    self.assertEqual(collector._resolve_manager_snapshot(), manager)

            run.assert_called_once_with(
                ("/bin/launchctl", "list", "com.apple.CoreSimulator.SimDevice.SIM-1")
            )
            read_process.assert_called_once_with(700)

    def test_unavailable_or_ambiguous_host_service_never_authorizes_a_process(self) -> None:
        label = '"Label" = "com.apple.CoreSimulator.SimDevice.SIM-1";\n'
        valid = label + '"PID" = 700;\n'
        for status, output in (
            (1, valid),
            (0, '"Label" = "com.apple.CoreSimulator.SimDevice.OTHER";\n"PID" = 700;\n'),
            (0, '"PID" = 700;\n'),
            (0, label),
            (0, label + '"PID" = unavailable;\n'),
            (0, label + '"PID" = 0;\n'),
            (0, label + '"PID" = -1;\n'),
            (0, label + valid),
            (0, valid + '"PID" = 701;\n'),
        ):
            with self.subTest(status=status, output=output):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    collector = self.make_collector(Path(temporary_directory))
                    result = subprocess.CompletedProcess(["launchctl"], status, output, "")
                    with patch.object(collector, "_run_command", return_value=result):
                        with patch.object(collector, "_process_snapshot") as read_process:
                            self.assertIsNone(collector._resolve_manager_snapshot())
                    read_process.assert_not_called()

    def test_request_stop_terminates_only_owned_sample_process(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            collector = self.make_collector(Path(temporary_directory))
            sample_process = unittest.mock.MagicMock()
            sample_process.poll.return_value = None
            collector._owned_sample_process = sample_process

            collector.request_stop()

            self.assertTrue(collector.stop_event.is_set())
            sample_process.terminate.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
