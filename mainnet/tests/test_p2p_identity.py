"""Offline persistent private-key lifecycle regression tests."""
import copy
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("identity", ROOT / "scripts/p2p-identity.py")
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)
# Public secp256k1 test vector, never an operational key.
ONE = b"0" * 63 + b"1"



class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.data = self.root / "l2reth"
        self.key = self.root / "l2reth-identity/discovery-secret"

    def write_key(self, path, raw=ONE):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        path.chmod(0o600)
        return path

    def config(self):
        return {"services": {"l2reth-node": {
            "volumes": [{"type": "bind", "source": str(self.data), "target": "/l2reth"},
                        {"type": "bind", "source": str(self.key), "target": identity.KEY_TARGET,
                         "read_only": True, "bind": {"create_host_path": False}}],
            "environment": {}
        }}}

    def test_generation_idempotence_and_permissions(self):
        first, _ = identity.initialize(self.key, self.data)
        self.assertEqual(identity.initialize(self.key, self.data)[0], first)
        self.assertEqual(identity.read_key(self.key), first)
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)

    def test_legacy_migration_preserves_identity_across_data_replacement(self):
        legacy = self.write_key(self.data / "discovery-secret", ONE + b"\n")
        self.assertEqual(identity.initialize(self.key, self.data)[0], ONE)
        self.assertEqual(legacy.read_bytes(), ONE + b"\n")
        # Restore/reset moves the old chain tree; a different snapshot has no key.
        self.data.rename(self.root / "l2reth.backup")
        self.data.mkdir()
        (self.data / "db").mkdir()
        self.assertEqual(identity.initialize(self.key, self.data)[0], ONE)
        self.assertEqual(identity.read_key(self.key), ONE)

    def test_import_normalizes_and_never_overwrites(self):
        source = self.write_key(self.root / "import", b"0x" + ONE + b"\n")
        identity.initialize(self.key, self.data, source)
        self.assertEqual(self.key.read_bytes(), ONE)
        source.write_bytes(b"0" * 63 + b"2")
        with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
            identity.initialize(self.key, self.data, source)
        self.assertEqual(self.key.read_bytes(), ONE)

    def test_existing_chain_without_identity_fails(self):
        self.data.mkdir()
        (self.data / "db").mkdir()
        with self.assertRaisesRegex(ValueError, "no automatic rotation"):
            identity.initialize(self.key, self.data)
        self.assertFalse(self.key.exists())

    def test_invalid_scalar_format_permissions_and_symlink(self):
        for raw in (b"0" * 64, f"{identity.ORDER:064x}".encode(), b"x" * 64, ONE + b"\n"):
            self.write_key(self.key, raw)
            with self.assertRaises(ValueError):
                identity.read_key(self.key)
        self.write_key(self.key).chmod(0o644)
        with self.assertRaisesRegex(ValueError, "permissions"):
            identity.read_key(self.key)
        self.key.unlink()
        source = self.write_key(self.root / "other")
        self.key.symlink_to(source)
        with self.assertRaises(ValueError):
            identity.read_key(self.key)

    def test_cli_init_without_network_addresses_preserves_key_and_keeps_it_private(self):
        # A new outbound-only node needs no advertised IP or egress declaration.
        output = io.StringIO()
        with patch("sys.argv", ["p2p-identity.py", "init"]), \
                patch.object(identity.subprocess, "check_output", return_value=json.dumps(self.config())), \
                contextlib.redirect_stdout(output):
            identity.main()
            first = identity.read_key(self.key)
            identity.main()
        self.assertEqual(identity.read_key(self.key), first)
        self.assertNotIn(first.decode(), output.getvalue())

    def test_compose_normalization_omits_false_create_host_path(self):
        cfg = self.config()
        cfg["services"]["l2reth-node"]["volumes"][1]["bind"] = {}
        self.assertEqual(identity.settings(cfg)[0], self.key)

    def test_reject_replaceable_paths_writable_mount_and_extra_overrides(self):
        cfg = self.config()
        for name in ("l2reth", "l1-interface", "dogecoin", ".snapshot-cache"):
            bad = copy.deepcopy(cfg)
            bad["services"]["l2reth-node"]["volumes"][1]["source"] = str(self.root / name / "key")
            with self.assertRaises(ValueError):
                identity.settings(bad)
        for field, value in (("read_only", False), ("bind", {"create_host_path": True})):
            bad = copy.deepcopy(cfg)
            bad["services"]["l2reth-node"]["volumes"][1][field] = value
            with self.assertRaises(ValueError):
                identity.settings(bad)
        for flag in ("--p2p-secret-key-hex=hidden", "--nat=none", "--port 1234", "--discovery.port=1234", "--instance=2", "--with-unused-ports"):
            cfg["services"]["l2reth-node"]["environment"]["L2RETH_EXTRA_ARGS"] = flag
            with self.assertRaises(ValueError):
                identity.settings(cfg)
