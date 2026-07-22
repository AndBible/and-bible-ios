#!/usr/bin/env python3
"""Behavior tests for deterministic BibleView bundle packaging."""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from manage_bibleview_bundle import (
    BundleContractError,
    bundle_digest,
    compare_bundles,
    synchronize_bundle,
    validate_bundle,
    verify_archive_bundle,
)


class BibleViewBundleContractTests(unittest.TestCase):
    """Protects reproducible frontend resources from source drift and release leakage."""

    def write_bundle(self, root: Path, javascript: bytes, *, css: bytes = b"body{}") -> None:
        """Create a minimal generated bundle fixture with valid linked assets.

        The helper writes only beneath the test-owned temporary directory. Callers control the
        JavaScript bytes to exercise source-map and machine-path failures; filesystem errors fail the
        test directly and temporary-directory cleanup remains owned by the caller.
        """
        assets = root / "assets"
        assets.mkdir(parents=True)
        (assets / "main.js").write_bytes(javascript)
        (assets / "main.css").write_bytes(css)
        (root / "index.html").write_text(
            '<link rel="stylesheet" href="./assets/main.css">'
            '<script type="module" src="./assets/main.js"></script>',
            encoding="utf-8",
        )

    def test_production_bundle_rejects_source_maps_and_machine_paths(self) -> None:
        """Release validation must fail before debug metadata can enter an application archive."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "bundle"
            self.write_bundle(root, b"console.log('ok')")
            validate_bundle(root, "production")

            (root / "assets" / "main.js").write_bytes(b"//# sourceMappingURL=data:application/json")
            with self.assertRaisesRegex(BundleContractError, "production bundle contains a source map"):
                validate_bundle(root, "production")

            (root / "assets" / "main.js").write_bytes(b'__file="/Users/example/project/View.vue"')
            with self.assertRaisesRegex(BundleContractError, "machine-specific path"):
                validate_bundle(root, "production")

            (root / "assets" / "main.js").write_bytes(
                b'component.__file="/Volumes/build-agent/project/View.vue"'
            )
            with self.assertRaisesRegex(BundleContractError, "absolute Vue __file metadata"):
                validate_bundle(root, "production")

    def test_debug_bundle_requires_inline_map_but_remains_checkout_independent(self) -> None:
        """Debug diagnostics remain available without external maps or absolute checkout paths."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "bundle"
            self.write_bundle(root, b"//# sourceMappingURL=data:application/json;base64,e30=")
            validate_bundle(root, "debug")

            (root / "assets" / "main.js").write_bytes(
                b'component.__file="/Volumes/build-agent/project/View.vue";'
                b"//# sourceMappingURL=data:application/json;base64,e30="
            )
            with self.assertRaisesRegex(BundleContractError, "absolute Vue __file metadata"):
                validate_bundle(root, "debug")

            (root / "assets" / "main.js").write_bytes(b"console.log('missing map')")
            with self.assertRaisesRegex(BundleContractError, "does not contain an inline source map"):
                validate_bundle(root, "debug")

    def test_compare_and_digest_cover_paths_and_bytes(self) -> None:
        """Source/bundle drift detection must notice changed bytes and unexpected generated files."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            expected = root / "expected"
            actual = root / "actual"
            self.write_bundle(expected, b"console.log('same')")
            self.write_bundle(actual, b"console.log('same')")
            compare_bundles(expected, actual, "production")
            self.assertEqual(bundle_digest(expected), bundle_digest(actual))

            (actual / "assets" / "main.js").write_bytes(b"console.log('changed')")
            with self.assertRaisesRegex(BundleContractError, "bundle bytes differ"):
                compare_bundles(expected, actual, "production")

            (actual / "assets" / "main.js").write_bytes(b"console.log('same')")
            (actual / "assets" / "stale.js").write_bytes(b"stale")
            with self.assertRaisesRegex(BundleContractError, "bundle file set differs"):
                compare_bundles(expected, actual, "production")

    def test_sync_replaces_stale_destination_with_validated_tree(self) -> None:
        """Bundle synchronization removes stale hashed assets and publishes one complete tree."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            destination = root / "destination"
            self.write_bundle(source, b"console.log('new')")
            self.write_bundle(destination, b"console.log('old')")
            (destination / "assets" / "stale.js").write_bytes(b"stale")

            synchronize_bundle(source, destination, "production")

            compare_bundles(source, destination, "production")
            self.assertFalse((destination / "assets" / "stale.js").exists())

    def test_archive_verification_reads_the_single_swiftpm_resource_bundle(self) -> None:
        """Archive checks compare the embedded SwiftPM resource against the exact release build."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            expected = root / "expected"
            embedded = (
                root
                / "AndBible.xcarchive"
                / "Products"
                / "Applications"
                / "AndBible.app"
                / "BibleView_BibleView.bundle"
                / "bibleview-js"
            )
            self.write_bundle(expected, b"console.log('release')")
            self.write_bundle(embedded, b"console.log('release')")
            verify_archive_bundle(root / "AndBible.xcarchive", expected)

            (embedded / "assets" / "main.js").write_bytes(b"console.log('stale')")
            with self.assertRaisesRegex(BundleContractError, "bundle bytes differ"):
                verify_archive_bundle(root / "AndBible.xcarchive", expected)


if __name__ == "__main__":
    unittest.main()
