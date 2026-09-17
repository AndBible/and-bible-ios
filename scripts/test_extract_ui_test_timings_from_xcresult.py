from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from extract_ui_test_timings_from_xcresult import (
    build_timing_manifest,
    extract_ui_test_timings,
    load_xcresult_payload,
    main,
    merge_ui_test_timings,
    reconcile_discovered_timings,
)


def test_results_payload(
    *tests: tuple[str, str, float | None],
    target: str = "AndBibleUITests",
    test_class: str = "AndBibleUITests",
) -> dict[str, object]:
    children: list[dict[str, object]] = []
    for method, result, duration in tests:
        node: dict[str, object] = {
            "name": f"{method}()",
            "nodeIdentifier": f"{test_class}/{method}()",
            "nodeIdentifierURL": (
                f"test://com.apple.xcode/AndBible/{target}/{test_class}/{method}"
            ),
            "nodeType": "Test Case",
            "result": result,
        }
        if duration is not None:
            node["durationInSeconds"] = duration
        children.append(node)
    return {
        "testNodes": [
            {
                "name": target,
                "nodeType": "Test Plan",
                "children": [
                    {
                        "name": target,
                        "nodeType": "UI test bundle",
                        "children": [
                            {
                                "name": test_class,
                                "nodeType": "Test Suite",
                                "children": children,
                            }
                        ],
                    }
                ],
            }
        ]
    }


class ExtractUITestTimingsFromXCResultTests(unittest.TestCase):
    def test_extract_ui_test_timings_uses_structured_test_nodes(self) -> None:
        payload = test_results_payload(
            ("testAlpha", "Passed", 12.5),
            ("testBeta", "Expected Failure", 7.25),
        )

        self.assertEqual(
            extract_ui_test_timings(
                payload,
                test_target="AndBibleUITests",
                test_case_class="AndBibleUITests",
            ),
            {
                "AndBibleUITests/AndBibleUITests/testAlpha": 12.5,
                "AndBibleUITests/AndBibleUITests/testBeta": 7.25,
            },
        )

    def test_extract_ui_test_timings_rejects_failed_attempt(self) -> None:
        with self.assertRaisesRegex(ValueError, "testAlpha reported Failed"):
            extract_ui_test_timings(
                test_results_payload(("testAlpha", "Failed", 2.0)),
                test_target="AndBibleUITests",
                test_case_class="AndBibleUITests",
            )

    def test_extract_ui_test_timings_rejects_missing_duration(self) -> None:
        with self.assertRaisesRegex(ValueError, "no valid durationInSeconds"):
            extract_ui_test_timings(
                test_results_payload(("testAlpha", "Passed", None)),
                test_target="AndBibleUITests",
                test_case_class="AndBibleUITests",
            )

    def test_extract_ui_test_timings_rejects_retry_attempts(self) -> None:
        with self.assertRaisesRegex(ValueError, "appears more than once"):
            extract_ui_test_timings(
                test_results_payload(
                    ("testAlpha", "Passed", 1.0),
                    ("testAlpha", "Passed", 2.0),
                ),
                test_target="AndBibleUITests",
                test_case_class="AndBibleUITests",
            )

    def test_merge_ui_test_timings_requires_disjoint_shards(self) -> None:
        with self.assertRaisesRegex(ValueError, "more than one xcresult bundle"):
            merge_ui_test_timings(
                [
                    test_results_payload(("testAlpha", "Passed", 1.0)),
                    test_results_payload(("testAlpha", "Passed", 2.0)),
                ],
                test_target="AndBibleUITests",
                test_case_class="AndBibleUITests",
            )

    def test_reconcile_discovered_timings_requires_exact_inventory(self) -> None:
        with self.assertRaisesRegex(
            ValueError,
            "missing discovered tests: AndBibleUITests/AndBibleUITests/testBeta",
        ):
            reconcile_discovered_timings(
                {"AndBibleUITests/AndBibleUITests/testAlpha": 1.0},
                [
                    "AndBibleUITests/AndBibleUITests/testAlpha",
                    "AndBibleUITests/AndBibleUITests/testBeta",
                ],
            )

    def test_build_timing_manifest_records_versioned_provenance(self) -> None:
        self.assertEqual(
            build_timing_manifest(
                {"AndBibleUITests/AndBibleUITests/testAlpha": 1.25},
                source_kind="github-actions-run",
                source_identifier="12345",
                collected_on="2026-09-13",
                limitations="Measured on the standard macOS runner.",
            ),
            {
                "schema_version": 1,
                "provenance": {
                    "status": "measured",
                    "collected_through": "2026-09-13",
                    "sources": [
                        {
                            "kind": "github-actions-run",
                            "identifier": "12345",
                            "collected_on": "2026-09-13",
                        }
                    ],
                    "limitations": "Measured on the standard macOS runner.",
                },
                "timings": {"AndBibleUITests/AndBibleUITests/testAlpha": 1.25},
            },
        )

    @patch("extract_ui_test_timings_from_xcresult.subprocess.run")
    def test_load_xcresult_payload_uses_current_structured_api(self, run_mock) -> None:
        payload = test_results_payload(("testAlpha", "Passed", 1.0))
        run_mock.return_value = subprocess.CompletedProcess(
            args=["xcrun", "xcresulttool"],
            returncode=0,
            stdout=json.dumps(payload),
            stderr="",
        )

        self.assertEqual(load_xcresult_payload(Path("result.xcresult")), payload)
        self.assertEqual(
            run_mock.call_args.args[0],
            [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "tests",
                "--path",
                "result.xcresult",
                "--compact",
            ],
        )

    @patch("extract_ui_test_timings_from_xcresult.load_xcresult_payload")
    def test_main_merges_all_shards_and_writes_planner_manifest(self, load_mock) -> None:
        load_mock.side_effect = [
            test_results_payload(("testAlpha", "Passed", 1.0)),
            test_results_payload(("testBeta", "Passed", 2.0)),
        ]
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "AndBibleUITests.swift"
            source.write_text(
                "func testAlpha() {}\n"
                "func testBeta() {}\n"
            )
            output = root / "timings.json"

            self.assertEqual(
                main(
                    [
                        "--xcresult-path",
                        "shard-1.xcresult",
                        "--xcresult-path",
                        "shard-2.xcresult",
                        "--test-source",
                        str(source),
                        "--source-kind",
                        "local-run",
                        "--source-identifier",
                        "manual-shard-run",
                        "--collected-on",
                        "2026-09-13",
                        "--output",
                        str(output),
                    ]
                ),
                0,
            )

            manifest = json.loads(output.read_text())
            self.assertEqual(
                manifest["timings"],
                {
                    "AndBibleUITests/AndBibleUITests/testAlpha": 1.0,
                    "AndBibleUITests/AndBibleUITests/testBeta": 2.0,
                },
            )
            self.assertEqual(manifest["provenance"]["status"], "measured")


if __name__ == "__main__":
    unittest.main()
