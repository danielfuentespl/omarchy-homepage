#!/usr/bin/env python3
import os
import datetime as dt
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from scripts import certificate_helper as Cert


def openssl(*args):
    result = subprocess.run(["openssl", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise AssertionError(result.stderr.decode("utf-8", "replace"))
    return result


class CertificateHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="omahome-cert-tests-")
        cls.root = pathlib.Path(cls.temp.name)
        cls.ca_key = cls.root / "private-ca.key"
        cls.ca = cls.root / "private-ca.pem"
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(cls.ca_key),
                "-out", str(cls.ca), "-days", "3", "-subj", "/CN=OmaHomepage Test CA",
                "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        cls.leaf_key = cls.root / "leaf.key"
        cls.csr = cls.root / "leaf.csr"
        cls.leaf = cls.root / "leaf.pem"
        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", str(cls.leaf_key),
                "-out", str(cls.csr), "-subj", "/CN=homepage.test")
        (cls.root / "leaf.ext").write_text(
            "subjectAltName=DNS:homepage.test\nbasicConstraints=critical,CA:FALSE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n", encoding="ascii")
        openssl("x509", "-req", "-in", str(cls.csr), "-CA", str(cls.ca), "-CAkey", str(cls.ca_key),
                "-CAcreateserial", "-out", str(cls.leaf), "-days", "3", "-extfile", str(cls.root / "leaf.ext"))
        cls.self_key = cls.root / "self.key"
        cls.self_cert = cls.root / "self.pem"
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(cls.self_key),
                "-out", str(cls.self_cert), "-days", "3", "-subj", "/CN=self.homepage.test",
                "-addext", "subjectAltName=DNS:self.homepage.test")
        cls.self_key_v2 = cls.root / "self-v2.key"
        cls.self_cert_v2 = cls.root / "self-v2.pem"
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(cls.self_key_v2),
                "-out", str(cls.self_cert_v2), "-days", "3", "-subj", "/CN=self.homepage.test",
                "-addext", "subjectAltName=DNS:self.homepage.test")
        cls.other_ca_key = cls.root / "other-ca.key"
        cls.other_ca = cls.root / "other-ca.pem"
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(cls.other_ca_key),
                "-out", str(cls.other_ca), "-days", "3", "-subj", "/CN=Wrong Test CA",
                "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def chain(self, cert):
        return [pathlib.Path(cert).read_bytes()]

    def test_private_ca_leaf_is_not_classified_as_self_signed(self):
        result = Cert.evaluate_chain("homepage.test", self.chain(self.leaf))
        self.assertFalse(result["ok"])
        self.assertEqual(result["kind"], "PRIVATE_CA_REQUIRED")
        self.assertFalse(result["selfSigned"])
        self.assertEqual(result["subject"], "CN=homepage.test")
        self.assertEqual(result["issuer"], "CN=OmaHomepage Test CA")
        self.assertIn("DNS:homepage.test", result["sans"])

    def test_real_self_signed_certificate_can_be_offered_for_explicit_trust(self):
        result = Cert.evaluate_chain("self.homepage.test", self.chain(self.self_cert))
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["kind"], "SELF-SIGNED TRUST AVAILABLE")
        self.assertTrue(result["selfSigned"])
        self.assertTrue(result["fingerprintHex"])

    def test_changed_self_signed_certificate_fails_against_previous_local_trust(self):
        previous = Cert.evaluate_chain("self.homepage.test", self.chain(self.self_cert))
        current = Cert.evaluate_chain("self.homepage.test", self.chain(self.self_cert_v2), str(self.self_cert))
        new = Cert.evaluate_chain("self.homepage.test", self.chain(self.self_cert_v2))
        self.assertNotEqual(previous["fingerprintHex"], new["fingerprintHex"])
        self.assertEqual(current["kind"], "CA_FILE_INVALID")
        self.assertFalse(current["ok"])

    def test_self_signed_trust_requires_the_exact_confirmed_fingerprint(self):
        cert = pathlib.Path(self.self_cert).read_bytes()
        inspected = Cert.evaluate_chain("self.homepage.test", [cert])
        with mock.patch.object(Cert, "fetch_chain", return_value=[cert]) as fetched, mock.patch.object(
            Cert, "store_certificate", return_value="/home/test/.config/omaops/homepage/trust/self.pem"
        ) as stored:
            trusted = Cert.trust_self_signed("https://self.homepage.test", inspected["fingerprintHex"])
            self.assertEqual(trusted["fingerprint"], inspected["fingerprintHex"])
            fetched.assert_called_once()
            stored.assert_called_once_with("self.homepage.test", inspected["fingerprintHex"], cert + b"\n")
        with mock.patch.object(Cert, "fetch_chain", return_value=[cert]), mock.patch.object(
            Cert, "store_certificate"
        ) as stored:
            with self.assertRaisesRegex(Cert.CertificateError, "changed after inspection"):
                Cert.trust_self_signed("https://self.homepage.test", "00" * 32)
            stored.assert_not_called()

    def test_private_ca_verifies_server_and_wrong_ca_does_not(self):
        result = Cert.evaluate_chain("homepage.test", self.chain(self.leaf), str(self.ca))
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["kind"], "CUSTOM CA")
        wrong = Cert.evaluate_chain("homepage.test", self.chain(self.leaf), str(self.other_ca))
        self.assertEqual(wrong["kind"], "CA_FILE_INVALID")

    def test_hostname_mismatch_blocks_system_custom_and_self_signed_trust(self):
        result = Cert.evaluate_chain("other.homepage.test", self.chain(self.leaf), str(self.ca))
        self.assertEqual(result["kind"], "HOSTNAME_MISMATCH")
        self.assertFalse(result["ok"])

    def test_ca_file_must_be_regular_pem_ca_without_private_key(self):
        data, _ = Cert.ca_file_info(self.ca)
        self.assertIn(b"BEGIN CERTIFICATE", data)
        with self.assertRaisesRegex(Cert.CertificateError, "PEM CERTIFICATE"):
            Cert.pem_blocks(b"not a certificate")
        with self.assertRaisesRegex(Cert.CertificateError, "Private keys are not accepted"):
            Cert.pem_blocks(pathlib.Path(self.ca).read_bytes() + b"\n-----BEGIN PRIVATE KEY-----\nnot-a-key\n")
        with tempfile.TemporaryDirectory() as directory:
            symlink = pathlib.Path(directory) / "ca.pem"
            symlink.symlink_to(self.ca)
            with self.assertRaisesRegex(Cert.CertificateError, "regular certificate file"):
                Cert.ca_file_info(symlink)
            unreadable = pathlib.Path(directory) / "unreadable.pem"
            unreadable.write_bytes(pathlib.Path(self.ca).read_bytes())
            unreadable.chmod(0)
            with self.assertRaisesRegex(Cert.CertificateError, "not readable"):
                Cert.ca_file_info(unreadable)

    def test_trust_files_are_host_and_fingerprint_specific_and_removable(self):
        with tempfile.TemporaryDirectory() as home:
            with mock.patch.dict(os.environ, {"HOME": home}):
                one = Cert.store_certificate("one.homepage.test", "a1" * 32, pathlib.Path(self.self_cert).read_bytes())
                previous = Cert.store_certificate("one.homepage.test", "c3" * 32, pathlib.Path(self.self_cert_v2).read_bytes())
                two = Cert.store_certificate("two.homepage.test", "b2" * 32, pathlib.Path(self.self_cert).read_bytes())
                unmanaged = pathlib.Path(one).parent / ("one.homepage.test-" + "d4" * 8 + ".pem")
                unmanaged.write_bytes(pathlib.Path(self.self_cert).read_bytes())
                self.assertTrue(one.endswith("one.homepage.test-" + "a1" * 8 + ".pem"))
                self.assertEqual(pathlib.Path(one).stat().st_mode & 0o777, 0o600)
                self.assertEqual(pathlib.Path(one).parent.stat().st_mode & 0o777, 0o700)
                with self.assertRaises(Cert.CertificateError):
                    Cert.remove_trust("two.homepage.test", one)
                Cert.remove_trust("one.homepage.test", one)
                self.assertFalse(pathlib.Path(one).exists())
                self.assertFalse(pathlib.Path(previous).exists())
                self.assertTrue(pathlib.Path(two).exists())
                self.assertTrue(unmanaged.exists())

    def test_tls_url_rejects_http_and_credentials(self):
        for value in ("http://homepage.test", "https://user:pass@homepage.test"):
            with self.assertRaises(Cert.CertificateError):
                Cert.parse_url(value)

    def test_expired_and_not_yet_valid_certificates_are_classified(self):
        now = dt.datetime(2026, 10, 8, tzinfo=dt.timezone.utc)
        self.assertEqual(Cert.certificate_validity("Oct  9 00:00:00 2026 GMT", "Oct 10 00:00:00 2026 GMT", now),
                         "CERTIFICATE_NOT_YET_VALID")
        self.assertEqual(Cert.certificate_validity("Oct  6 00:00:00 2026 GMT", "Oct  7 00:00:00 2026 GMT", now),
                         "CERTIFICATE_EXPIRED")
        self.assertEqual(Cert.certificate_validity("Oct  7 00:00:00 2026 GMT", "Oct  9 00:00:00 2026 GMT", now), "VALID")

    def test_successful_system_verification_is_reported_without_custom_trust(self):
        with mock.patch.object(Cert, "verify", side_effect=[(False, "self-signed check failed"), (True, "OK")]):
            result = Cert.evaluate_chain("homepage.test", self.chain(self.leaf))
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["kind"], "SYSTEM TRUST")

    def test_ca_import_copies_only_after_live_chain_validation(self):
        with tempfile.TemporaryDirectory() as home:
            with mock.patch.dict(os.environ, {"HOME": home}), mock.patch.object(
                Cert, "inspect", return_value={"ok": True, "kind": "CUSTOM CA"}
            ):
                imported = Cert.import_ca("https://homepage.test", str(self.ca))
            self.assertTrue(imported["ok"])
            saved = pathlib.Path(imported["caPath"])
            self.assertTrue(saved.is_file())
            self.assertEqual(saved.read_bytes(), pathlib.Path(self.ca).read_bytes())
            self.assertEqual(saved.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
