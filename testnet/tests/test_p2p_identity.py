"""Offline identity lifecycle and public allowlist report regression tests."""
import copy
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("identity", ROOT / "scripts/p2p-identity.py")
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)
# Public secp256k1 test vector, never an operational key.
ONE = b"0" * 63 + b"1"
GENERATOR = ("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
             "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8")


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
            "environment": {"L2RETH_P2P_PUBLIC_IP": "203.0.113.10", "L2RETH_P2P_PORT": "31303",
                            "L2RETH_P2P_SOURCE_CIDRS": "198.51.100.20/32,198.51.100.0/24"},
            "ports": [{"target": 31303, "published": "31303", "protocol": x} for x in ("tcp", "udp")]
        }}}

    def test_generation_idempotence_and_permissions(self):
        first, _ = identity.initialize(self.key, self.data)
        self.assertEqual(identity.initialize(self.key, self.data)[0], first)
        self.assertEqual(identity.read_key(self.key), first)
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(identity.public_key(first)), 128)

    def test_legacy_migration_preserves_identity_across_data_replacement(self):
        legacy = self.write_key(self.data / "discovery-secret", ONE + b"\n")
        self.assertEqual(identity.initialize(self.key, self.data)[0], ONE)
        self.assertEqual(legacy.read_bytes(), ONE + b"\n")
        # Restore/reset moves the old chain tree; a different snapshot has no key.
        self.data.rename(self.root / "l2reth.backup")
        self.data.mkdir()
        (self.data / "db").mkdir()
        self.assertEqual(identity.initialize(self.key, self.data)[0], ONE)
        self.assertEqual(identity.public_key(identity.read_key(self.key)), GENERATOR)

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

    def test_known_public_key_and_nat_report(self):
        cfg = self.config()
        service = cfg["services"]["l2reth-node"]
        path, data, env = identity.settings(cfg)
        self.assertEqual((path, data), (self.key, self.data))
        report = identity.report(ONE, env, service)
        self.assertEqual(report["node_id"], GENERATOR)
        self.assertEqual(report["enode"], f"enode://{GENERATOR}@203.0.113.10:31303")
        self.assertEqual(report["source_cidrs"], ["198.51.100.20/32", "198.51.100.0/24"])
        self.assertEqual(set(report), {"network", "node_id", "enode", "source_cidrs"})

    def test_report_requires_ip_cidrs_and_matching_ports(self):
        service = self.config()["services"]["l2reth-node"]
        for key, value in (("L2RETH_P2P_PUBLIC_IP", ""), ("L2RETH_P2P_SOURCE_CIDRS", ""),
                           ("L2RETH_P2P_SOURCE_CIDRS", "198.51.100.20/24"), ("L2RETH_P2P_PORT", "30303")):
            env = dict(service["environment"], **{key: value})
            with self.assertRaises(ValueError):
                identity.report(ONE, env, service)
        service["ports"].pop()
        with self.assertRaises(ValueError):
            identity.report(ONE, service["environment"], service)

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
