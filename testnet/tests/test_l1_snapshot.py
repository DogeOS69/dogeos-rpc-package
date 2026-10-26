"""Offline snapshot contract tests; no daemon, downloads, or live node data."""

import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import unittest

NETWORK_DIR = Path(__file__).resolve().parents[1]
NETWORK = NETWORK_DIR.name
spec = importlib.util.spec_from_file_location("validator", NETWORK_DIR / "scripts/validate-l1-snapshot.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="l1-snapshot-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "source/l1-interface"
        for name in (*validator.DATABASES, validator.HISTORY):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            conn = sqlite3.connect(path)
            conn.execute("CREATE TABLE fixture(value TEXT)")
            conn.execute("INSERT INTO fixture VALUES ('snapshot data')")
            conn.commit()
            conn.close()
        (self.source / "replay.artifacts/eth_da_artifacts").mkdir()
        self.history = hashlib.sha256((self.source / validator.HISTORY).read_bytes()).hexdigest()
        self.data = self.root / "data"
        self.config = {"services": {
            "l2reth-node": {"image": "fixture", "volumes": [
                {"type": "bind", "source": str(self.data / "l2reth"), "target": "/l2reth"}]},
            "l1-interface": {"image": "fixture", "environment": {
                **validator.FIXED_ENV,
                "DOGEOS_L1_INTERFACE_EVENT_PLANE_ARTIFACT_PATH": "/data/" + validator.HISTORY,
            }, "volumes": [{"type": "bind", "source": str(self.data / "l1-interface"), "target": "/data"}]},
            "l1-interface-init-fetch-sqlite": {"environment": {
                "DOGEOS_L1_INTERFACE_REPLAY_READ__SQLITE_PATH": "/data/replay.sqlite",
                "DOGEOS_L1_INTERFACE_EVENT_PLANE_ARTIFACT_PATH": "/data/" + validator.HISTORY,
                "ARTIFACT_URL": "https://example.invalid/history-" + self.history + ".sqlite",
            }, "volumes": [{"type": "bind", "source": str(self.data / "l1-interface"), "target": "/data"}]},
        }}

    def archive(self, extra=None):
        path = self.root / "snapshot.tar.gz"
        with tarfile.open(path, "w:gz") as out:
            out.add(self.source, arcname="l1-interface")
            if extra:
                info, data = extra
                out.addfile(info, io.BytesIO(data) if data else None)
        return path

    def test_valid_complete_snapshot(self):
        validator.validate_archive(self.archive(), self.history)
        validator.validate_extracted(self.source, self.history)

    def test_mainnet_history_is_optional(self):
        (self.source / validator.HISTORY).unlink()
        validator.validate_archive(self.archive(), "none")
        validator.validate_extracted(self.source, "none")

    def test_missing_files_rejected(self):
        for name in (*validator.DATABASES, validator.HISTORY):
            with self.subTest(name=name):
                path = self.source / name
                original = path.read_bytes()
                path.unlink()
                with self.assertRaises(ValueError):
                    validator.validate_archive(self.archive(), self.history)
                path.write_bytes(original)

    def test_missing_blob_directory_rejected(self):
        (self.source / "replay.artifacts/eth_da_artifacts").rmdir()
        with self.assertRaises(ValueError):
            validator.validate_archive(self.archive(), self.history)

    def test_invalid_archive_members(self):
        for name in ("l1-interface/replay.sqlite", "l1-interface/.env",
                     "l1-interface/l1-interface/replay.sqlite", "l1-interface/../outside",
                     "/outside", "l1-interface/replay.sqlite-wal",
                     "l1-interface/replay.artifacts/nested/password.env"):
            with self.subTest(name=name):
                info = tarfile.TarInfo(name)
                info.size = 1
                with self.assertRaises(ValueError):
                    validator.validate_archive(self.archive((info, b"x")), self.history)

    def test_links_and_special_members_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE):
            with self.subTest(kind=kind):
                info = tarfile.TarInfo("l1-interface/replay.artifacts/link")
                info.type = kind
                info.linkname = "/outside"
                with self.assertRaises(ValueError):
                    validator.validate_archive(self.archive((info, None)), self.history)

    def test_corrupt_sqlite_and_wrong_history_rejected(self):
        with self.assertRaises(ValueError):
            validator.validate_extracted(self.source, "0" * 64)
        (self.source / "replay.sqlite").write_bytes(b"not a SQLite database")
        with self.assertRaises(ValueError):
            validator.validate_extracted(self.source, self.history)

    def test_fixed_config(self):
        self.assertEqual(validator.validate_config(self.config, "testnet"), self.history)
        mainnet = copy.deepcopy(self.config)
        del mainnet["services"]["l1-interface"]["environment"]["DOGEOS_L1_INTERFACE_EVENT_PLANE_ARTIFACT_PATH"]
        self.assertEqual(validator.validate_config(mainnet, "mainnet"), "none")

    def test_changed_paths_rejected(self):
        for field in (*validator.FIXED_ENV, "DOGEOS_L1_INTERFACE_EVENT_PLANE_ARTIFACT_PATH"):
            with self.subTest(field=field):
                config = copy.deepcopy(self.config)
                config["services"]["l1-interface"]["environment"][field] = "/somewhere/else"
                with self.assertRaises(ValueError):
                    validator.validate_config(config, NETWORK)
        for target in ("/data", "/data/replay.sqlite"):
            config = copy.deepcopy(self.config)
            config["services"]["l1-interface"]["volumes"].append(
                {"type": "bind", "source": "/other", "target": target})
            with self.assertRaises(ValueError):
                validator.validate_config(config, NETWORK)
        config = copy.deepcopy(self.config)
        config["services"]["l1-interface"]["volumes"][0]["source"] = "/other"
        with self.assertRaises(ValueError):
            validator.validate_config(config, NETWORK)

    def test_entrypoint_rejects_legacy_path_overrides_before_writing(self):
        script = NETWORK_DIR / "scripts/l1-interface_entrypoint.sh"
        for field in (*validator.FIXED_ENV, "DOGEOS_L1_INTERFACE_EVENT_PLANE_ARTIFACT_PATH"):
            with self.subTest(field=field):
                env = dict(os.environ, **self.config["services"]["l1-interface"]["environment"])
                env[field] = "/invalid/custom/path"
                result = subprocess.run(["sh", str(script)], env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be", result.stderr)

    @unittest.skipUnless(NETWORK == "testnet", "only testnet has a bootstrap downloader")
    def test_bootstrap_rejects_partial_existing_data(self):
        # Execute the actual downloader prefix before it reaches any download.
        # Substitute only the fixed /data mount with a temporary test directory.
        import textwrap
        compose = (NETWORK_DIR / "docker-compose.yml").read_text()
        prefix = compose.split("        set -eu", 1)[1].split("        # --- Task 1:", 1)[0]
        script = "set -eu\n" + textwrap.dedent(prefix).replace("$$", "$")
        script = script.replace("/data/l1-interface.sqlite", str(self.source / "l1-interface.sqlite"))
        env = dict(os.environ, DOGEOS_L1_INTERFACE_REPLAY_READ__SQLITE_PATH=str(self.source / "replay.sqlite"))
        valid = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        (self.source / "replay.sqlite").unlink()
        partial = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)
        self.assertNotEqual(partial.returncode, 0)
        self.assertIn("Incomplete L1 data", partial.stderr)
        (self.source / "l1-interface.sqlite").unlink()
        fresh = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)
        self.assertEqual(fresh.returncode, 0, fresh.stderr)

    def restore(self, bad_sqlite=False, fail_stop=False, component="l1-interface", missing_key=False):
        package = self.root / "package" / NETWORK
        shutil.copytree(NETWORK_DIR / "scripts", package / "scripts")
        (package / ".env").write_text("# fixture; mocked Compose supplies resolved config\n")
        target = self.data / component
        target.mkdir(parents=True)
        (target / "original").write_text("keep me")
        if bad_sqlite:
            (self.source / "replay.sqlite").write_bytes(b"bad database")
        archive = self.archive()
        if component == "l2reth":
            with tarfile.open(archive, "w:gz") as out:
                for name in ("db/mdbx.dat", "db/scroll.db", "static_files/header"):
                    item = tarfile.TarInfo("l2reth/" + name)
                    item.size = 1
                    out.addfile(item, io.BytesIO(b"x"))
            key = self.data / "l2reth-identity/discovery-secret"
            if not missing_key:
                key.parent.mkdir()
                key.write_text("0" * 63 + "1")  # Public test vector only.
                key.chmod(0o600)
            self.config["services"]["l2reth-node"]["volumes"].append({
                "type": "bind", "source": str(key), "target": "/run/dogeos/l2reth-p2p.key",
                "read_only": True, "bind": {"create_host_path": False}})
        cache = self.data / ".snapshot-cache" / component
        cache.mkdir(parents=True)
        shutil.copyfile(archive, cache / archive.name)
        config_file = self.root / "config.json"
        config_file.write_text(json.dumps(self.config))
        bindir = self.root / "bin"
        bindir.mkdir()
        docker = bindir / "docker"
        docker.write_text("#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\n"
                          "if 'config' in sys.argv: print(Path(os.environ['TEST_CONFIG']).read_text())\n"
                          "elif 'stop' in sys.argv or 'down' in sys.argv:\n"
                          " Path(os.environ['TEST_STOP']).write_text(' '.join(sys.argv))\n"
                          " sys.exit(int(os.environ['TEST_FAIL_STOP']))\n"
                          "else: sys.exit('unexpected docker call: '+repr(sys.argv))\n")
        docker.chmod(0o755)
        for name in ("readlink", "stat", "df", "tar"):
            gnu = shutil.which("g" + name)
            if gnu:
                (bindir / name).symlink_to(gnu)
        stop_log = self.root / "stopped"
        env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"],
                   TEST_CONFIG=str(config_file), TEST_STOP=str(stop_log),
                   TEST_FAIL_STOP=str(int(fail_stop)), PYTHONDONTWRITEBYTECODE="1")
        for key in ("SNAPSHOT_INDEX_URL", "SNAPSHOT_CACHE_DIR"):
            env.pop(key, None)
        self.restore_env = env
        self.fixture_package = package
        result = subprocess.run([
            "bash", str(package / "scripts/restore-snapshot.sh"), "--no-start", "--force",
            "--snapshot-url", "https://example.invalid/" + archive.name,
            "--sha256", hashlib.sha256(archive.read_bytes()).hexdigest(), component,
        ], env=env, capture_output=True, text=True)
        return result, target, stop_log

    def test_l2_restore_and_reset_preserve_external_identity(self):
        result, target, stop_log = self.restore(component="l2reth")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        key = self.data / "l2reth-identity/discovery-secret"
        original = key.read_bytes()
        self.assertTrue((target / "db/mdbx.dat").is_file())
        reset = subprocess.run(["bash", str(self.fixture_package / "scripts/reset-chain-data.sh"),
                                "--delete", "--yes"], env=self.restore_env, capture_output=True, text=True)
        self.assertEqual(reset.returncode, 0, reset.stdout + reset.stderr)
        self.assertEqual(key.read_bytes(), original)
        self.assertFalse(any(target.iterdir()))

    def test_l2_restore_without_identity_stops_before_replacement(self):
        result, target, stop_log = self.restore(component="l2reth", missing_key=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("init first", result.stderr)
        self.assertFalse(stop_log.exists())
        self.assertEqual((target / "original").read_text(), "keep me")

    def test_restore_preserves_old_data_and_stops_dependents(self):
        result, target, stop_log = self.restore()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((target / "replay.sqlite").is_file())
        self.assertIn("stop l2reth-node l1-interface", stop_log.read_text())
        backups = list(self.data.glob("l1-interface.backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "original").read_text(), "keep me")

    def test_corrupt_data_does_not_stop_or_replace_services(self):
        result, target, stop_log = self.restore(bad_sqlite=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid SQLite header", result.stderr)
        self.assertFalse(stop_log.exists())
        self.assertEqual((target / "original").read_text(), "keep me")
        self.assertFalse(list(self.data.glob(".l1-interface-snapshot-restore-*")))

    def test_failed_stop_does_not_replace_data(self):
        result, target, stop_log = self.restore(fail_stop=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(stop_log.exists())
        self.assertEqual((target / "original").read_text(), "keep me")
        self.assertFalse(list(self.data.glob("l1-interface.backup-*")))


if __name__ == "__main__":
    unittest.main()
