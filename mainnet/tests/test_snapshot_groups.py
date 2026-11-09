"""Group pinning, missing components, startup ordering and failure boundaries."""
import copy
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
import tarfile
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("groups", ROOT / "scripts/snapshot-group.py")
groups = importlib.util.module_from_spec(spec)
spec.loader.exec_module(groups)


def manifest():
    def point(height):
        return {"height": height, "hash": "a" * 64}
    entries = {}
    for name, height, minute in (("dogecoin", 100, 5), ("l1-interface", 20, 2), ("l2reth", 10, 0)):
        entries[name] = {"id": name + "-one", "captured_at": f"2026-10-23T01:0{minute}:00Z",
                         "source_revision": "source-commit", "compatible_images": ["image:1"],
                         "checkpoint": point(height), "requires": {},
                         "archive": {"url": "https://example.invalid/" + name + ".tar.gz",
                                     "sha256": "b" * 64, "size_bytes": 100, "uncompressed_bytes": 200}}
    entries["l1-interface"]["requires"] = {"dogecoin": point(99)}
    entries["l1-interface"]["replay"] = {"validated_up_to": 10, "discovered_up_to": 10, "state_hash": "c" * 64}
    entries["l2reth"]["requires"] = {"l1-interface": point(19)}
    return {"schema_version": 2, "network": ROOT.name, "group_id": "one",
            "published_at": "2026-10-23T02:00:00Z",
            "identity": {"genesis_sha256": "d" * 64, "protocol_context_sha256": "e" * 64},
            "components": entries}


class FakeStack:
    def __init__(self, path):
        self.data = path
        self.state = path / ".snapshot-group-state.json"
        self.env_file = path / ".env"
        self.calls = []
        self.external_doge = ""
        self.height = 100
        self.ibd = False
        self.config = {"services": {name: {"image": "image:1"} for name in groups.SERVICES.values()}}
        self.doge_volume = ""
        self.existing_volumes = set()
        self.stale_volume = False
        self.containers = {}

    def volume_exists(self, name):
        return name in self.existing_volumes

    def doge_volume_stale(self):
        return self.stale_volume

    def identity(self):
        return manifest()["identity"]

    def container_state(self, service):
        return self.containers.get(service)

    preflight = groups.Stack.preflight

    def compose(self, *args):
        self.calls.append(args)

    def endpoint(self, port):
        return "http://l1:" + str(port)

    def doge(self, method, params=None):
        self.calls.append((method,))
        if method == "getblockchaininfo":
            return {"chain": "test" if ROOT.name == "testnet" else "main", "pruned": False,
                    "initialblockdownload": self.ibd, "blocks": self.height, "headers": 100}
        return "a" * 64


class GroupTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name)
        self.stack = FakeStack(self.path)

    def test_list_fetches_pinned_manifests_without_archives_or_stack_changes(self):
        group = manifest()
        group["components"]["dogecoin"] = None
        body = json.dumps(group)
        index = {"schema_version": 2, "network": ROOT.name,
                 "published_at": group["published_at"], "groups": [
                     {"id": "one", "published_at": group["published_at"], "manifest": {
                         "url": "https://example.invalid/one.json",
                         "sha256": groups.hashlib.sha256(body.encode()).hexdigest()}}]}
        urls = []
        def download(url, path):
            urls.append(url)
            value = index if url.endswith("index.json") else group
            path.write_text(json.dumps(value))
            return value
        output = io.StringIO()
        with patch.object(groups, "download_json", download), redirect_stdout(output):
            groups.load_group("https://example.invalid/index.json", None, self.path, self.stack)
        self.assertEqual(urls, ["https://example.invalid/index.json", "https://example.invalid/one.json"])
        self.assertEqual(self.stack.calls, [])
        self.assertFalse(self.stack.state.exists())
        for text in ("Compatibility: MATCH", "dogecoin: absent", "l2reth: height=10",
                     "captured=2026-10-23T01:00:00Z", "Total: download=200 B extracted=400 B",
                     "requires l1-interface: height=19", "compatible images: image:1"):
            self.assertIn(text, output.getvalue())
        index["groups"][0]["manifest"]["sha256"] = "0" * 64
        with patch.object(groups, "download_json", download), self.assertRaisesRegex(ValueError, "checksum"):
            groups.load_group("https://example.invalid/index.json", None, self.path, self.stack)

    def test_list_reports_unknown_and_incompatible_configuration(self):
        group = manifest()
        output = io.StringIO()
        with redirect_stdout(output):
            groups.print_group(group)
        self.assertIn("Compatibility: NOT CHECKED", output.getvalue())
        for reason in ("image", "identity", "external"):
            with self.subTest(reason=reason):
                item = copy.deepcopy(group)
                if reason == "image":
                    item["components"]["l2reth"]["compatible_images"] = ["image:2"]
                elif reason == "identity":
                    item["identity"]["genesis_sha256"] = "0" * 64
                else:
                    self.stack.external_doge = "http://external:1234"
                output = io.StringIO()
                with redirect_stdout(output):
                    groups.print_group(item, self.stack)
                self.assertIn("Compatibility: INCOMPATIBLE", output.getvalue())
                self.assertNotIn("Compatibility: MATCH", output.getvalue())

    def test_list_cli_checks_local_config_only_when_env_supplied_or_present(self):
        with patch.object(groups, "ROOT", self.path), patch.object(groups, "load_group") as load, \
                patch.object(groups, "Stack", return_value=self.stack) as stack, \
                patch.object(groups.sys, "argv", ["snapshot-group.py", "list"]):
            groups.main()
            stack.assert_not_called()
            self.assertIsNone(load.call_args.args[3])
            (self.path / ".env").touch()
            groups.main()
            stack.assert_called_once_with(None)
            self.assertIs(load.call_args.args[3], self.stack)
        with patch.object(groups, "load_group") as load, \
                patch.object(groups, "Stack", return_value=self.stack) as stack, \
                patch.object(groups.sys, "argv", ["snapshot-group.py", "list", "--env-file", "custom.env"]):
            groups.main()
            stack.assert_called_once_with("custom.env")
            self.assertIs(load.call_args.args[3], self.stack)

    def test_group_catalog_has_its_own_url_and_override(self):
        # <network>/index.json stays the schema-1 component index of
        # restore-snapshot.sh; groups are read from group-index.json.
        expected = groups.INDEX_BASE + "/" + ROOT.name + "/group-index.json"
        self.assertEqual(groups.GROUP_INDEX_URL, expected)
        base = {k: v for k, v in os.environ.items() if not k.startswith("SNAPSHOT_")}
        for extra, url in (({}, expected),
                           ({"SNAPSHOT_GROUP_INDEX_URL": "https://mirror.invalid/g.json"}, "https://mirror.invalid/g.json"),
                           # The component-index override must not redirect group selection.
                           ({"SNAPSHOT_INDEX_URL": "https://mirror.invalid/component.json"}, expected)):
            with self.subTest(env=extra), patch.dict(os.environ, {**base, **extra}, clear=True), \
                    patch.object(groups, "ROOT", self.path), patch.object(groups, "load_group") as load, \
                    patch.object(groups.sys, "argv", ["snapshot-group.py", "list"]):
                groups.main()
                self.assertEqual(load.call_args.args[0], url)

    def test_component_index_and_missing_catalog_are_explained(self):
        component_index = {"schema_version": 1, "network": ROOT.name,
                           "published_at": "2026-10-20T14:37:22Z", "components": {}}
        with self.assertRaisesRegex(ValueError, "schema-1 component index.*restore-snapshot.sh"):
            groups.validate_index(component_index, ROOT.name)
        unreachable = subprocess.CalledProcessError(22, ["curl"])
        with patch.object(groups, "download_json", side_effect=unreachable), \
                self.assertRaisesRegex(ValueError, "cannot download the snapshot group catalog") as raised:
            groups.load_group("https://mirror.invalid/secret-token/group-index.json", None, self.path)
        self.assertNotIn("secret-token", str(raised.exception))

    def test_full_partial_and_empty_groups(self):
        group = manifest()
        groups.validate_manifest(group, ROOT.name)
        for name in groups.COMPONENTS:
            group["components"][name] = None
            groups.validate_manifest(group, ROOT.name)
        del group["components"]["dogecoin"]
        with self.assertRaises(ValueError):
            groups.validate_manifest(group, ROOT.name)

    def test_invalid_metadata_rejected(self):
        for mutate in (
            lambda g: g.update(network="other"),
            lambda g: g["identity"].update(genesis_sha256="bad"),
            lambda g: g["components"]["l2reth"]["archive"].update(size_bytes=0),
            lambda g: g["components"]["l2reth"]["requires"].clear(),
            lambda g: g["components"]["l2reth"]["requires"].update({"l1-interface": {"height": 20, "hash": "f" * 64}}),
        ):
            group = manifest()
            mutate(group)
            with self.assertRaises(ValueError):
                groups.validate_manifest(group, ROOT.name)

    def test_older_upstream_allowed_but_gate_waits(self):
        group = manifest()
        group["components"]["dogecoin"]["checkpoint"]["height"] = 90
        groups.validate_manifest(group, ROOT.name)
        with self.assertRaises(groups.Pending):
            groups.check_points(groups.requirements(group, "dogecoin"), 90, lambda h: "a" * 64)

    def test_hash_mismatch_stops_instead_of_waiting(self):
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            groups.check_points([{"height": 10, "hash": "a" * 64}], 20, lambda h: "b" * 64)

    def test_index_group_ids_unique(self):
        item = {"id": "one", "published_at": manifest()["published_at"],
                "manifest": {"url": "https://example.invalid/one.json", "sha256": "a" * 64}}
        index = {"schema_version": 2, "network": ROOT.name, "published_at": item["published_at"], "groups": [item, item]}
        with self.assertRaisesRegex(ValueError, "duplicate"):
            groups.validate_index(index, ROOT.name)

    def test_manifest_pinned_to_index_checksum(self):
        group = manifest()
        body = json.dumps(group)
        index = {"schema_version": 2, "network": ROOT.name, "published_at": group["published_at"],
                 "groups": [{"id": "one", "published_at": group["published_at"],
                             "manifest": {"url": "https://example.invalid/one.json",
                                          "sha256": groups.hashlib.sha256(body.encode()).hexdigest()}}]}
        calls = []
        def download(url, path):
            calls.append(url)
            value = index if len(calls) == 1 else group
            path.write_text(json.dumps(value))
            return value
        with patch.object(groups, "download_json", download):
            result = groups.load_group("https://example.invalid/index.json", "one", self.path)
        self.assertEqual(result, group)
        self.assertEqual(len(calls), 2)
        index["groups"][0]["manifest"]["sha256"] = "0" * 64
        calls.clear()
        with patch.object(groups, "download_json", download), self.assertRaisesRegex(ValueError, "checksum"):
            groups.load_group("https://example.invalid/index.json", "one", self.path)

    def test_partial_restore_does_not_fetch_missing_component(self):
        group = manifest()
        group["components"]["l1-interface"] = None
        with patch.object(groups.subprocess, "run") as run:
            groups.restore(self.stack, group, False, True)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual([c[-2] for c in commands], ["dogecoin", "l2reth"])
        self.assertTrue(all("--no-start" in c for c in commands))
        self.assertEqual(json.loads(self.stack.state.read_text())["status"], "complete")
        self.assertFalse(any(c[0] == "up" for c in self.stack.calls))

    def test_group_runs_real_component_restore_with_pinned_metadata(self):
        from test_l1_snapshot import SnapshotTests
        fixture = SnapshotTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        first, target, stop_log = fixture.restore()
        self.assertEqual(first.returncode, 0, first.stderr)
        stack = FakeStack(fixture.data)
        package = fixture.root / "package" / ROOT.name
        stack.env_file = package / ".env"
        stack.config["services"]["l1-interface"]["image"] = "fixture"
        group = manifest()
        group["components"]["dogecoin"] = None
        group["components"]["l2reth"] = None
        entry = group["components"]["l1-interface"]
        entry["compatible_images"] = ["fixture"]
        archive = fixture.data / ".snapshot-cache/l1-interface/snapshot.tar.gz"
        with tarfile.open(archive) as content:
            extracted_size = sum(m.size for m in content)
        entry["archive"] = {"url": "https://example.invalid/snapshot.tar.gz",
                            "sha256": groups.sha(archive), "size_bytes": archive.stat().st_size,
                            "uncompressed_bytes": extracted_size}
        env = dict(PATH=str(fixture.root / "bin") + os.pathsep + os.environ["PATH"],
                   TEST_CONFIG=str(fixture.root / "config.json"), TEST_STOP=str(stop_log),
                   TEST_FAIL_STOP="0", PYTHONDONTWRITEBYTECODE="1")
        with patch.object(groups, "ROOT", package), patch.dict(os.environ, env):
            groups.restore(stack, group, True, True)
        self.assertTrue((target / "replay.sqlite").exists())
        state = json.loads(stack.state.read_text())
        self.assertEqual(state["applied"], ["l1-interface"])
        self.assertEqual(state["status"], "complete")

    def test_failed_restore_blocks_start_and_different_group(self):
        with patch.object(groups.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["restore"])):
            with self.assertRaises(subprocess.CalledProcessError):
                groups.restore(self.stack, manifest(), False, False)
        with self.assertRaisesRegex(ValueError, "interrupted"):
            groups.start(self.stack)
        other = manifest()
        other["group_id"] = "different"
        with self.assertRaisesRegex(ValueError, "same immutable"):
            groups.restore(self.stack, other, True, True)
        self.assertFalse(any(c[0] == "up" for c in self.stack.calls))

    def test_retained_live_downstream_cannot_use_stale_receipt(self):
        (self.path / "l2reth").mkdir()
        (self.path / "l2reth/data").write_text("progressed beyond original snapshot")
        groups.atomic_json(self.stack.state, {"status": "complete", "effective_manifest": manifest()})
        group = manifest()
        group["group_id"] = "new"
        group["components"]["l2reth"] = None
        with self.assertRaisesRegex(ValueError, "unknown current dependencies"):
            groups.restore(self.stack, group, True, True)
        self.assertFalse(self.stack.calls)

    def test_resume_uses_pinned_manifest_and_skips_completed_components(self):
        with patch.object(groups.subprocess, "run", side_effect=[None, subprocess.CalledProcessError(1, ["restore"])]) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                groups.restore(self.stack, manifest(), False, True)
        with patch.object(groups, "load_group", side_effect=AssertionError("must not fetch a new catalog")):
            pinned = groups.resolve_restore_group(self.stack, "one", "unused", self.path)
        with patch.object(groups.subprocess, "run") as run:
            groups.restore(self.stack, pinned, True, True)
        self.assertEqual([c.args[0][-2] for c in run.call_args_list], ["l1-interface", "l2reth"])
        self.assertEqual(json.loads(self.stack.state.read_text())["applied"], list(groups.COMPONENTS))

    def test_force_required_before_stop_or_journal(self):
        (self.path / "l2reth").mkdir()
        (self.path / "l2reth/data").write_text("existing")
        with self.assertRaisesRegex(ValueError, "--force"):
            groups.restore(self.stack, manifest(), False, True)
        self.assertFalse(self.stack.calls)
        self.assertFalse(self.stack.state.exists())

    def test_same_group_id_cannot_change(self):
        with patch.object(groups.subprocess, "run"):
            groups.restore(self.stack, manifest(), False, True)
        changed = manifest()
        changed["components"]["dogecoin"]["archive"]["sha256"] = "f" * 64
        with self.assertRaisesRegex(ValueError, "republished"):
            groups.restore(self.stack, changed, True, True)

    def test_start_waits_for_doge_then_l1_then_l2(self):
        self.stack.ibd = True
        health_attempts = []
        def health(url):
            health_attempts.append(url)
            if url.endswith("/health"):
                return {"historical_sync": "completed"}
            return {"ready": True}
        def rpc(url, method, params=None):
            return "0x14" if method == "eth_blockNumber" else {"hash": "0x" + "a" * 64}
        def sleep(_):
            self.assertNotIn(("up", "-d", "l1-interface"), self.stack.calls)
            self.assertFalse(health_attempts)
            self.stack.ibd = False
        with patch.object(groups.time, "sleep", sleep), patch.object(groups, "http_json", health), patch.object(groups, "rpc", rpc):
            groups.start(self.stack, manifest())
        calls = self.stack.calls
        self.assertLess(calls.index(("up", "-d", "dogecoin-node")), calls.index(("up", "-d", "l1-interface")))
        self.assertEqual(calls[-1], ("up", "-d", "--no-deps", "l2reth-node"))

    def test_crash_looping_upstream_is_reported_while_waiting(self):
        self.stack.ibd = True
        self.stack.containers = {"dogecoin-node": (2, "running"), "l1-interface": (0, "running")}
        attempts = []
        def sleep(_):
            attempts.append(1)
            if len(attempts) == 1:
                self.stack.containers["dogecoin-node"] = (3, "restarting")
            else:
                self.stack.ibd = False
        def health(url):
            return {"historical_sync": "completed", "ready": True}
        def rpc(url, method, params=None):
            return "0x14" if method == "eth_blockNumber" else {"hash": "0x" + "a" * 64}
        output = io.StringIO()
        with patch.object(groups.time, "sleep", sleep), patch.object(groups, "http_json", health), \
                patch.object(groups, "rpc", rpc), redirect_stdout(output):
            groups.start(self.stack, manifest())
        lines = [line for line in output.getvalue().splitlines() if "WARNING" in line]
        # Restarts before this start are not counted; a stable container gets no warning.
        self.assertEqual(len(lines), 1)
        self.assertIn("dogecoin-node container is restarting, restarted 1 time(s) during this wait", lines[0])
        self.assertIn("DOGECOIN_MEM_LIMIT", lines[0])

    def test_container_state_never_raises(self):
        stack = groups.Stack.__new__(groups.Stack)
        stack.command = ["docker", "compose"]
        with patch.object(groups.subprocess, "run", side_effect=OSError("no docker")):
            self.assertIsNone(stack.container_state("dogecoin-node"))
        replies = [subprocess.CompletedProcess([], 0, stdout="0123abcd\n"),
                   subprocess.CompletedProcess([], 0, stdout="4 restarting\n")]
        with patch.object(groups.subprocess, "run", side_effect=replies):
            self.assertEqual(stack.container_state("dogecoin-node"), (4, "restarting"))

    def test_l1_readiness_failure_keeps_l2_stopped(self):
        ready = [False]
        def health(url):
            return {"historical_sync": "completed"} if url.endswith("/health") else {"ready": ready[0]}
        def sleep(_):
            self.assertNotIn(("up", "-d", "--no-deps", "l2reth-node"), self.stack.calls)
            ready[0] = True
        def rpc(url, method, params=None):
            return "0x14" if method == "eth_blockNumber" else {"hash": "0x" + "a" * 64}
        with patch.object(groups, "http_json", health), patch.object(groups, "rpc", rpc), patch.object(groups.time, "sleep", sleep):
            groups.start(self.stack, manifest())
        self.assertEqual(self.stack.calls[-1], ("up", "-d", "--no-deps", "l2reth-node"))

    def test_l1_hash_mismatch_never_starts_l2(self):
        def health(url):
            return {"historical_sync": "completed", "ready": True}
        def rpc(url, method, params=None):
            return "0x14" if method == "eth_blockNumber" else {"hash": "0x" + "b" * 64}
        with patch.object(groups, "http_json", health), patch.object(groups, "rpc", rpc):
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                groups.start(self.stack, manifest())
        self.assertNotIn(("up", "-d", "--no-deps", "l2reth-node"), self.stack.calls)

    def upgrade_package(self):
        # A later release changes service images and genesis fork settings.
        for service in self.stack.config["services"].values():
            service["image"] = "image:2"
        self.stack.identity = lambda: {"genesis_sha256": "f" * 64, "protocol_context_sha256": "e" * 64}

    def test_start_after_package_upgrade_keeps_checkpoint_gates(self):
        groups.atomic_json(self.stack.state, {"status": "complete", "effective_manifest": manifest()})
        self.upgrade_package()
        def health(url):
            return {"historical_sync": "completed", "ready": True}
        def same_chain(url, method, params=None):
            return "0x14" if method == "eth_blockNumber" else {"hash": "0x" + "a" * 64}
        def other_chain(url, method, params=None):
            return "0x14" if method == "eth_blockNumber" else {"hash": "0x" + "b" * 64}
        with patch.object(groups, "http_json", health), patch.object(groups, "rpc", same_chain):
            groups.start(self.stack)
        self.assertEqual(self.stack.calls[-1], ("up", "-d", "--no-deps", "l2reth-node"))
        # The saved checkpoints are still enforced after the upgrade.
        self.stack.calls.clear()
        with patch.object(groups, "http_json", health), patch.object(groups, "rpc", other_chain):
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                groups.start(self.stack)
        self.assertNotIn(("up", "-d", "--no-deps", "l2reth-node"), self.stack.calls)

    def test_partial_restore_retains_checkpoints_recorded_before_upgrade(self):
        old = manifest()
        groups.atomic_json(self.stack.state, {"status": "complete", "effective_manifest": old})
        self.upgrade_package()
        group = manifest()
        group["group_id"] = "l2-only"
        group["identity"] = self.stack.identity()
        group["components"]["dogecoin"] = None
        group["components"]["l1-interface"] = None
        group["components"]["l2reth"]["compatible_images"] = ["image:2"]
        with patch.object(groups.subprocess, "run") as run:
            groups.restore(self.stack, group, True, True)
        self.assertEqual([c.args[0][-2] for c in run.call_args_list], ["l2reth"])
        effective = json.loads(self.stack.state.read_text())["effective_manifest"]
        self.assertEqual(effective["identity"], group["identity"])
        self.assertEqual(effective["components"]["dogecoin"], old["components"]["dogecoin"])
        self.assertEqual(effective["components"]["l1-interface"], old["components"]["l1-interface"])
        # A new group must still match the current package.
        incompatible = copy.deepcopy(group)
        incompatible["group_id"] = "old-image"
        incompatible["components"]["l2reth"]["compatible_images"] = ["image:1"]
        with self.assertRaisesRegex(ValueError, "image incompatible"):
            groups.restore(self.stack, incompatible, True, True)

    def test_dogecoin_volume_name_from_config(self):
        volume = {"services": {"dogecoin-node": {"volumes": [
                      {"type": "volume", "source": "dogecoin_data", "target": "/data"}]}},
                  "volumes": {"dogecoin_data": {"name": "custom_dogecoin_data"}}}
        self.assertEqual(groups.dogecoin_volume(volume), "custom_dogecoin_data")
        bind = {"services": {"dogecoin-node": {"volumes": [
                    {"type": "bind", "source": "/srv/data/dogecoin", "target": "/data"}]}}}
        self.assertEqual(groups.dogecoin_volume(bind), "")

    def test_existing_dogecoin_volume_rejected_before_stop_or_journal(self):
        self.stack.doge_volume = "dogeos-rpc-package_dogecoin_data"
        self.stack.existing_volumes.add(self.stack.doge_volume)
        # --force never replaces a Docker volume, so it does not bypass the check.
        with self.assertRaisesRegex(ValueError, "DOGECOIN_VOLUME_NAME"):
            groups.restore(self.stack, manifest(), True, True)
        self.assertFalse(self.stack.calls)
        self.assertFalse(self.stack.state.exists())
        # Retaining the populated volume (a group without Dogecoin) is allowed.
        group = manifest()
        group["components"]["dogecoin"] = None
        with patch.object(groups.subprocess, "run") as run:
            groups.restore(self.stack, group, True, True)
        self.assertEqual([c.args[0][-2] for c in run.call_args_list], ["l1-interface", "l2reth"])

    def test_l2_genesis_mountpoint_is_not_chain_data(self):
        # Docker creates this mountpoint when the l2reth container starts.
        (self.path / "l2reth/genesis").mkdir(parents=True)
        (self.path / "l2reth/genesis/genesis.json").touch()
        l1_only = manifest()
        l1_only["components"]["dogecoin"] = None
        l1_only["components"]["l2reth"] = None
        with patch.object(groups.subprocess, "run") as run:
            groups.restore(self.stack, l1_only, False, True)
        self.assertEqual([c.args[0][-2] for c in run.call_args_list], ["l1-interface"])
        # Real chain data still counts.
        (self.path / "l2reth/db").mkdir()
        other = manifest()
        other["group_id"] = "with-l2"
        with self.assertRaisesRegex(ValueError, "--force"):
            groups.restore(self.stack, other, False, True)

    def test_concurrent_run_names_the_lock(self):
        lock_path = self.path / ".snapshot-group.lock"
        with lock_path.open("a") as held:
            groups.fcntl.flock(held, groups.fcntl.LOCK_EX | groups.fcntl.LOCK_NB)
            with patch.object(groups, "Stack", return_value=self.stack), \
                    patch.object(groups.subprocess, "run"), \
                    patch.object(groups.sys, "argv", ["snapshot-group.py", "start"]):
                with self.assertRaisesRegex(ValueError, "another snapshot-group.py .* is running"):
                    groups.main()
        self.assertFalse(self.stack.calls)

    def test_start_recreates_dogecoin_attached_to_another_volume(self):
        self.stack.stale_volume = True
        def health(url):
            return {"historical_sync": "completed", "ready": True}
        def rpc(url, method, params=None):
            return "0x14" if method == "eth_blockNumber" else {"hash": "0x" + "a" * 64}
        with patch.object(groups, "http_json", health), patch.object(groups, "rpc", rpc):
            groups.start(self.stack, manifest())
        self.assertIn(("up", "-d", "--force-recreate", "dogecoin-node"), self.stack.calls)
        self.assertNotIn(("up", "-d", "dogecoin-node"), self.stack.calls)

    def test_doge_volume_stale_compares_container_mount(self):
        stack = groups.Stack.__new__(groups.Stack)
        stack.command = ["docker", "compose"]
        stack.doge_volume = "new_dogecoin_data"
        def mounts(name):
            return json.dumps([{"Type": "bind", "Destination": "/entrypoint.sh"},
                               {"Type": "volume", "Name": name, "Destination": "/data"}])
        listed = subprocess.CompletedProcess([], 0, stdout="0123abcd\n")
        for mounted, stale in (("old_dogecoin_data", True), ("new_dogecoin_data", False)):
            with patch.object(groups.subprocess, "run", return_value=listed), \
                    patch.object(groups.subprocess, "check_output", return_value=mounts(mounted)) as inspect:
                self.assertIs(stack.doge_volume_stale(), stale)
            self.assertEqual(inspect.call_args.args[0][-1], "0123abcd")
        # No container yet, or a bind-mounted data directory: nothing to recreate.
        with patch.object(groups.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="")):
            self.assertFalse(stack.doge_volume_stale())
        stack.doge_volume = ""
        with patch.object(groups.subprocess, "run", side_effect=AssertionError("no docker call")):
            self.assertFalse(stack.doge_volume_stale())


if __name__ == "__main__":
    unittest.main()
