"""Run the entrypoint offline and verify it gates the actual node process."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

NETWORK_DIR = Path(__file__).resolve().parents[1]


class StartupTests(unittest.TestCase):
    def run_startup(self, statuses, rpc_fail_first=False, custom_url=None, missing_key=False, overrides=None):
        with tempfile.TemporaryDirectory(prefix="l2-startup-test-") as tmp:
            root = Path(tmp)
            script = (NETWORK_DIR / "scripts/l2reth_entrypoint.sh").read_text()
            # Relocate only the container data directory for this host-side test.
            script = script.replace("DATA_DIR=/l2reth", f'DATA_DIR="{root}/data"', 1)
            script = script.replace("P2P_KEY_FILE=/run/dogeos/l2reth-p2p.key", f'P2P_KEY_FILE="{root}/key"', 1)
            if not missing_key:
                (root / "key").write_text("0" * 63 + "1")
            entrypoint = root / "entrypoint.sh"
            entrypoint.write_text(script)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            mocks = {
                "curl": '''#!/bin/sh
round=$(cat "$TEST_ROOT/round" 2>/dev/null || echo 0)
for arg do url=$arg; done
printf '%s %s\\n' "$round" "$url" >> "$TEST_ROOT/requests"
case "$url" in
  "$L2RETH_L1_ENDPOINT")
    if [ "$FAIL_RPC" = 1 ] && [ "$round" = 0 ]; then exit 7; fi
    echo '{"result":"0x1"}'
    ;;
  *)
    status=$(sed -n "$((round + 1))p" "$TEST_ROOT/statuses")
    case "$status" in
      timeout) printf 000; exit 28 ;;
      503) printf 503; exit 22 ;;
      *) printf '%s' "$status" ;;
    esac
    ;;
esac
''',
                "sleep": '''#!/bin/sh
round=$(cat "$TEST_ROOT/round" 2>/dev/null || echo 0)
round=$((round + 1))
printf '%s' "$round" > "$TEST_ROOT/round"
# Stop an otherwise endless wait without ever starting the node.
[ "$round" -lt "$MAX_ROUNDS" ] || exit 89
''',
                "rollup-node": '''#!/bin/sh
printf '%s\\n' "$@" > "$TEST_ROOT/argv"
cat "$TEST_ROOT/round" 2>/dev/null > "$TEST_ROOT/started" || echo 0 > "$TEST_ROOT/started"
''',
            }
            for name, content in mocks.items():
                path = bin_dir / name
                path.write_text(content)
                path.chmod(0o755)
            (root / "statuses").write_text("\n".join(statuses) + "\n")
            env = os.environ.copy()
            for key in list(env):
                if key.startswith("L2RETH_") or key == "L2GETH_PEER_LIST":
                    env.pop(key)
            env.update(PATH=f"{bin_dir}:{env['PATH']}", TEST_ROOT=str(root),
                       L2RETH_L1_ENDPOINT="http://rpc.example:8545",
                       L2RETH_BLOB_S3_URL="https://example.invalid/batches",
                       L2RETH_NETWORK_ID="1", FAIL_RPC=str(int(rpc_fail_first)),
                       MAX_ROUNDS=str(len(statuses)))
            if custom_url:
                env["L2RETH_L1_READY_URL"] = custom_url
            env.update(overrides or {})
            result = subprocess.run(["/bin/sh", str(entrypoint)], env=env,
                                    capture_output=True, text=True, timeout=5)
            self.argv = (root / "argv").read_text().splitlines() if (root / "argv").exists() else []
            self.output = result.stdout + result.stderr
            started = root / "started"
            return (result.returncode, started.read_text().strip() if started.exists() else None,
                    (root / "requests").read_text() if (root / "requests").exists() else "")

    def test_persistent_identity_and_advertised_port_arguments(self):
        code, started, _ = self.run_startup(["200"], overrides={
            "L2RETH_P2P_PORT": "31303", "L2RETH_P2P_PUBLIC_IP": "203.0.113.10"})
        self.assertEqual(code, 0, self.output)
        self.assertEqual(started, "0")
        for flag, value in (("--port", "31303"), ("--discovery.port", "31303"),
                            ("--nat", "extip:203.0.113.10")):
            self.assertEqual(self.argv[self.argv.index(flag) + 1], value)
        self.assertTrue(self.argv[self.argv.index("--p2p-secret-key") + 1].endswith("/key"))

    def test_missing_key_and_conflicting_override_prevent_launch(self):
        for options in ({"missing_key": True}, {"overrides": {"L2RETH_EXTRA_ARGS": "--port=31303"}}):
            code, started, requests = self.run_startup(["200"], **options)
            self.assertNotEqual(code, 0)
            self.assertIsNone(started)
            self.assertEqual(requests, "")

    def test_unready_timeout_and_redirect_wait_until_200(self):
        code, started, requests = self.run_startup(["503", "timeout", "302", "200"])
        self.assertEqual(code, 0)
        self.assertEqual(started, "3")
        self.assertEqual(requests.count("http://l1-interface:9090/api/v1/health/ready"), 4)
        self.assertEqual(requests.count("http://rpc.example:8545"), 4)

    def test_no_node_launch_while_unready(self):
        code, started, _ = self.run_startup(["503", "503"])
        self.assertEqual(code, 89)
        self.assertIsNone(started)

    def test_rpc_failure_still_blocks_and_custom_readiness_url_is_used(self):
        url = "http://custom-l1:9091/api/v1/health/ready"
        code, started, requests = self.run_startup(["200", "200"], True, url)
        self.assertEqual(code, 0)
        self.assertEqual(started, "1")
        self.assertNotIn("0 " + url, requests)
        self.assertIn("1 " + url, requests)
        self.assertNotIn("http://l1-interface:9090", requests)


if __name__ == "__main__":
    unittest.main()
