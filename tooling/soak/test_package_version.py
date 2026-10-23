import subprocess
import unittest
from unittest.mock import Mock

from tooling.soak.run_24h_matrix import SoakRunner


class PackageVersionTests(unittest.TestCase):
    def version(self, name, error=""):
        runner = object.__new__(SoakRunner)
        runner.shell = Mock(return_value=(subprocess.CompletedProcess(
            [], 0, f"versionCode=43139 minSdk=24\nversionName={name}\n"
        ), error))
        return runner.package_version()

    def test_numeric_versions_and_build_metadata_are_preserved(self):
        for name in ("1.0.127", "1.0.128-rc.1+qa", "v1.0.127"):
            self.assertEqual(self.version(name), {"version_name": name, "version_code": 43139})

    def test_malformed_or_oversized_names_are_not_partially_accepted(self):
        for name in ("", "1.0.127/secret", "a" * 65):
            self.assertEqual(self.version(name)["version_name"], "unknown")

    def test_observer_error_does_not_prove_an_app_version(self):
        self.assertEqual(self.version("1.0.127", error="observer_unavailable"),
                         {"version_name": "unknown", "version_code": -1})


if __name__ == "__main__":
    unittest.main()
