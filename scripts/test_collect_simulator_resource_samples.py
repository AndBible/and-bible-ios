from __future__ import annotations

import json
import os
import signal
import stat
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
    _retain_failed_spindump_stackshot,
    format_retained_stackshot,
    parse_process_arguments,
    parse_process_snapshots,
    run_bounded_owned_tool,
    run_privileged_spindump_helper,
    webkit_service_label,
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
        first_observed_monotonic=0.0,
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

    def test_release_allows_failed_classification_to_be_observed_again(self) -> None:
        detector = XPCProxyStallDetector(minimum_stall_seconds=5.0, capture_limit=3)
        child = snapshot(800)
        observe(detector, [child], 0.0)
        qualified = observe(detector, [child], 5.0)
        self.assertEqual([item.process for item in qualified], [child])

        detector.release(qualified[0])

        self.assertEqual([item.process for item in observe(detector, [child], 10.0)], [child])


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

    def test_parses_process_arguments_by_exact_pid(self) -> None:
        output = (
            "  42878 /runtime/xpcproxy_sim com.apple.WebKit.WebContent."
            "9CBD02D2-4267-4CBB-AB4E-CF197214645A\n"
            "  42879 /runtime/xpcproxy_sim com.apple.backboardd\n"
        )

        self.assertEqual(
            parse_process_arguments(output),
            {
                42878: (
                    "/runtime/xpcproxy_sim com.apple.WebKit.WebContent."
                    "9CBD02D2-4267-4CBB-AB4E-CF197214645A"
                ),
                42879: "/runtime/xpcproxy_sim com.apple.backboardd",
            },
        )

    def test_recognizes_only_exact_observed_webkit_service_label_shapes(self) -> None:
        uuid = "9CBD02D2-4267-4CBB-AB4E-CF197214645A"
        for label in (
            f"com.apple.WebKit.WebContent.{uuid}",
            f"com.apple.WebKit.WebContent.EnhancedSecurity.{uuid}",
            f"com.apple.WebKit.GPU.{uuid}",
            f"com.apple.WebKit.Networking.{uuid}",
            "com.apple.WebKit.WebContent",
        ):
            with self.subTest(label=label):
                self.assertEqual(webkit_service_label(f"/runtime/xpcproxy_sim {label}"), label)
        for arguments in (
            "/runtime/xpcproxy_sim com.apple.WebKit.WebContent.not-a-uuid",
            "/runtime/xpcproxy_sim --name=com.apple.WebKit.WebContent",
            "/runtime/xpcproxy_sim prefix-com.apple.WebKit.GPU",
            "/runtime/xpcproxy_sim 'com.apple.WebKit.WebContent",
            "/runtime/xpcproxy_sim com.apple.WebKit.WebContent com.apple.WebKit.GPU",
        ):
            with self.subTest(arguments=arguments):
                self.assertIsNone(webkit_service_label(arguments))


