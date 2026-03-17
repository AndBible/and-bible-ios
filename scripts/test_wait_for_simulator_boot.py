import subprocess
import unittest
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from wait_for_simulator_boot import wait_for_boot


class WaitForSimulatorBootTests(unittest.TestCase):
    def test_wait_for_boot_returns_zero_when_bootstatus_succeeds(self) -> None:
        with patch("wait_for_simulator_boot.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["xcrun", "simctl", "bootstatus", "SIM-1", "-b"],
                returncode=0,
                stdout="Booted\n",
                stderr="",
            )

            self.assertEqual(wait_for_boot("SIM-1", timeout_seconds=10), 0)

    def test_wait_for_boot_returns_one_on_timeout_and_runs_diagnostics(self) -> None:
        with patch("wait_for_simulator_boot.subprocess.run") as run:
            run.side_effect = [
                subprocess.TimeoutExpired(cmd=["xcrun", "simctl", "bootstatus", "SIM-1", "-b"], timeout=10),
                subprocess.CompletedProcess(
                    args=["xcrun", "simctl", "list", "devices", "available"],
                    returncode=0,
                    stdout="devices\n",
                    stderr="",
                ),
                subprocess.CompletedProcess(args=["xcrun", "simctl", "list", "devices", "available"], returncode=0, stdout="devices\n", stderr=""),
                subprocess.CompletedProcess(args=["xcrun", "simctl", "list", "runtimes", "available"], returncode=0, stdout="runtimes\n", stderr=""),
            ]

            self.assertEqual(wait_for_boot("SIM-1", timeout_seconds=10), 1)

    def test_wait_for_boot_returns_zero_when_timeout_but_device_is_booted(self) -> None:
        with patch("wait_for_simulator_boot.subprocess.run") as run:
            run.side_effect = [
                subprocess.TimeoutExpired(cmd=["xcrun", "simctl", "bootstatus", "SIM-1", "-b"], timeout=10),
                subprocess.CompletedProcess(
                    args=["xcrun", "simctl", "list", "devices", "available"],
                    returncode=0,
                    stdout="    iPhone 17 (SIM-1) (Booted)\n",
                    stderr="",
                ),
            ]

            self.assertEqual(wait_for_boot("SIM-1", timeout_seconds=10), 0)

    def test_wait_for_boot_returns_zero_when_bootstatus_fails_but_device_is_booted(self) -> None:
        with patch("wait_for_simulator_boot.subprocess.run") as run:
            run.side_effect = [
                subprocess.CompletedProcess(
                    args=["xcrun", "simctl", "bootstatus", "SIM-1", "-b"],
                    returncode=149,
                    stdout="",
                    stderr="bootstatus failed\n",
                ),
                subprocess.CompletedProcess(
                    args=["xcrun", "simctl", "list", "devices", "available"],
                    returncode=0,
                    stdout="    iPhone 17 (SIM-1) (Booted)\n",
                    stderr="",
                ),
            ]

            self.assertEqual(wait_for_boot("SIM-1", timeout_seconds=10), 0)


if __name__ == "__main__":
    unittest.main()
