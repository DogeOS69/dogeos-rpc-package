import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("data_archive", ROOT / "scripts/validate-data-archive.py")
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


class ArchiveTests(unittest.TestCase):
    def check(self, extra=None):
        with tempfile.NamedTemporaryFile(suffix=".tar.gz") as path:
            with tarfile.open(path.name, "w:gz") as out:
                for name in ("l2reth/db/mdbx.dat", "l2reth/db/scroll.db", "l2reth/static_files/header"):
                    info = tarfile.TarInfo(name)
                    info.size = 1
                    out.addfile(info, io.BytesIO(b"x"))
                if extra:
                    out.addfile(extra)
            archive.validate(path.name, "l2reth", ROOT.name)

    def test_directory_headers_optional(self):
        self.check()

    def test_forbidden_descendant_without_directory_header(self):
        for name in ("l2reth/genesis/genesis.json", "l2reth/lost+found/recovered"):
            with self.assertRaisesRegex(ValueError, "forbidden"):
                self.check(tarfile.TarInfo(name))

    def test_identity_keys_rejected_at_any_depth(self):
        for name in ("discovery-secret", "nodekey", "p2p-secret-key", "l2reth-p2p.key", "l2reth-identity/key"):
            for prefix in ("l2reth/", "l2reth/db/"):
                with self.subTest(name=prefix + name), self.assertRaises(ValueError):
                    self.check(tarfile.TarInfo(prefix + name))

    def test_links_duplicates_and_traversal_rejected(self):
        link = tarfile.TarInfo("l2reth/db/link")
        link.type = tarfile.SYMTYPE
        link.linkname = "/tmp/outside"
        for item in (link, tarfile.TarInfo("l2reth/db/mdbx.dat"), tarfile.TarInfo("l2reth/../outside")):
            with self.assertRaises(ValueError):
                self.check(item)

    def test_non_normalized_paths_rejected(self):
        for name in ("./l2reth/db/extra", "l2reth//db/extra", "l2reth/db/./extra"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "normalized"):
                self.check(tarfile.TarInfo(name))

    def test_dogecoin_private_state_and_required_trees(self):
        chain = "dogecoin/" + ("testnet3/" if ROOT.name == "testnet" else "")
        required = (chain + "blocks/index/CURRENT", chain + "chainstate/CURRENT")
        def check(names):
            with tempfile.NamedTemporaryFile(suffix=".tar.gz") as path:
                with tarfile.open(path.name, "w:gz") as out:
                    for name in names:
                        info = tarfile.TarInfo(name)
                        info.size = 1
                        out.addfile(info, io.BytesIO(b"x"))
                archive.validate(path.name, "dogecoin", ROOT.name)
        check(required)
        for private in ("wallet.dat", "wallets/w1", "dogecoin.conf", ".cookie", "peers.dat", "banlist.dat", ".lock"):
            with self.subTest(name=private), self.assertRaisesRegex(ValueError, "forbidden"):
                check(required + (chain + private,))
        with self.assertRaisesRegex(ValueError, "missing"):
            check(required[:1])
