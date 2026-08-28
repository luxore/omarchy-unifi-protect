from __future__ import annotations

import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent


class ManifestTests(unittest.TestCase):
    def test_manifest_contract(self) -> None:
        manifest = json.loads((ROOT / "manifest.json").read_text())
        self.assertEqual(manifest["id"], "io.github.luxore.unifi-protect")
        self.assertEqual(manifest["kinds"], ["bar-widget"])
        self.assertEqual(manifest["entryPoints"]["barWidget"], "ProtectWidget.qml")
        self.assertTrue((ROOT / manifest["entryPoints"]["barWidget"]).is_file())
        self.assertNotIn("apiKey", json.dumps(manifest))


if __name__ == "__main__":
    unittest.main()
