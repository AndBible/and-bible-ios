import io
import unittest
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from resolve_ios_simulator_destination import (
    choose_candidate,
    choose_device_type,
    choose_existing_device,
    choose_runtime,
    has_simulator_placeholder,
    parse_candidates,
    print_resolved_output,
)


class ResolveIosSimulatorDestinationTests(unittest.TestCase):
    def test_parse_candidates_filters_to_real_iphone_simulators(self) -> None:
        text = "\n".join(
            [
                "{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, OS:18.2, name:Any iOS Simulator Device }",
                "{ platform:iOS Simulator, id:ABC-123, OS:18.2, name:iPhone 16 Pro }",
                "{ platform:iOS Simulator, id:DEF-456, OS:18.2, name:iPad Pro (13-inch) (M4) }",
                "{ platform:macOS, id:MAC-1, name:My Mac }",
            ]
        )

        self.assertEqual(parse_candidates(text), [("iPhone 16 Pro", "18.2", "ABC-123")])

    def test_choose_candidate_prefers_known_devices(self) -> None:
        candidates = [
            ("iPhone 15", "17.5", "ID-15"),
            ("iPhone 16 Pro", "18.2", "ID-16P"),
        ]

        self.assertEqual(choose_candidate(candidates), ("iPhone 16 Pro", "18.2", "ID-16P"))

    def test_choose_candidate_falls_back_to_first_available(self) -> None:
        candidates = [
            ("iPhone 14", "17.4", "ID-14"),
            ("iPhone 13 mini", "17.4", "ID-13M"),
        ]

        self.assertEqual(choose_candidate(candidates), ("iPhone 14", "17.4", "ID-14"))

    def test_has_simulator_placeholder_detects_placeholder_only_output(self) -> None:
        text = "{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }"
        self.assertTrue(has_simulator_placeholder(text))

    def test_choose_runtime_prefers_latest_available_ios_runtime(self) -> None:
        payload = {
            "runtimes": [
                {"identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-18-0", "version": "18.0", "isAvailable": True},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-5", "version": "17.5", "isAvailable": True},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-2", "version": "18.2", "isAvailable": True},
            ]
        }

        runtime = choose_runtime(payload)
        self.assertIsNotNone(runtime)
        self.assertEqual(runtime["identifier"], "com.apple.CoreSimulator.SimRuntime.iOS-18-2")

    def test_choose_device_type_respects_preferred_order_with_supported_runtime_types(self) -> None:
        runtime = {
            "supportedDeviceTypes": [
                {"name": "iPhone 15", "identifier": "iphone-15", "productFamily": "iPhone"},
                {"name": "iPhone 16", "identifier": "iphone-16", "productFamily": "iPhone"},
                {"name": "iPad Pro", "identifier": "ipad-pro", "productFamily": "iPad"},
            ]
        }

        device_type = choose_device_type(runtime)
        self.assertIsNotNone(device_type)
        self.assertEqual(device_type["identifier"], "iphone-16")

    def test_choose_existing_device_reuses_available_runtime_device(self) -> None:
        payload = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
                    {"name": "iPhone 15", "udid": "ID-15", "isAvailable": True},
                    {"name": "iPhone 16 Pro", "udid": "ID-16P", "isAvailable": True},
                ]
            }
        }

        device = choose_existing_device(payload, "com.apple.CoreSimulator.SimRuntime.iOS-18-2")
        self.assertIsNotNone(device)
        self.assertEqual(device["udid"], "ID-16P")

    def test_print_resolved_output_emits_local_cli_values(self) -> None:
        with patch("sys.stdout", new_callable=io.StringIO) as stdout:
            print_resolved_output("id=ABC-123", "iPhone 16 Pro", "18.2")

        self.assertEqual(
            stdout.getvalue(),
            "destination=id=ABC-123\n"
            "device_name=iPhone 16 Pro\n"
            "os_version=18.2\n",
        )


if __name__ == "__main__":
    unittest.main()
