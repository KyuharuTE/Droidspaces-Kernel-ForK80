"""Regression checks for configurations that previously produced bad builds."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("config_check", Path(__file__).with_name("check-kernel-config.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

BASE = "\n".join("CONFIG_" + name + "=y" for name in (
    "SYSVIPC", "IPC_NS", "PID_NS", "UTS_NS", "NAMESPACES", "DEVTMPFS",
    "CGROUPS", "CFI_CLANG", "SHADOW_CALL_STACK")) + "\n# CONFIG_MODULE_SIG is not set\n"


class ConfigTests(unittest.TestCase):
    def check_config(self, text):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / ".config"
            config.write_text(text)
            return checker.check(config)

    def test_boot_baseline_accepts_absent_experimental_symbols(self):
        self.assertEqual(self.check_config(BASE), [])

    def test_previous_failure_configurations_are_rejected(self):
        for symbol in ("CFI_CLANG", "SHADOW_CALL_STACK", "IPC_NS"):
            with self.subTest(symbol=symbol):
                errors = self.check_config(BASE.replace(f"CONFIG_{symbol}=y", f"# CONFIG_{symbol} is not set"))
                self.assertTrue(any(symbol in error for error in errors))
        for symbol in ("MODULE_SIG", "MODULE_SIG_PROTECT", "MODULE_SIG_FORCE", "KP_LKM", "KSU", "KSU_NEXT"):
            for value in ("y", "m"):
                with self.subTest(symbol=symbol, value=value):
                    errors = self.check_config(BASE + f"CONFIG_{symbol}={value}\n")
                    self.assertTrue(any(symbol in error for error in errors))


if __name__ == "__main__":
    unittest.main()
