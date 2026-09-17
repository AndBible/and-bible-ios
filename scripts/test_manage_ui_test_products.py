"""Behavioral tests for portable UI-test product packaging and verification."""

from __future__ import annotations

import io
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

from manage_ui_test_products import (
    FIXTURE_MANIFEST_RELATIVE_PATH,
    ProductArchiveError,
    SWORD_DERIVED_CACHE_RELATIVE_PATH,
    RUNNER_LOCAL_UI_TEST_ENVIRONMENT_KEYS,
    ToolchainProvenance,
    _resolve_xctestrun_product_path,
    _write_github_output,
    current_toolchain_provenance,
    compose_sword_fixture,
    inventory_payload,
    package_products,
    strip_runner_local_ui_test_environment,
    validate_calvin_fixture,
    validate_baseline_fixture_excludes_calvin,
    verify_products,
)


PROVENANCE = ToolchainProvenance(
    xcode_version="Xcode 26.3\nBuild version 17C529",
    simulator_sdk_version="26.2",
    runner_architecture="arm64",
)


class ManageUITestProductsTests(unittest.TestCase):
    """Exercises product discovery, provenance checks, and payload integrity."""

    def test_checked_in_calvin_fixture_matches_reviewed_provenance(self) -> None:
        repository_root = Path(__file__).resolve().parents[1]
        validate_calvin_fixture(
            repository_root / "Tests/UI/Fixtures/calvin-sword"
        )

    def test_shared_sword_fixture_retains_exact_pre_calvin_baseline(self) -> None:
        repository_root = Path(__file__).resolve().parents[1]
        baseline = repository_root / "Sources/BibleUI/Tests/BibleUITests/Fixtures/sword"
        expected = {
            "mods.d/kjv.conf",
            "modules/texts/ztext/kjv/nt.bzs",
            "modules/texts/ztext/kjv/nt.bzv",
            "modules/texts/ztext/kjv/nt.bzz",
            "modules/texts/ztext/kjv/ot.bzs",
            "modules/texts/ztext/kjv/ot.bzv",
            "modules/texts/ztext/kjv/ot.bzz",
            "ui-test-encrypted-rawtext/nt",
            "ui-test-encrypted-rawtext/nt.vss",
            "ui-test-encrypted-rawtext/ot",
            "ui-test-encrypted-rawtext/ot.vss",
        }
        self.assertEqual(
            {
                relative
                for path in baseline.rglob("*")
                if path.is_file()
                and (relative := path.relative_to(baseline).as_posix())
                != SWORD_DERIVED_CACHE_RELATIVE_PATH.as_posix()
            },
            expected,
        )
        validate_baseline_fixture_excludes_calvin(baseline)

    def test_ui_product_composition_adds_reviewed_calvin_to_baseline_copy(self) -> None:
        repository_root = Path(__file__).resolve().parents[1]
        baseline = repository_root / "Sources/BibleUI/Tests/BibleUITests/Fixtures/sword"
        calvin = repository_root / "Tests/UI/Fixtures/calvin-sword"
        baseline_before = {
            path.relative_to(baseline).as_posix(): path.read_bytes()
            for path in baseline.rglob("*") if path.is_file()
        }
        calvin_before = {
            path.relative_to(calvin).as_posix(): path.read_bytes()
            for path in calvin.rglob("*") if path.is_file()
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            destination = Path(temporary_directory) / "composite"
            compose_sword_fixture(baseline, calvin, destination)
            validate_calvin_fixture(destination)
            self.assertTrue((destination / "mods.d/kjv.conf").is_file())
            self.assertFalse((baseline / "mods.d/calvincommentaries.conf").exists())
        self.assertEqual(
            {path.relative_to(baseline).as_posix(): path.read_bytes()
             for path in baseline.rglob("*") if path.is_file()},
            baseline_before,
        )
        self.assertEqual(
            {path.relative_to(calvin).as_posix(): path.read_bytes()
             for path in calvin.rglob("*") if path.is_file()},
            calvin_before,
        )

    def test_ui_product_composition_excludes_libsword_derived_module_cache(self) -> None:
        repository_root = Path(__file__).resolve().parents[1]
        source_baseline = repository_root / "Sources/BibleUI/Tests/BibleUITests/Fixtures/sword"
        calvin = repository_root / "Tests/UI/Fixtures/calvin-sword"
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            baseline = root / "baseline"
            destination = root / "composite"
            shutil.copytree(source_baseline, baseline)
            derived_cache = baseline / SWORD_DERIVED_CACHE_RELATIVE_PATH
            derived_cache.write_text("libsword generated cache", encoding="utf-8")

            compose_sword_fixture(baseline, calvin, destination)

            self.assertTrue(derived_cache.is_file())
            self.assertFalse((destination / SWORD_DERIVED_CACHE_RELATIVE_PATH).exists())
            validate_calvin_fixture(destination)

    def test_baseline_only_product_excludes_derived_cache_without_mutating_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            products, fixture, fixture_manifest, sword_fixture = self.make_products(root)
            derived_cache = sword_fixture / SWORD_DERIVED_CACHE_RELATIVE_PATH
            derived_cache.write_text("libsword generated cache", encoding="utf-8")
            archive = root / "ui-test-products.tar.gz"

            package_products(
                products_path=products,
                fixture_tool=fixture,
                fixture_manifest=fixture_manifest,
                sword_fixture=sword_fixture,
                output_path=archive,
                commit_sha="abc123",
                configuration="Debug",
                code_signing_allowed="NO",
                provenance=PROVENANCE,
                architecture_reader=self.fake_architectures,
            )
            destination = root / "restored"
            destination.mkdir()
            verify_products(
                archive_path=archive,
                destination=destination,
                expected_commit_sha="abc123",
                expected_configuration="Debug",
                expected_code_signing_allowed="NO",
                provenance=PROVENANCE,
                architecture_reader=self.fake_architectures,
            )

            self.assertTrue(derived_cache.is_file())
            self.assertFalse(
                (destination / ".ui-test/fixtures/sword" / SWORD_DERIVED_CACHE_RELATIVE_PATH).exists()
            )

    def test_calvin_ui_product_round_trip_restores_composed_fixture(self) -> None:
        repository_root = Path(__file__).resolve().parents[1]
        calvin = repository_root / "Tests/UI/Fixtures/calvin-sword"
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            products, fixture, fixture_manifest, sword_fixture = self.make_products(root)
            fixture_manifest.write_text(
                json.dumps({"AndBibleUITests/testCalvin": "calvin-commentary-scroll-restoration"}),
                encoding="utf-8",
            )
            archive = root / "ui-test-products.tar.gz"
            package_products(
                products_path=products,
                fixture_tool=fixture,
                fixture_manifest=fixture_manifest,
                sword_fixture=sword_fixture,
                calvin_fixture=calvin,
                output_path=archive,
                commit_sha="abc123",
                configuration="Debug",
                code_signing_allowed="NO",
                provenance=PROVENANCE,
                architecture_reader=self.fake_architectures,
            )
            destination = root / "restored"
            destination.mkdir()
            verify_products(
                archive_path=archive,
                destination=destination,
                expected_commit_sha="abc123",
                expected_configuration="Debug",
                expected_code_signing_allowed="NO",
                provenance=PROVENANCE,
                architecture_reader=self.fake_architectures,
            )
            restored = destination / ".ui-test/fixtures/sword"
            validate_calvin_fixture(restored)
            self.assertTrue((restored / "mods.d/kjv.conf").is_file())

    def test_calvin_manifest_requires_self_contained_module(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            products, fixture, fixture_manifest, sword_fixture = self.make_products(root)
            fixture_manifest.write_text(
                json.dumps({"AndBibleUITests/testCalvin": "calvin-commentary-scroll-restoration"}),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ProductArchiveError, "Calvin fixture"):
                package_products(
                    products_path=products,
                    fixture_tool=fixture,
                    fixture_manifest=fixture_manifest,
                    sword_fixture=sword_fixture,
                    output_path=root / "archive.tar.gz",
                    commit_sha="abc123",
                    configuration="Debug",
                    code_signing_allowed="NO",
                    provenance=PROVENANCE,
                    architecture_reader=self.fake_architectures,
                )

    def test_exported_consumer_paths_work_outside_the_restoring_directory(self) -> None:
        """A separate consumer can read every emitted path after relative restoration."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            destination = root / "consumer"
            payloads = {
                "xctestrun_path": ".derivedData/Build/Products/AndBible.xctestrun",
                "fixture_tool_path": ".build/debug/UITestFixtureTool",
                "fixture_manifest_path": ".ui-test/fixtures/ui_test_fixture_manifest.json",
                "sword_fixture_path": ".ui-test/fixtures/sword",
            }
            for key, relative_path in payloads.items():
                path = destination / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                if key == "sword_fixture_path":
                    path.mkdir()
                    (path / "module.conf").write_text("fixture")
                else:
                    path.write_text(key)
            output = root / "github-output"
            previous_directory = Path.cwd()
            try:
                os.chdir(destination)
                _write_github_output(output, Path("."), Path(payloads["xctestrun_path"]))
            finally:
                os.chdir(previous_directory)
            exported = dict(line.split("=", 1) for line in output.read_text().splitlines())
            script = (
                "import json,pathlib,sys; values=json.loads(sys.argv[1]); "
                "print(json.dumps({key:(pathlib.Path(value).is_dir() if key == "
                "'sword_fixture_path' else pathlib.Path(value).read_text()) "
                "for key,value in values.items()}))"
            )
            result = subprocess.run(
                [sys.executable, "-c", script, json.dumps(exported)],
                cwd=root, capture_output=True, text=True, check=True,
            )
            self.assertEqual(json.loads(result.stdout), {
                key: True if key == "sword_fixture_path" else key for key in payloads
            })

    @staticmethod
    def fake_architectures(_path: Path) -> list[str]:
        return ["arm64"]

    @staticmethod
    def make_bundle(bundle: Path, executable_name: str) -> None:
        bundle.mkdir(parents=True, exist_ok=True)
        with (bundle / "Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleExecutable": executable_name}, output)
        executable = bundle / executable_name
        executable.write_bytes(f"Mach-O:{executable_name}".encode())
        executable.chmod(executable.stat().st_mode | stat.S_IXUSR)

    def make_products(self, root: Path) -> tuple[Path, Path, Path, Path]:
        products = root / "source/Build/Products"
        debug_products = products / "Debug-iphonesimulator"
        app = debug_products / "AndBible.app"
        runner = debug_products / "AndBibleUITests-Runner.app"
        unit_test_bundle = app / "PlugIns/AndBibleTests.xctest"
        test_bundle = runner / "PlugIns/AndBibleUITests.xctest"
        self.make_bundle(app, "AndBible")
        self.make_bundle(unit_test_bundle, "AndBibleTests")
        self.make_bundle(runner, "AndBibleUITests-Runner")
        self.make_bundle(test_bundle, "AndBibleUITests")
        resource = app / "BibleView.bundle/index.html"
        resource.parent.mkdir(parents=True)
        resource.write_text("<main>reader</main>", encoding="utf-8")
        app_debug_dylib = app / "AndBible.debug.dylib"
        app_debug_dylib.write_bytes(b"Mach-O:app-debug-dylib")
        (debug_products / "current-app").symlink_to("AndBible.app")

        xctestrun = products / "AndBible_iphonesimulator26.2-arm64.xctestrun"
        with xctestrun.open("wb") as output:
            plistlib.dump(
                {
                    "AndBibleTests": {
                        "BlueprintName": "AndBibleTests",
                        "IsAppHostedTestBundle": True,
                        "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/AndBible.app",
                        "TestBundlePath": "__TESTHOST__/PlugIns/AndBibleTests.xctest",
                    },
                    "AndBibleUITests": {
                        "BlueprintName": "AndBibleUITests",
                        "IsUITestBundle": True,
                        "UITargetAppPath": "__TESTROOT__/Debug-iphonesimulator/AndBible.app",
                        "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/AndBibleUITests-Runner.app",
                        "TestBundlePath": "__TESTHOST__/PlugIns/AndBibleUITests.xctest",
                        "EnvironmentVariables": {
                            "PRODUCT_CONTRACT": "retained",
                            "UITEST_FIXTURE_SERVICE_DIRECTORY": "/private/tmp/expired-service",
                        },
                        "TestingEnvironmentVariables": {
                            "HOME": "/private/tmp/expired-home",
                            "PERFORMANCE_LIBRARY_SCALE": "10000",
                        },
                    },
                    "__xctestrun_metadata__": {"FormatVersion": 1},
                },
                output,
            )

        fixture = root / "source/.build/debug/UITestFixtureTool"
        fixture.parent.mkdir(parents=True)
        fixture.write_bytes(b"fixture-tool")
        fixture.chmod(fixture.stat().st_mode | stat.S_IXUSR)
        for bundle_name in ("AndBible_BibleCore.bundle", "AndBible_SwordKit.bundle"):
            resource = fixture.parent / bundle_name / "fixture-resource.txt"
            resource.parent.mkdir(parents=True)
            resource.write_text(bundle_name, encoding="utf-8")
        fixture_manifest = root / "source/Tests/UI/Fixtures/ui_test_fixture_manifest.json"
        fixture_manifest.parent.mkdir(parents=True)
        fixture_manifest.write_text('{"testExample": "baseline"}\n', encoding="utf-8")
        sword_fixture = root / "source/Sources/BibleUI/Tests/BibleUITests/Fixtures/sword"
        for relative_path in (
            "mods.d/kjv.conf",
            "modules/texts/ztext/kjv/nt.bzs",
            "modules/texts/ztext/kjv/nt.bzv",
            "modules/texts/ztext/kjv/nt.bzz",
            "modules/texts/ztext/kjv/ot.bzs",
            "modules/texts/ztext/kjv/ot.bzv",
            "modules/texts/ztext/kjv/ot.bzz",
            "ui-test-encrypted-rawtext/nt",
            "ui-test-encrypted-rawtext/nt.vss",
            "ui-test-encrypted-rawtext/ot",
            "ui-test-encrypted-rawtext/ot.vss",
        ):
            resource = sword_fixture / relative_path
            resource.parent.mkdir(parents=True, exist_ok=True)
            resource.write_text(relative_path, encoding="utf-8")
        return products, fixture, fixture_manifest, sword_fixture

    def package(self, root: Path) -> Path:
        products, fixture, fixture_manifest, sword_fixture = self.make_products(root)
        archive = root / "ui-test-products.tar.gz"
        package_products(
            products_path=products,
            fixture_tool=fixture,
            fixture_manifest=fixture_manifest,
            sword_fixture=sword_fixture,
            output_path=archive,
            commit_sha="abc123",
            configuration="Debug",
            code_signing_allowed="NO",
            provenance=PROVENANCE,
            architecture_reader=self.fake_architectures,
        )
        return archive

    def test_round_trip_verifies_resources_modes_symlinks_and_xctestrun(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = self.package(root)
            destination = root / "restored"
            destination.mkdir()

            xctestrun = verify_products(
                archive_path=archive,
                destination=destination,
                expected_commit_sha="abc123",
                expected_configuration="Debug",
                expected_code_signing_allowed="NO",
                provenance=PROVENANCE,
                architecture_reader=self.fake_architectures,
            )

            self.assertEqual(
                destination / ".derivedData/Build/Products/AndBible_iphonesimulator26.2-arm64.xctestrun",
                xctestrun,
            )
            self.assertEqual(
                "<main>reader</main>",
                (
                    destination
                    / ".derivedData/Build/Products/Debug-iphonesimulator/AndBible.app"
                    / "BibleView.bundle/index.html"
                ).read_text(encoding="utf-8"),
            )
            self.assertTrue(os.access(destination / ".build/debug/UITestFixtureTool", os.X_OK))
            self.assertEqual(
                "AndBible_BibleCore.bundle",
                (
                    destination
                    / ".build/debug/AndBible_BibleCore.bundle/fixture-resource.txt"
                ).read_text(encoding="utf-8"),
            )
            self.assertEqual(
                '{"testExample": "baseline"}\n',
                (destination / FIXTURE_MANIFEST_RELATIVE_PATH).read_text(encoding="utf-8"),
            )
            self.assertTrue(
                (destination / ".ui-test/fixtures/sword/mods.d/kjv.conf").is_file()
            )
            self.assertTrue(
                (
                    destination
                    / ".derivedData/Build/Products/Debug-iphonesimulator/current-app"
                ).is_symlink()
            )
            with xctestrun.open("rb") as source:
                restored_xctestrun = plistlib.load(source)
            restored_ui_target = restored_xctestrun["AndBibleUITests"]
            self.assertEqual(
                restored_ui_target["EnvironmentVariables"],
                {"PRODUCT_CONTRACT": "retained"},
            )
            self.assertEqual(restored_ui_target["TestingEnvironmentVariables"], {})

    def test_round_trip_supports_host_paths_with_double_underscores(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory) / "runner__workspace"
            root.mkdir()
            archive = self.package(root)
            destination = root / "restored__products"
            destination.mkdir()

            verify_products(
                archive_path=archive,
                destination=destination,
                expected_commit_sha="abc123",
                expected_configuration="Debug",
                expected_code_signing_allowed="NO",
                provenance=PROVENANCE,
                architecture_reader=self.fake_architectures,
            )

    def test_xctestrun_path_placeholders_are_validated_before_single_substitution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            products = Path(temporary_directory) / "products__TESTHOST__" / "Build/Products"
            expected = products / "Debug-iphonesimulator/AndBible.app"
            self.assertEqual(
                _resolve_xctestrun_product_path(
                    "__TESTROOT__/Debug-iphonesimulator/AndBible.app",
                    products_path=products,
                ),
                expected,
            )
            with self.assertRaisesRegex(ProductArchiveError, "Unsupported placeholder"):
                _resolve_xctestrun_product_path(
                    "__UNKNOWN__/AndBible.app",
                    products_path=products,
                )
            with self.assertRaisesRegex(ProductArchiveError, "escapes Build/Products"):
                _resolve_xctestrun_product_path(
                    "__TESTROOT__/../AndBible.app",
                    products_path=products,
                )

    def test_package_strips_runner_local_environment_without_mutating_producer(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            products, fixture, fixture_manifest, sword_fixture = self.make_products(root)
            producer_xctestrun = next(products.glob("*.xctestrun"))
            producer_bytes = producer_xctestrun.read_bytes()
            archive = root / "ui-test-products.tar.gz"

            package_products(
                products_path=products,
                fixture_tool=fixture,
                fixture_manifest=fixture_manifest,
                sword_fixture=sword_fixture,
                output_path=archive,
                commit_sha="abc123",
                configuration="Debug",
                code_signing_allowed="NO",
                provenance=PROVENANCE,
                architecture_reader=self.fake_architectures,
            )
            self.assertEqual(producer_xctestrun.read_bytes(), producer_bytes)

            destination = root / "restored"
            restored_xctestrun = verify_products(
                archive_path=archive,
                destination=destination,
                expected_commit_sha="abc123",
                expected_configuration="Debug",
                expected_code_signing_allowed="NO",
                provenance=PROVENANCE,
                architecture_reader=self.fake_architectures,
            )
            with restored_xctestrun.open("rb") as source:
                restored = plistlib.load(source)
            ui_target = restored["AndBibleUITests"]
            for environment_name in ("EnvironmentVariables", "TestingEnvironmentVariables"):
                self.assertTrue(
                    RUNNER_LOCAL_UI_TEST_ENVIRONMENT_KEYS.isdisjoint(
                        ui_target[environment_name]
                    )
                )

    def test_runner_local_environment_stripping_supports_format_two(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            xctestrun = Path(temporary_directory) / "FormatTwo.xctestrun"
            with xctestrun.open("wb") as output:
                plistlib.dump(
                    {
                        "TestConfigurations": [
                            {
                                "TestTargets": [
                                    {
                                        "BlueprintName": "AndBibleTests",
                                        "EnvironmentVariables": {"HOME": "host-contract"},
                                    },
                                    {
                                        "BlueprintName": "AndBibleUITests",
                                        "IsUITestBundle": True,
                                        "EnvironmentVariables": {
                                            "PRODUCT_CONTRACT": "retained",
                                            "UITEST_FIXTURE_SERVICE_DIRECTORY": "/expired",
                                        },
                                        "TestingEnvironmentVariables": {
                                            "UITEST_SIMULATOR_ID": "expired-simulator"
                                        },
                                    },
                                ]
                            }
                        ]
                    },
                    output,
                )

            removed = strip_runner_local_ui_test_environment(xctestrun)

            self.assertEqual(
                removed,
                {"HOME", "UITEST_FIXTURE_SERVICE_DIRECTORY", "UITEST_SIMULATOR_ID"},
            )
            with xctestrun.open("rb") as source:
                stripped = plistlib.load(source)
            unit_target, ui_target = stripped["TestConfigurations"][0]["TestTargets"]
            self.assertEqual(unit_target["EnvironmentVariables"], {})
            self.assertEqual(
                ui_target["EnvironmentVariables"],
                {"PRODUCT_CONTRACT": "retained"},
            )
            self.assertEqual(ui_target["TestingEnvironmentVariables"], {})

    def test_verify_rejects_different_commit_or_toolchain(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = self.package(root)
            destination = root / "restored"
            destination.mkdir()

            with self.assertRaisesRegex(ProductArchiveError, "commit_sha mismatch"):
                verify_products(
                    archive_path=archive,
                    destination=destination,
                    expected_commit_sha="different",
                    expected_configuration="Debug",
                    expected_code_signing_allowed="NO",
                    provenance=PROVENANCE,
                    architecture_reader=self.fake_architectures,
                )

            with self.assertRaisesRegex(ProductArchiveError, "toolchain mismatch"):
                verify_products(
                    archive_path=archive,
                    destination=root / "different-toolchain-restored",
                    expected_commit_sha="abc123",
                    expected_configuration="Debug",
                    expected_code_signing_allowed="NO",
                    provenance=ToolchainProvenance("different", "26.2", "arm64"),
                    architecture_reader=self.fake_architectures,
                )

    def test_verify_rejects_archive_link_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = root / "unsafe-link.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                member = tarfile.TarInfo(".derivedData/escaped")
                member.type = tarfile.SYMTYPE
                member.linkname = "../../outside"
                output.addfile(member)

            with self.assertRaisesRegex(ProductArchiveError, "Unsafe archive link target"):
                verify_products(
                    archive_path=archive,
                    destination=root / "restored",
                    expected_commit_sha="abc123",
                    expected_configuration="Debug",
                    expected_code_signing_allowed="NO",
                    provenance=PROVENANCE,
                    architecture_reader=self.fake_architectures,
                )

    def test_verify_rejects_payload_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = self.package(root)
            unpacked = root / "unpacked"
            unpacked.mkdir()
            with tarfile.open(archive, "r:gz") as source:
                source.extractall(unpacked)
            resource = (
                unpacked
                / ".derivedData/Build/Products/Debug-iphonesimulator/AndBible.app"
                / "BibleView.bundle/index.html"
            )
            resource.write_text("tampered", encoding="utf-8")
            tampered_archive = root / "tampered.tar.gz"
            with tarfile.open(tampered_archive, "w:gz") as output:
                for path in sorted(unpacked.iterdir()):
                    output.add(path, arcname=path.name)

            destination = root / "restored"
            destination.mkdir()
            with self.assertRaisesRegex(ProductArchiveError, "inventory does not match"):
                verify_products(
                    archive_path=tampered_archive,
                    destination=destination,
                    expected_commit_sha="abc123",
                    expected_configuration="Debug",
                    expected_code_signing_allowed="NO",
                    provenance=PROVENANCE,
                    architecture_reader=self.fake_architectures,
                )

    def test_verify_rejects_archive_path_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = root / "unsafe.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                member = tarfile.TarInfo("../escape")
                payload = b"bad"
                member.size = len(payload)
                output.addfile(member, io.BytesIO(payload))

            with self.assertRaisesRegex(ProductArchiveError, "Unsafe archive member path"):
                verify_products(
                    archive_path=archive,
                    destination=root / "restored",
                    expected_commit_sha="abc123",
                    expected_configuration="Debug",
                    expected_code_signing_allowed="NO",
                    provenance=PROVENANCE,
                    architecture_reader=self.fake_architectures,
                )

    def test_package_requires_complete_ui_product_graph(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            products, fixture, fixture_manifest, sword_fixture = self.make_products(root)
            (products / "Debug-iphonesimulator/AndBibleUITests-Runner.app").rename(
                products / "Debug-iphonesimulator/missing-runner"
            )

            with self.assertRaisesRegex(ProductArchiveError, "Built bundle is missing"):
                package_products(
                    products_path=products,
                    fixture_tool=fixture,
                    fixture_manifest=fixture_manifest,
                    sword_fixture=sword_fixture,
                    output_path=root / "archive.tar.gz",
                    commit_sha="abc123",
                    configuration="Debug",
                    code_signing_allowed="NO",
                    provenance=PROVENANCE,
                    architecture_reader=self.fake_architectures,
                )

    def test_package_requires_host_fixture_resource_bundles(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            products, fixture, fixture_manifest, sword_fixture = self.make_products(root)
            (fixture.parent / "AndBible_SwordKit.bundle").rename(
                fixture.parent / "missing-swordkit-resources"
            )

            with self.assertRaisesRegex(ProductArchiveError, "resource bundles are incomplete"):
                package_products(
                    products_path=products,
                    fixture_tool=fixture,
                    fixture_manifest=fixture_manifest,
                    sword_fixture=sword_fixture,
                    output_path=root / "archive.tar.gz",
                    commit_sha="abc123",
                    configuration="Debug",
                    code_signing_allowed="NO",
                    provenance=PROVENANCE,
                    architecture_reader=self.fake_architectures,
                )

    def test_package_requires_complete_sword_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            products, fixture, fixture_manifest, sword_fixture = self.make_products(root)
            (sword_fixture / "mods.d/kjv.conf").unlink()

            with self.assertRaisesRegex(ProductArchiveError, "SWORD fixture is incomplete"):
                package_products(
                    products_path=products,
                    fixture_tool=fixture,
                    fixture_manifest=fixture_manifest,
                    sword_fixture=sword_fixture,
                    output_path=root / "archive.tar.gz",
                    commit_sha="abc123",
                    configuration="Debug",
                    code_signing_allowed="NO",
                    provenance=PROVENANCE,
                    architecture_reader=self.fake_architectures,
                )

    def test_package_rejects_sword_module_payload_in_built_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            products, fixture, fixture_manifest, sword_fixture = self.make_products(root)
            app_sword = products / "Debug-iphonesimulator/AndBible.app/Resources/sword"
            (app_sword / "mods.d").mkdir(parents=True)
            (app_sword / "mods.d/kjv.conf").write_text("[KJV]\n", encoding="utf-8")
            payload = app_sword / "modules/texts/ztext/kjv/ot.bzs"
            payload.parent.mkdir(parents=True)
            payload.write_bytes(b"bundled scripture")

            with self.assertRaisesRegex(
                ProductArchiveError,
                "Built application bundles SWORD module payloads",
            ):
                package_products(
                    products_path=products,
                    fixture_tool=fixture,
                    fixture_manifest=fixture_manifest,
                    sword_fixture=sword_fixture,
                    output_path=root / "archive.tar.gz",
                    commit_sha="abc123",
                    configuration="Debug",
                    code_signing_allowed="NO",
                    provenance=PROVENANCE,
                    architecture_reader=self.fake_architectures,
                )

    def test_package_allows_non_sword_modules_and_app_host_plugin_fixtures(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            products, fixture, fixture_manifest, sword_fixture = self.make_products(root)
            app = products / "Debug-iphonesimulator/AndBible.app"
            unrelated = app / "Resources/modules/assets/catalog.json"
            unrelated.parent.mkdir(parents=True)
            unrelated.write_text("{}\n", encoding="utf-8")
            plugin_fixture = app / "PlugIns/AndBibleTests.xctest/Fixtures/sword/mods.d/kjv.conf"
            plugin_fixture.parent.mkdir(parents=True)
            plugin_fixture.write_text("[KJV]\n", encoding="utf-8")

            package_products(
                products_path=products,
                fixture_tool=fixture,
                fixture_manifest=fixture_manifest,
                sword_fixture=sword_fixture,
                output_path=root / "archive.tar.gz",
                commit_sha="abc123",
                configuration="Debug",
                code_signing_allowed="NO",
                provenance=PROVENANCE,
                architecture_reader=self.fake_architectures,
            )

    def test_verify_rejects_bundled_sword_payload_even_with_matching_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = self.package(root)
            unpacked = root / "unpacked"
            unpacked.mkdir()
            with tarfile.open(archive, "r:gz") as source:
                source.extractall(unpacked)
            app_sword = (
                unpacked
                / ".derivedData/Build/Products/Debug-iphonesimulator/AndBible.app/Resources/sword"
            )
            payload = app_sword / "modules/texts/ztext/kjv/ot.bzs"
            payload.parent.mkdir(parents=True)
            payload.write_bytes(b"bundled scripture")
            manifest_path = unpacked / "ui-test-products-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["payload"] = inventory_payload(unpacked)
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            tampered_archive = root / "bundled-sword.tar.gz"
            with tarfile.open(tampered_archive, "w:gz") as output:
                for path in sorted(unpacked.iterdir()):
                    output.add(path, arcname=path.name)

            with self.assertRaisesRegex(
                ProductArchiveError,
                "Built application bundles SWORD module payloads",
            ):
                verify_products(
                    archive_path=tampered_archive,
                    destination=root / "restored",
                    expected_commit_sha="abc123",
                    expected_configuration="Debug",
                    expected_code_signing_allowed="NO",
                    provenance=PROVENANCE,
                    architecture_reader=self.fake_architectures,
                )

    def test_verify_rejects_missing_bundled_fixture_manifest_without_repository_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = self.package(root)
            unpacked = root / "unpacked"
            unpacked.mkdir()
            with tarfile.open(archive, "r:gz") as source:
                source.extractall(unpacked)
            (unpacked / FIXTURE_MANIFEST_RELATIVE_PATH).unlink()
            tampered_archive = root / "missing-fixture-manifest.tar.gz"
            with tarfile.open(tampered_archive, "w:gz") as output:
                for path in sorted(unpacked.iterdir()):
                    output.add(path, arcname=path.name)

            with self.assertRaisesRegex(ProductArchiveError, "inventory does not match"):
                verify_products(
                    archive_path=tampered_archive,
                    destination=root / "restored",
                    expected_commit_sha="abc123",
                    expected_configuration="Debug",
                    expected_code_signing_allowed="NO",
                    provenance=PROVENANCE,
                    architecture_reader=self.fake_architectures,
                )

    def test_verify_rejects_macho_product_for_different_runner_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            products, fixture, fixture_manifest, sword_fixture = self.make_products(root)

            with self.assertRaisesRegex(ProductArchiveError, "do not support runner architecture"):
                package_products(
                    products_path=products,
                    fixture_tool=fixture,
                    fixture_manifest=fixture_manifest,
                    sword_fixture=sword_fixture,
                    output_path=root / "archive.tar.gz",
                    commit_sha="abc123",
                    configuration="Debug",
                    code_signing_allowed="NO",
                    provenance=ToolchainProvenance(
                        PROVENANCE.xcode_version,
                        PROVENANCE.simulator_sdk_version,
                        "x86_64",
                    ),
                    architecture_reader=self.fake_architectures,
                )

    def test_toolchain_provenance_uses_selected_xcode_sdk_and_architecture(self) -> None:
        commands: list[tuple[str, ...]] = []
        outputs = iter(("Xcode 26.3\nBuild version 17C529", "26.2", "arm64"))

        def fake_run(command: tuple[str, ...]) -> str:
            commands.append(command)
            return next(outputs)

        provenance = current_toolchain_provenance(fake_run)

        self.assertEqual(PROVENANCE, provenance)
        self.assertEqual(
            [
                ("xcodebuild", "-version"),
                ("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"),
                ("uname", "-m"),
            ],
            commands,
        )


if __name__ == "__main__":
    unittest.main()
