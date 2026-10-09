"""Exercise firewall transactions with fake OS tools and isolated file paths.

No commands touch the real firewall, system files, or launchd. These tests cover
control flow only. The macOS check script separately parses real PF syntax.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class NetworkTransactions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.log"
        self.env = dict(os.environ, MOCK_LOG=str(self.log))
        self.state = self.root / "var/db/macos-agent-network"
        self.pf = self.root / "etc/pf.conf"
        self.pf.parent.mkdir()
        (self.root / "etc/pf.anchors").mkdir()
        (self.root / "Library/LaunchDaemons").mkdir(parents=True)
        self.original = 'scrub-anchor "com.apple/*"\nanchor "com.apple/*"\n'
        self.pf.write_text(self.original)
        script = (Path(__file__).resolve().parents[1] / "lib/network.sh").read_text()
        for prefix in ["/var/db/", "/usr/local/", "/etc/", "/Library/", "/var/log/"]:
            script = script.replace(prefix, str(self.root) + prefix)
        script = script.replace(
            "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            f'export PATH="{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin"',
        )
        self.script = self.root / "network.sh"
        self.script.write_text(script)
        self.script.chmod(0o755)
        stub = f"#!{sys.executable}\n" + r'''
import os, pathlib, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["MOCK_LOG"], "a") as f:
    f.write(name + " " + " ".join(args) + "\n")
if name == "uname": print("Darwin")
elif name == "id": print("0")
elif name == "install":
    clean = []
    i = 0
    while i < len(args):
        if args[i] in ("-o", "-g"): i += 2
        else: clean.append(args[i]); i += 1
    sys.exit(subprocess.call(["/usr/bin/install"] + clean))
elif name == "pfctl":
    if args == ["-s", "info"]: print("Status: Enabled")
    fail = os.environ.get("MOCK_PF_FAILURE")
    if fail and args and args[0] == "-f" and pathlib.Path(fail).exists():
        pathlib.Path(fail).unlink()
        sys.exit(1)
elif name == "launchctl":
    if os.environ.get("MOCK_TIMER_FAILURE") and args[0] == "bootstrap" and "rollback.plist" in args[-1]:
        sys.exit(1)
'''
        for name in ["uname", "id", "install", "pfctl", "plutil", "launchctl", "sleep"]:
            path = self.bin / name
            path.write_text(stub)
            path.chmod(0o755)

    def run_action(self, *args, succeeds=True):
        result = subprocess.run(
            ["/bin/bash", str(self.script), *args],
            env=self.env, text=True, capture_output=True,
        )
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_watchdog_starts_before_rules_change_and_restores_snapshot(self):
        self.run_action("install", "192.0.2.53")
        self.assertTrue((self.state / "pending").exists())
        calls = self.log.read_text()
        self.assertLess(calls.index("launchctl bootstrap"), calls.index("pfctl -f "))
        self.assertIn('anchor "macos-agent"', self.pf.read_text())
        self.run_action("watch")
        self.assertEqual(self.pf.read_text(), self.original)
        self.assertFalse((self.state / "pending").exists())

    def test_confirmation_survives_watchdog_and_reapply_rollback(self):
        self.run_action("install", "192.0.2.53")
        self.run_action("confirm")
        confirmed = self.pf.read_text()
        self.run_action("watch")
        self.assertEqual(self.pf.read_text(), confirmed)
        self.run_action("install", "192.0.2.54")
        self.assertEqual(self.pf.read_text().count('anchor "macos-agent"\n'), 1)
        self.run_action("rollback")
        self.assertEqual(self.pf.read_text(), confirmed)
        anchor = self.root / "etc/pf.anchors/macos-agent"
        self.assertIn("192.0.2.53 port 53", anchor.read_text())

    def test_failed_timer_does_not_change_firewall(self):
        self.env["MOCK_TIMER_FAILURE"] = "1"
        self.run_action("install", "192.0.2.53", succeeds=False)
        self.assertEqual(self.pf.read_text(), self.original)
        self.assertFalse((self.state / "pending").exists())

    def test_apply_failure_triggers_immediate_restore(self):
        marker = self.root / "fail-once"
        marker.touch()
        self.env["MOCK_PF_FAILURE"] = str(marker)
        self.run_action("install", "192.0.2.53", succeeds=False)
        self.assertEqual(self.pf.read_text(), self.original)
        self.assertFalse((self.state / "pending").exists())

    def test_pending_change_cannot_be_overwritten(self):
        self.run_action("install", "192.0.2.53")
        self.run_action("install", "192.0.2.54", succeeds=False)
        self.run_action("rollback")
        self.assertEqual(self.pf.read_text(), self.original)


if __name__ == "__main__":
    unittest.main()
