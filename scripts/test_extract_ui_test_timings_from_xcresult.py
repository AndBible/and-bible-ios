from __future__ import annotations

import unittest

from extract_ui_test_timings_from_xcresult import extract_ui_test_timings, find_tests_ref_id


def typed_scalar(type_name: str, value: str) -> dict[str, object]:
    return {"_type": {"_name": type_name}, "_value": value}


def typed_array(values: list[dict[str, object]]) -> dict[str, object]:
    return {"_type": {"_name": "Array"}, "_values": values}


class ExtractUITestTimingsFromXCResultTests(unittest.TestCase):
    def test_find_tests_ref_id_extracts_first_reference(self) -> None:
        payload = {
            "actions": typed_array(
                [
                    {
                        "actionResult": {
                            "testsRef": {
                                "id": typed_scalar("String", "tests-ref-id"),
                            }
                        }
                    }
                ]
            )
        }

        self.assertEqual(find_tests_ref_id(payload), "tests-ref-id")

    def test_extract_ui_test_timings_filters_to_ui_test_metadata(self) -> None:
        payload = {
            "summaries": typed_array(
                [
                    {
                        "testableSummaries": typed_array(
                            [
                                {
                                    "testKind": typed_scalar("String", "UI"),
                                    "tests": typed_array(
                                        [
                                            {
                                                "subtests": typed_array(
                                                    [
                                                        {
                                                            "identifier": typed_scalar(
                                                                "String",
                                                                "AndBibleUITests/testAlpha()",
                                                            ),
                                                            "duration": typed_scalar("Double", "12.5"),
                                                        },
                                                        {
                                                            "identifier": typed_scalar(
                                                                "String",
                                                                "AndBibleUITests/testBeta()",
                                                            ),
                                                            "duration": typed_scalar("Double", "7.25"),
                                                        },
                                                    ]
                                                )
                                            }
                                        ]
                                    ),
                                },
                                {
                                    "testKind": typed_scalar("String", "Unit"),
                                    "tests": typed_array(
                                        [
                                            {
                                                "subtests": typed_array(
                                                    [
                                                        {
                                                            "identifier": typed_scalar(
                                                                "String",
                                                                "AndBibleTests/testUnit()",
                                                            ),
                                                            "duration": typed_scalar("Double", "1.0"),
                                                        }
                                                    ]
                                                )
                                            }
                                        ]
                                    ),
                                },
                            ]
                        )
                    }
                ]
            )
        }

        timings = extract_ui_test_timings(
            payload,
            test_target="AndBibleUITests",
            test_case_class="AndBibleUITests",
        )

        self.assertEqual(
            timings,
            {
                "AndBibleUITests/AndBibleUITests/testAlpha": 12.5,
                "AndBibleUITests/AndBibleUITests/testBeta": 7.25,
            },
        )


if __name__ == "__main__":
    unittest.main()