class OwnedToolLifecycleTests(unittest.TestCase):
    def test_real_timed_out_child_is_terminated_and_reaped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            child_pid: list[int] = []
            tool_output_path = Path(temporary_directory) / "child.log"
            previous_umask = os.umask(0o077)
            try:
                result = run_bounded_owned_tool(
                    (sys.executable, "-c", "import time; time.sleep(30)"),
                    tool_output_path=tool_output_path,
                    timeout=0.05,
                    process_started=lambda process: child_pid.append(process.pid),
                )
            finally:
                os.umask(previous_umask)

            self.assertTrue(result.launched)
            self.assertTrue(result.timed_out)
            self.assertIsNotNone(result.returncode)
            self.assertEqual(stat.S_IMODE(tool_output_path.stat().st_mode), 0o644)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid[0], 0)

    def test_privileged_helper_accepts_only_fixed_spindump_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            diagnostics = Path(temporary_directory).resolve()
            output = diagnostics / "capture.spindump.txt"
            process = unittest.mock.MagicMock()
            process.wait.return_value = 0
            process.poll.return_value = 0

            def inspect_command(command: tuple[str, ...], **_kwargs: object) -> object:
                self.assertEqual(command[0], "/usr/sbin/spindump")
                self.assertEqual(command[1:4], ("800", "1", "10"))
                self.assertIn("-onlyTarget", command)
                self.assertIn("-noIPC", command)
                self.assertEqual(command[command.index("-timelimit") + 1], "3")
                self.assertNotIn("-noSymbolicate", command)
                self.assertNotIn("-noBinary", command)
                self.assertEqual(Path(command[-1]), output)
                output.write_text("kernel stack")
                return process

            with patch(
                "collect_simulator_resource_samples.subprocess.Popen",
                side_effect=inspect_command,
            ):
                status = run_privileged_spindump_helper(
                    (
                        "--pid", "800",
                        "--diagnostics-directory", str(diagnostics),
                        "--output", str(output),
                    )
                )

            self.assertEqual(status, 0)

    def test_failed_spindump_retains_only_new_validated_raw_stackshot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            raw_directory = root / "var-tmp"
            raw_directory.mkdir()
            raw_path = raw_directory / "spindump-stuck-stackshot.2026-10-12-21:30:49.25057.buf"
            raw_path.write_bytes(b"raw-kcdata")
            native_log = root / "capture.native.log"
            native_log.write_text(f"spindump-stuck: Wrote stackshot to {raw_path}\n")
            destination = root / "capture.raw.buf"

            with patch(
                "collect_simulator_resource_samples.SPINDUMP_STUCK_DIRECTORY",
                raw_directory,
            ):
                previous_umask = os.umask(0o077)
                try:
                    retained = _retain_failed_spindump_stackshot(
                        native_log,
                        destination,
                        existing_stackshots=set(),
                        required_owner_uid=os.getuid(),
                    )
                finally:
                    os.umask(previous_umask)

            self.assertEqual(retained, destination)
            self.assertEqual(destination.read_bytes(), b"raw-kcdata")
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o644)

    def test_raw_stackshot_validation_rejects_untrusted_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            raw_directory = root / "var-tmp"
            raw_directory.mkdir()
            valid_name = "spindump-stuck-stackshot.2026-10-12-21:30:49.25057.buf"
            raw_path = raw_directory / valid_name
            raw_path.write_bytes(b"raw-kcdata")
            native_log = root / "capture.native.log"
            destination = root / "capture.raw.buf"

            with patch(
                "collect_simulator_resource_samples.SPINDUMP_STUCK_DIRECTORY",
                raw_directory,
            ):
                for log_text, existing, owner in (
                    (f"spindump-stuck: Wrote stackshot to {raw_path}\n", {raw_path}, os.getuid()),
                    (f"spindump-stuck: Wrote stackshot to {raw_path}\n", set(), os.getuid() + 1),
                    (f"spindump-stuck: Wrote stackshot to {root / valid_name}\n", set(), os.getuid()),
                    (f"spindump-stuck: Wrote stackshot to {raw_path}\n"
                     f"spindump-stuck: Wrote stackshot to {raw_path}\n", set(), os.getuid()),
                ):
                    with self.subTest(log_text=log_text, existing=existing, owner=owner):
                        native_log.write_text(log_text)
                        self.assertIsNone(
                            _retain_failed_spindump_stackshot(
                                native_log,
                                destination,
                                existing_stackshots=existing,
                                required_owner_uid=owner,
                            )
                        )
                        self.assertFalse(destination.exists())

                with patch(
                    "collect_simulator_resource_samples.MAX_RAW_STACKSHOT_BYTES",
                    len(b"raw-kcdata") - 1,
                ):
                    native_log.write_text(f"spindump-stuck: Wrote stackshot to {raw_path}\n")
                    self.assertIsNone(
                        _retain_failed_spindump_stackshot(
                            native_log,
                            destination,
                            existing_stackshots=set(),
                            required_owner_uid=os.getuid(),
                        )
                    )
                    self.assertFalse(destination.exists())

                raw_path.unlink()
                raw_path.symlink_to(root / "attacker-controlled")
                native_log.write_text(f"spindump-stuck: Wrote stackshot to {raw_path}\n")
                self.assertIsNone(
                    _retain_failed_spindump_stackshot(
                        native_log,
                        destination,
                        existing_stackshots=set(),
                        required_owner_uid=os.getuid(),
                    )
                )
                self.assertFalse(destination.exists())

    def test_privileged_helper_rejects_output_outside_diagnostics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            diagnostics = Path(temporary_directory).resolve()
            with patch("collect_simulator_resource_samples.subprocess.Popen") as launch:
                status = run_privileged_spindump_helper(
                    (
                        "--pid", "800",
                        "--diagnostics-directory", str(diagnostics),
                        "--output", str(diagnostics.parent / "outside.spindump.txt"),
                    )
                )
            self.assertEqual(status, 64)
            launch.assert_not_called()

    def test_privileged_helper_retains_raw_stackshot_after_report_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            diagnostics = Path(temporary_directory).resolve()
            output = diagnostics / "capture.spindump.txt"
            process = unittest.mock.MagicMock()
            process.wait.return_value = 75
            process.poll.return_value = 75

            with patch(
                "collect_simulator_resource_samples.subprocess.Popen",
                return_value=process,
            ):
                with patch(
                    "collect_simulator_resource_samples._retain_failed_spindump_stackshot",
                    return_value=diagnostics / "capture.spindump.txt.raw.buf",
                ) as retain:
                    with patch("builtins.print"):
                        status = run_privileged_spindump_helper(
                            (
                                "--pid", "800",
                                "--diagnostics-directory", str(diagnostics),
                                "--output", str(output),
                            )
                        )

            self.assertEqual(status, 75)
            retain.assert_called_once()

    def test_formats_exactly_one_retained_stackshot_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            diagnostics = Path(temporary_directory).resolve()
            raw = diagnostics / "xpcproxy-800-20261012T213133986627Z.spindump.txt.raw.buf"
            raw.write_bytes(b"raw-kcdata")
            process = unittest.mock.MagicMock()
            process.wait.return_value = 0
            process.poll.return_value = 0

            def inspect_command(command: tuple[str, ...], **_kwargs: object) -> object:
                self.assertEqual(command[0:3], ("/usr/sbin/spindump", "-i", str(raw)))
                self.assertIn("-noIPC", command)
                self.assertIn("-inspectLiveSystem", command)
                self.assertEqual(command[command.index("-timelimit") + 1], "30")
                Path(command[-1]).write_text("formatted stack")
                return process

            with patch(
                "collect_simulator_resource_samples.subprocess.Popen",
                side_effect=inspect_command,
            ):
                status = format_retained_stackshot(
                    ("--diagnostics-directory", str(diagnostics)),
                    required_owner_uid=os.getuid(),
                )

            self.assertEqual(status, 0)
            self.assertEqual(raw.read_bytes(), b"raw-kcdata")
            process.wait.assert_called_once_with(timeout=35.0)

    def test_retained_stackshot_formatter_is_noop_when_no_raw_capture_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            diagnostics = Path(temporary_directory).resolve()
            with patch("collect_simulator_resource_samples.subprocess.Popen") as launch:
                status = format_retained_stackshot(
                    ("--diagnostics-directory", str(diagnostics)),
                )

            self.assertEqual(status, 0)
            launch.assert_not_called()

    def test_retained_stackshot_timeout_preserves_raw_and_reaps_formatter(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            diagnostics = Path(temporary_directory).resolve()
            raw = diagnostics / "xpcproxy-800-20261012T213133986627Z.spindump.txt.raw.buf"
            raw.write_bytes(b"raw-kcdata")
            process = unittest.mock.MagicMock()
            process.wait.side_effect = [
                subprocess.TimeoutExpired(cmd=["spindump"], timeout=35.0),
                -15,
            ]
            process.poll.return_value = -15

            with patch(
                "collect_simulator_resource_samples.subprocess.Popen",
                return_value=process,
            ):
                status = format_retained_stackshot(
                    ("--diagnostics-directory", str(diagnostics)),
                    required_owner_uid=os.getuid(),
                )

            self.assertEqual(status, 124)
            self.assertEqual(raw.read_bytes(), b"raw-kcdata")
            process.terminate.assert_called_once_with()
            process.kill.assert_not_called()

    def test_retained_stackshot_formatter_rejects_ambiguous_or_untrusted_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            diagnostics = Path(temporary_directory).resolve()
            valid = diagnostics / "xpcproxy-800-20261012T213133986627Z.spindump.txt.raw.buf"
            malformed = diagnostics / "attacker.spindump.txt.raw.buf"
            malformed.write_bytes(b"raw-kcdata")
            with patch("collect_simulator_resource_samples.subprocess.Popen") as launch:
                self.assertEqual(
                    format_retained_stackshot(
                        ("--diagnostics-directory", str(diagnostics)),
                        required_owner_uid=os.getuid(),
                    ),
                    64,
                )
                launch.assert_not_called()

                valid.write_bytes(b"raw-kcdata")
                second = diagnostics / "xpcproxy-801-20261012T213133986628Z.spindump.txt.raw.buf"
                second.write_bytes(b"raw-kcdata")
                self.assertEqual(
                    format_retained_stackshot(
                        ("--diagnostics-directory", str(diagnostics)),
                        required_owner_uid=os.getuid(),
                    ),
                    64,
                )
                launch.assert_not_called()

    def test_privileged_helper_honors_stop_during_child_registration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            diagnostics = Path(temporary_directory).resolve()
            output = diagnostics / "capture.spindump.txt"
            child_pid: list[int] = []
            original_popen = subprocess.Popen

            def launch_then_stop(_command: tuple[str, ...], **kwargs: object) -> object:
                process = original_popen(
                    (sys.executable, "-c", "import time; time.sleep(30)"),
                    **kwargs,
                )
                child_pid.append(process.pid)
                os.kill(os.getpid(), signal.SIGTERM)
                return process

            with patch(
                "collect_simulator_resource_samples.subprocess.Popen",
                side_effect=launch_then_stop,
            ):
                status = run_privileged_spindump_helper(
                    (
                        "--pid", "800",
                        "--diagnostics-directory", str(diagnostics),
                        "--output", str(output),
                    )
                )

            self.assertEqual(status, -15)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid[0], 0)


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

    def test_stop_before_owned_child_registration_terminates_and_reaps_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            collector = self.make_collector(Path(temporary_directory))
            collector.stop_event.set()

            result = collector._run_owned_capture_tool(
                (sys.executable, "-c", "import time; time.sleep(30)"),
                tool_output_path=Path(temporary_directory) / "child.log",
                timeout=1.0,
            )
            self.assertTrue(result.launched)
            self.assertEqual(result.returncode, -15)
            self.assertIsNone(collector._owned_capture_process)

    def test_classification_preserves_webkit_capacity_after_one_boot_control(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            collector = self.make_collector(Path(temporary_directory))
            manager = snapshot(700, ppid=1, command="launchd_sim")
            boot = candidate(snapshot(800))
            ignored_boot = candidate(snapshot(801))
            web_content = candidate(snapshot(802))
            gpu = candidate(snapshot(803))
            extra_web_content = candidate(snapshot(804))
            labels = {
                800: "/runtime/xpcproxy_sim com.apple.backboardd",
                801: "/runtime/xpcproxy_sim com.apple.SpringBoard",
                802: "/runtime/xpcproxy_sim com.apple.WebKit.WebContent",
                803: "/runtime/xpcproxy_sim com.apple.WebKit.GPU",
                804: "/runtime/xpcproxy_sim com.apple.WebKit.WebContent",
            }

            with patch.object(collector, "_process_arguments", return_value=labels):
                with patch.object(collector, "_capture_stall", return_value=True) as sample_capture:
                    with patch.object(
                        collector, "_capture_kernel_stall", return_value=True
                    ) as kernel_capture:
                        collector._capture_candidates(
                            [boot, ignored_boot, web_content, gpu, extra_web_content], manager
                        )

            self.assertEqual(
                [(call.args[0].process.pid, call.kwargs.get("service_label")) for call in sample_capture.call_args_list],
                [(803, "com.apple.WebKit.GPU"), (800, None)],
            )
            kernel_capture.assert_called_once_with(
                web_content, manager, "com.apple.WebKit.WebContent"
            )

    def test_prelaunch_identity_skip_does_not_consume_a_tool_slot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            collector = self.make_collector(Path(temporary_directory))
            manager = snapshot(700, ppid=1, command="launchd_sim")
            first = candidate(snapshot(800))
            second = candidate(snapshot(801))
            labels = {
                800: "/runtime/xpcproxy_sim com.apple.WebKit.WebContent",
                801: "/runtime/xpcproxy_sim com.apple.WebKit.GPU",
            }

            with patch.object(collector, "_process_arguments", return_value=labels):
                with patch.object(
                    collector, "_capture_kernel_stall", side_effect=[False, True]
                ) as kernel_capture:
                    collector._capture_candidates([first, second], manager)

            self.assertEqual(kernel_capture.call_count, 2)
            self.assertEqual(collector._kernel_capture_count, 1)
            self.assertEqual(collector._webkit_capture_count, 1)

    def test_unavailable_arguments_defer_without_consuming_capture_slots(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            collector = self.make_collector(Path(temporary_directory))
            manager = snapshot(700, ppid=1, command="launchd_sim")
            unavailable = candidate(snapshot(800))

            with patch.object(collector, "_process_arguments", return_value={}):
                with patch.object(collector.detector, "release") as release:
                    with patch.object(collector, "_capture_stall") as sample_capture:
                        collector._capture_candidates([unavailable], manager)

            release.assert_called_once_with(unavailable)
            sample_capture.assert_not_called()
            self.assertEqual(collector._boot_capture_count, 0)
            self.assertEqual(collector._webkit_capture_count, 0)

    def test_kernel_capture_uses_bounded_noninteractive_root_wrapper(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            collector = self.make_collector(root)
            manager = snapshot(700, ppid=1, command="launchd_sim")
            child = snapshot(800)
            process = unittest.mock.MagicMock()
            process.wait.return_value = 0
            process.returncode = 0
            process.poll.return_value = 0

            def create_stack(command: tuple[str, ...], **_kwargs: object) -> unittest.mock.MagicMock:
                self.assertEqual(command[:2], ("/usr/bin/sudo", "-n"))
                self.assertEqual(Path(command[2]), Path(sys.executable))
                self.assertEqual(command[4], "--capture-kernel-spindump")
                self.assertEqual(command[command.index("--pid") + 1], "800")
                output = Path(command[command.index("--output") + 1])
                output.write_text("kernel stack")
                return process

            with patch.object(
                collector,
                "_process_snapshot",
                side_effect=[manager, child, manager, child],
            ):
                with patch(
                    "collect_simulator_resource_samples.subprocess.Popen",
                    side_effect=create_stack,
                ):
                    collector._capture_kernel_stall(
                        candidate(child), manager, "com.apple.WebKit.WebContent"
                    )

            event = json.loads((root / "stalls" / "metadata.jsonl").read_text().splitlines()[-1])
            self.assertEqual(event["event"], "kernel_stall_capture")
            self.assertTrue(event["stack_valid"])
            process.wait.assert_called_once_with(timeout=8.0)

    def test_kernel_capture_timeout_reaps_only_owned_sudo_process(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            collector = self.make_collector(root)
            manager = snapshot(700, ppid=1, command="launchd_sim")
            child = snapshot(800)
            process = unittest.mock.MagicMock()
            process.wait.side_effect = [
                subprocess.TimeoutExpired(cmd=["sudo", "spindump"], timeout=5.0),
                -15,
            ]
            process.returncode = -15
            process.poll.return_value = -15

            with patch.object(
                collector,
                "_process_snapshot",
                side_effect=[manager, child, manager, child],
            ):
                with patch(
                    "collect_simulator_resource_samples.subprocess.Popen",
                    return_value=process,
                ):
                    collector._capture_kernel_stall(
                        candidate(child), manager, "com.apple.WebKit.WebContent"
                    )

            event = json.loads((root / "stalls" / "metadata.jsonl").read_text().splitlines()[-1])
            self.assertTrue(event["timed_out"])
            self.assertFalse(event["stack_valid"])
            process.terminate.assert_called_once_with()
            process.kill.assert_not_called()

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

    def test_request_stop_terminates_only_owned_capture_process(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            collector = self.make_collector(Path(temporary_directory))
            sample_process = unittest.mock.MagicMock()
            sample_process.poll.return_value = None
            collector._owned_capture_process = sample_process

            collector.request_stop()

            self.assertTrue(collector.stop_event.is_set())
            sample_process.terminate.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
