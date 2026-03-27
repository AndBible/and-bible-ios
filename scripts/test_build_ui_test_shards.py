from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from build_ui_test_shards import (
    assign_cases_to_shards,
    build_matrix,
    build_ui_test_cases,
    choose_shard_count,
    discover_ui_test_identifiers,
    load_timing_manifest,
)


class BuildUITestShardsTests(unittest.TestCase):
    def test_discover_ui_test_identifiers_extracts_only_test_methods(self) -> None:
        source = """
        final class AndBibleUITests: XCTestCase {
            func helper() {}
            func testAlpha() {}
            private func testBeta() {}
            func testGamma_example() {}
        }
        """

        identifiers = discover_ui_test_identifiers(
            source,
            test_target="AndBibleUITests",
            test_case_class="AndBibleUITests",
        )

        self.assertEqual(
            identifiers,
            [
                "AndBibleUITests/AndBibleUITests/testAlpha",
                "AndBibleUITests/AndBibleUITests/testBeta",
                "AndBibleUITests/AndBibleUITests/testGamma_example",
            ],
        )

    def test_load_timing_manifest_normalizes_short_identifiers(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "timings.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "AndBibleUITests/testAlpha()": 12.5,
                        "testBeta()": 4.0,
                    }
                )
            )

            timings = load_timing_manifest(
                manifest_path,
                test_target="AndBibleUITests",
                test_case_class="AndBibleUITests",
            )

        self.assertEqual(
            timings,
            {
                "AndBibleUITests/AndBibleUITests/testAlpha": 12.5,
                "AndBibleUITests/AndBibleUITests/testBeta": 4.0,
            },
        )

    def test_load_timing_manifest_rejects_unknown_identifier_formats(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "timings.json"
            manifest_path.write_text(json.dumps({"not-a-test-id": 12.5}))

            with self.assertRaisesRegex(ValueError, "Invalid timing manifest key 'not-a-test-id'"):
                load_timing_manifest(
                    manifest_path,
                    test_target="AndBibleUITests",
                    test_case_class="AndBibleUITests",
                )

    def test_assign_cases_to_shards_balances_estimated_runtime(self) -> None:
        identifiers = [
            "AndBibleUITests/AndBibleUITests/testSlow",
            "AndBibleUITests/AndBibleUITests/testMedium",
            "AndBibleUITests/AndBibleUITests/testFast",
        ]
        timings = {
            "AndBibleUITests/AndBibleUITests/testSlow": 20.0,
            "AndBibleUITests/AndBibleUITests/testMedium": 10.0,
            "AndBibleUITests/AndBibleUITests/testFast": 10.0,
        }
        cases = build_ui_test_cases(identifiers, timings, default_duration_seconds=1.0)

        shards = assign_cases_to_shards(cases, shard_count=2)

        shard_totals = [sum(case.estimated_seconds for case in shard) for shard in shards]
        self.assertEqual(sorted(shard_totals), [20.0, 20.0])

    def test_build_matrix_emits_multiline_only_testing_args(self) -> None:
        cases = build_ui_test_cases(
            [
                "AndBibleUITests/AndBibleUITests/testAlpha",
                "AndBibleUITests/AndBibleUITests/testBeta",
            ],
            {},
            default_duration_seconds=10.0,
        )
        shards = assign_cases_to_shards(cases, shard_count=1)

        matrix = build_matrix(shards, timeout_minutes=90)

        self.assertEqual(len(matrix["include"]), 1)
        entry = matrix["include"][0]
        self.assertEqual(entry["job_name"], "UI Tests (Simulator, Shard 1/1)")
        self.assertEqual(
            entry["test_selection_args"],
            "-only-testing:AndBibleUITests/AndBibleUITests/testAlpha\n"
            "-only-testing:AndBibleUITests/AndBibleUITests/testBeta",
        )

    def test_choose_shard_count_expands_from_runtime_target(self) -> None:
        identifiers = [
            "AndBibleUITests/AndBibleUITests/testAlpha",
            "AndBibleUITests/AndBibleUITests/testBeta",
            "AndBibleUITests/AndBibleUITests/testGamma",
        ]
        timings = {
            "AndBibleUITests/AndBibleUITests/testAlpha": 300.0,
            "AndBibleUITests/AndBibleUITests/testBeta": 300.0,
            "AndBibleUITests/AndBibleUITests/testGamma": 300.0,
        }
        cases = build_ui_test_cases(identifiers, timings, default_duration_seconds=60.0)

        shard_count = choose_shard_count(
            cases,
            minimum_shard_count=2,
            target_shard_duration_seconds=400.0,
            maximum_shard_count=None,
        )

        self.assertEqual(shard_count, 3)

    def test_choose_shard_count_respects_maximum(self) -> None:
        identifiers = [
            "AndBibleUITests/AndBibleUITests/testAlpha",
            "AndBibleUITests/AndBibleUITests/testBeta",
            "AndBibleUITests/AndBibleUITests/testGamma",
            "AndBibleUITests/AndBibleUITests/testDelta",
        ]
        timings = {
            "AndBibleUITests/AndBibleUITests/testAlpha": 300.0,
            "AndBibleUITests/AndBibleUITests/testBeta": 300.0,
            "AndBibleUITests/AndBibleUITests/testGamma": 300.0,
            "AndBibleUITests/AndBibleUITests/testDelta": 300.0,
        }
        cases = build_ui_test_cases(identifiers, timings, default_duration_seconds=60.0)

        shard_count = choose_shard_count(
            cases,
            minimum_shard_count=2,
            target_shard_duration_seconds=200.0,
            maximum_shard_count=3,
        )

        self.assertEqual(shard_count, 3)

    def test_assign_cases_to_shards_does_not_emit_empty_shards(self) -> None:
        identifiers = [
            "AndBibleUITests/AndBibleUITests/testAlpha",
            "AndBibleUITests/AndBibleUITests/testBeta",
        ]
        cases = build_ui_test_cases(identifiers, {}, default_duration_seconds=10.0)

        shards = assign_cases_to_shards(cases, shard_count=5)

        self.assertEqual(len(shards), 2)
        self.assertEqual(
            sorted(case.identifier for shard in shards for case in shard),
            identifiers,
        )


if __name__ == "__main__":
    unittest.main()
