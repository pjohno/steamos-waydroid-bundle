"""Offline regression tests for Release-backed targets.manifest."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BUILDER = (
    Path(__file__).resolve().parents[1] / "maintainer" / "rebuild-release-catalog.py"
)
ABI_A = "a" * 64
ABI_B = "b" * 64


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifests = self.root / "manifests"
        self.manifests.mkdir()
        self.rows = []

    def add(self, version, timestamp, target, abi, kernel, complete=True):
        archive = f"{version}.tar.gz"
        name = f"{version}.manifest"
        content = (
            f"format=1\nbundle_version={version}\narchive={archive}\n"
            f"sha256={'f' * 64}\nTARGET_ENVIRONMENT_ID={target}\n"
            f"ABI_SHA256={abi}\nKERNEL_RELEASE={kernel}\n"
        )
        (self.manifests / name).write_text(content)
        self.rows.append((name, timestamp, "200"))
        if complete:
            self.rows.extend(
                ((archive, timestamp, "5000"), (archive + ".sha256", timestamp, "100"))
            )

    def build(self, success=True):
        assets = self.root / "assets.tsv"
        assets.write_text("".join("\t".join(x) + "\n" for x in self.rows))
        output = self.root / "targets.manifest"
        result = subprocess.run(
            [
                sys.executable,
                str(BUILDER),
                "--assets",
                str(assets),
                "--manifests",
                str(self.manifests),
                "--output",
                str(output),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return output.read_text() if success else result.stderr

    def test_newer_preferred_same_target_abi_kernel_and_older_survives(self):
        self.add("old", "2026-08-04T16:40:42Z", "steamos-3.8-b1-abiaaaa", ABI_A, "6.1")
        self.add("new", "2026-10-21T09:16:06Z", "steamos-3.8-b1-abiaaaa", ABI_A, "6.1")
        self.add(
            "other", "2026-09-15T13:12:42Z", "steamos-3.9-b2-abibbbb", ABI_B, "6.2"
        )
        result = self.build()
        self.assertIn("target|steamos-3.8-b1-abiaaaa=new\n", result)
        self.assertIn("target-kernel|steamos-3.8-b1-abiaaaa|6.1=new\n", result)
        self.assertIn(f"abi-kernel|{ABI_A}|6.1=new\n", result)
        self.assertIn("target|steamos-3.9-b2-abibbbb=other\n", result)
        self.assertNotIn("=old\n", result)

    def test_multiple_kernels_preserve_kernel_specific_preference(self):
        self.add(
            "first", "2026-09-20T00:00:00Z", "steamos-3.8-b1-abiaaaa", ABI_A, "6.1"
        )
        self.add(
            "second", "2026-10-20T00:00:00Z", "steamos-3.8-b1-abiaaaa", ABI_A, "6.2"
        )
        result = self.build()
        self.assertIn("target-kernel|steamos-3.8-b1-abiaaaa|6.1=first\n", result)
        self.assertIn("target-kernel|steamos-3.8-b1-abiaaaa|6.2=second\n", result)
        self.assertIn("target|steamos-3.8-b1-abiaaaa=second\n", result)

    def test_incomplete_bundle_not_selected(self):
        self.add(
            "first", "2026-09-20T00:00:00Z", "steamos-3.8-b1-abiaaaa", ABI_A, "6.1"
        )
        self.add(
            "unfinished",
            "2026-10-20T00:00:00Z",
            "steamos-3.8-b1-abiaaaa",
            ABI_A,
            "6.1",
            False,
        )
        result = self.build()
        self.assertIn("target|steamos-3.8-b1-abiaaaa=first\n", result)
        self.assertNotIn("=unfinished\n", result)

    def test_refuses_bad_release_data(self):
        self.add("one", "2026-09-20T00:00:00Z", "steamos-3.8-b1-abiaaaa", ABI_A, "6.1")
        (self.manifests / "one.manifest").unlink()
        self.assertIn("not downloaded", self.build(False))


if __name__ == "__main__":
    unittest.main()
