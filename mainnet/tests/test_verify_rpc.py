"""RPC acceptance failures, reference defaults and credential-safe diagnostics."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verify_rpc", ROOT / "scripts/verify-rpc.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.responses = {
            label: {"eth_chainId": "0x123", "eth_syncing": False,
                    "eth_blockNumber": hex(height), "eth_getBlockByNumber": {"hash": "0x" + "a" * 64}}
            for label, height in (("local", 100), ("reference", 102))}
        self.output = io.StringIO()
        self.capture = redirect_stdout(self.output)
        self.capture.__enter__()
        self.addCleanup(self.capture.__exit__, None, None, None)

    def rpc(self, url, label, method, params=None):
        return self.responses[label][method]

    def sample(self, **kwargs):
        with patch.object(verify, "rpc", self.rpc):
            return verify.sample("http://local", "http://reference", 0x123, 5, **kwargs)

    def test_matching_chain_and_hash_with_bounded_lag(self):
        self.assertEqual(self.sample(), (100, 102))
        self.assertIn("block 80 hash match", self.output.getvalue())
        self.sample(block_number=50)
        self.assertIn("block 50 hash match", self.output.getvalue())

    def test_wrong_network_syncing_and_lag_fail_with_actionable_reason(self):
        cases = (("eth_chainId", "0x999", "chain ID"), ("eth_syncing", {}, "reports syncing"),
                 ("eth_blockNumber", "0xff", "head difference"),
                 ("eth_blockNumber", "0x0", "head difference"),
                 ("eth_blockNumber", "oops", "hexadecimal"))
        for method, value, message in cases:
            with self.subTest(method=method, value=value):
                original = self.responses["reference"][method]
                self.responses["reference"][method] = value
                with self.assertRaisesRegex(verify.CheckError, message):
                    self.sample()
                self.responses["reference"][method] = original

    def test_hash_mismatch_missing_hash_and_out_of_range_block(self):
        for value, message in (({"hash": "0x" + "b" * 64}, "hash mismatch"), ({}, "missing/invalid")):
            self.responses["reference"]["eth_getBlockByNumber"] = value
            with self.assertRaisesRegex(verify.CheckError, message):
                self.sample()
        with self.assertRaisesRegex(verify.CheckError, "outside the shared history"):
            self.sample(block_number=1000)

    def test_transport_and_provider_errors_never_disclose_url_or_body(self):
        secret = "provider-secret-value"
        url = "https://example.invalid/" + secret
        for error, message in ((urllib.error.HTTPError(url, 429, secret, {}, None), "reference eth_chainId: HTTP 429"),
                               (urllib.error.URLError(secret), "connection"), (TimeoutError(secret), "timeout")):
            with patch.object(verify.urllib.request, "urlopen", side_effect=error):
                with self.assertRaises(verify.CheckError) as caught:
                    verify.rpc(url, "reference", "eth_chainId")
                self.assertIn(message, str(caught.exception))
                self.assertNotIn(secret, str(caught.exception))
        for reply in ({"error": {"message": secret}}, {"result": None}, [], "bad JSON"):
            body = reply if isinstance(reply, str) else json.dumps(reply)
            with patch.object(verify.urllib.request, "urlopen", return_value=io.BytesIO(body.encode())):
                with self.assertRaises(verify.CheckError) as caught:
                    verify.rpc(url, "reference", "eth_chainId")
                self.assertNotIn(secret, str(caught.exception))

    def test_false_sync_response_is_valid(self):
        with patch.object(verify.urllib.request, "urlopen", return_value=io.BytesIO(b'{"result":false}')):
            self.assertIs(verify.rpc("http://local", "local", "eth_syncing"), False)

    def run_main(self, samples):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "config").mkdir()
            (root / "config/l2reth-genesis.json").write_text('{"config":{"chainId":291}}')
            with patch.object(verify, "ROOT", root), patch.object(verify, "sample", side_effect=samples), \
                    patch.object(verify.time, "sleep") as sleep, \
                    patch("sys.argv", ["verify-rpc.py", "--reference-url", "http://reference"]):
                verify.main()
                self.assertEqual(sleep.call_count, 2)

    def test_three_samples_require_both_heads_to_advance(self):
        self.run_main([(100, 102), (101, 103), (102, 104)])
        self.assertIn("PASS: 3 sample(s)", self.output.getvalue())
        for samples in ([(100, 100)] * 3, [(100, 102), (101, 102), (102, 102)]):
            with self.assertRaisesRegex(verify.CheckError, "advancement was not observed"):
                self.run_main(samples)

    def test_mainnet_has_no_testnet_reference_default(self):
        if ROOT.name == "mainnet":
            self.assertIsNone(verify.DEFAULT_REFERENCE)
            with patch("sys.argv", ["verify-rpc.py"]), patch.object(verify, "rpc") as rpc:
                with self.assertRaisesRegex(verify.CheckError, "mainnet reference RPC is not published"):
                    verify.main()
                rpc.assert_not_called()
        else:
            self.assertEqual(verify.DEFAULT_REFERENCE, "https://rpc.testnet.dogeos.com")


if __name__ == "__main__":
    unittest.main()
