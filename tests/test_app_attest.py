"""Exercise Apple's App Attest validation rules with a local certificate hierarchy."""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path
import struct
import tempfile
import unittest

import cbor2
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from service.app_attest import AppAttestVerifier, InvalidAttestation, NONCE_OID


APP_ID = "TESTTEAM.ai.paceman.app"
NOW = datetime(2026, 1, 1, tzinfo=timezone.utc)


def encoded(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def certificate(subject, issuer, key, signer, *, ca, nonce=None):
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject)])
    issuer_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, issuer)])
    builder = (x509.CertificateBuilder().subject_name(name).issuer_name(issuer_name)
               .public_key(key.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(NOW - timedelta(days=1))
               .not_valid_after(NOW + timedelta(days=1))
               .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True))
    if nonce is not None:
        builder = builder.add_extension(x509.UnrecognizedExtension(
            NONCE_OID, b"\x30\x24\xa1\x22\x04\x20" + nonce), critical=False)
    return builder.sign(signer, hashes.SHA256())


class AppAttestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root_key = ec.generate_private_key(ec.SECP256R1())
        self.intermediate_key = ec.generate_private_key(ec.SECP256R1())
        self.device_key = ec.generate_private_key(ec.SECP256R1())
        self.root = certificate("Root", "Root", self.root_key, self.root_key, ca=True)
        self.intermediate = certificate("Intermediate", "Root", self.intermediate_key,
                                        self.root_key, ca=True)
        root_path = Path(self.temporary.name) / "root.pem"
        root_path.write_bytes(self.root.public_bytes(serialization.Encoding.PEM))
        self.verifier = AppAttestVerifier({"production": APP_ID}, root_path)
        self.challenge = "challenge-bound-to-source-and-credential"
        public = self.device_key.public_key().public_bytes(
            serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        self.key_id = encoded(hashlib.sha256(public).digest())
        self.cose = cbor2.dumps({1: 2, 3: -7, -1: 1, -2: public[1:33], -3: public[33:]})

    def attestation(self, challenge=None, *, aaguid=b"appattest" + b"\0" * 7,
                    app_id=APP_ID, root_key=None):
        credential = base64.urlsafe_b64decode(self.key_id + "=")
        auth = (hashlib.sha256(app_id.encode()).digest() + b"\x40" + struct.pack(">I", 0)
                + aaguid + struct.pack(">H", 32) + credential + self.cose)
        nonce = hashlib.sha256(auth + hashlib.sha256((challenge or self.challenge).encode()).digest()).digest()
        leaf = certificate("Leaf", "Intermediate", self.device_key, self.intermediate_key,
                           ca=False, nonce=nonce)
        chain = [leaf.public_bytes(serialization.Encoding.DER),
                 self.intermediate.public_bytes(serialization.Encoding.DER)]
        return encoded(cbor2.dumps({"fmt": "apple-appattest", "authData": auth,
                                    "attStmt": {"x5c": chain}}))

    def assertion(self, counter, challenge=None, *, app_id=APP_ID):
        auth = hashlib.sha256(app_id.encode()).digest() + b"\x00" + struct.pack(">I", counter)
        nonce = hashlib.sha256(auth + hashlib.sha256((challenge or self.challenge).encode()).digest()).digest()
        signature = self.device_key.sign(nonce, ec.ECDSA(hashes.SHA256()))
        return encoded(cbor2.dumps({"authenticatorData": auth, "signature": signature}))

    def assertion_with_extensions(self, category, *, flags=0):
        extensions = cbor2.dumps({"apple_validation_category_01": category.to_bytes(4, "little"),
                                  "apple_bundle_version_01": "1"})
        auth = hashlib.sha256(APP_ID.encode()).digest() + bytes([flags]) + struct.pack(">I", 1) + extensions
        nonce = hashlib.sha256(auth + hashlib.sha256(self.challenge.encode()).digest()).digest()
        signature = self.device_key.sign(nonce, ec.ECDSA(hashes.SHA256()))
        return encoded(cbor2.dumps({"authenticatorData": auth, "signature": signature}))

    def test_assertion_rejects_signature_over_unhashed_composite(self):
        public = self.verifier.attest(self.attestation(), self.key_id, self.challenge,
                                      "production", now=NOW)
        auth = hashlib.sha256(APP_ID.encode()).digest() + b"\x00" + struct.pack(">I", 1)
        composite = auth + hashlib.sha256(self.challenge.encode()).digest()
        signature = self.device_key.sign(composite, ec.ECDSA(hashes.SHA256()))
        proof = encoded(cbor2.dumps({"authenticatorData": auth, "signature": signature}))
        with self.assertRaisesRegex(InvalidAttestation, "Invalid App Attest assertion signature"):
            self.verifier.assert_key(proof, public, self.challenge, "production", 0)

    def test_cryptokit_nonce_signature_interoperability(self):
        # P-256 public key and DER signature generated by CryptoKit's
        # PrivateKey.signature(for: nonce Data), independent of Python signing.
        public = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), base64.b64decode(
            "BDaRkJT5C/jEaXGs6ODj9T0KMhFs2k4xgKRsbxnpAitQDwIB7cEzMc/ASo83RIMORyFqy2E8nZVAHO6wARQpnLg="))
        public_der = public.public_bytes(serialization.Encoding.DER,
                                         serialization.PublicFormat.SubjectPublicKeyInfo)
        auth = base64.b64decode(
            "OV3q7r7IW0Gj0e7DCVa7DJTZb1x4RZ+Bp6SrKO3qc7rAAAAAAaJ4HGFwcGxlX3ZhbGlkYXRpb25fY2F0ZWdvcnlfMDFEAgAAAHdhcHBsZV9idW5kbGVfdmVyc2lvbl8wMWEx")
        signature = base64.b64decode(
            "MEQCIB9/9abWh+C9rYLjQSWqRHdbrv0S1JCC3IOG4y7FdY26AiAPIoDcW5t8G6NCqVNy9gCY7FxK5VsAV4NUAwA6/s2AwA==")
        proof = encoded(cbor2.dumps({"authenticatorData": auth, "signature": signature}))
        self.assertEqual(self.verifier.assert_key(proof, public_der, self.challenge,
                                                  "production", 0), 1)

    def test_attestation_and_incrementing_assertions(self):
        public = self.verifier.attest(self.attestation(), self.key_id, self.challenge,
                                      "production", now=NOW)
        self.assertEqual(self.verifier.assert_key(self.assertion(1), public, self.challenge,
                                                   "production", 0), 1)
        with self.assertRaises(InvalidAttestation):
            self.verifier.assert_key(self.assertion(1), public, self.challenge, "production", 1)
        with self.assertRaises(InvalidAttestation):
            self.verifier.assert_key(self.assertion(2, "other challenge"), public,
                                     self.challenge, "production", 1)

    def test_attestation_rejects_wrong_identity_environment_and_challenge(self):
        for proof, key_id, challenge in (
                (self.attestation(app_id="OTHER.app"), self.key_id, self.challenge),
                (self.attestation(aaguid=b"appattestdevelop"), self.key_id, self.challenge),
                (self.attestation("other challenge"), self.key_id, self.challenge),
                (self.attestation(), "a" * 43, self.challenge)):
            with self.subTest(proof=proof[:12], key_id=key_id):
                with self.assertRaises(InvalidAttestation):
                    self.verifier.attest(proof, key_id, challenge, "production", now=NOW)

    def test_attestation_rejects_trailing_cbor(self):
        proof = self.attestation()
        raw = base64.urlsafe_b64decode(proof + "=" * (-len(proof) % 4))
        with self.assertRaises(InvalidAttestation):
            self.verifier.attest(encoded(raw + b"\x00"), self.key_id, self.challenge,
                                 "production", now=NOW)

    def test_assertion_validation_category_even_without_extension_flag(self):
        public = self.verifier.attest(self.attestation(), self.key_id, self.challenge,
                                      "production", now=NOW)
        self.assertEqual(self.verifier.assert_key(self.assertion_with_extensions(2), public,
                                                   self.challenge, "production", 0), 1)
        with self.assertRaises(InvalidAttestation):
            self.verifier.assert_key(self.assertion_with_extensions(3), public,
                                     self.challenge, "production", 0)

    def test_ios27_assertion_at_bit_does_not_bypass_validation(self):
        public = self.verifier.attest(self.attestation(), self.key_id, self.challenge,
                                      "production", now=NOW)
        for flags in (0x40, 0xC0):
            with self.subTest(flags=flags):
                proof = self.assertion_with_extensions(2, flags=flags)
                self.assertEqual(self.verifier.assert_key(proof, public, self.challenge,
                                                          "production", 0), 1)
                with self.assertRaises(InvalidAttestation):
                    self.verifier.assert_key(proof, public, self.challenge, "production", 1)
                with self.assertRaises(InvalidAttestation):
                    self.verifier.assert_key(proof, public, "wrong challenge", "production", 0)
                with self.assertRaises(InvalidAttestation):
                    self.verifier.assert_key(self.assertion_with_extensions(3, flags=flags), public,
                                             self.challenge, "production", 0)
                raw = base64.urlsafe_b64decode(proof + "=" * (-len(proof) % 4))
                altered = cbor2.loads(raw)
                auth = bytearray(altered["authenticatorData"])
                auth[32] ^= 0x40
                altered["authenticatorData"] = bytes(auth)
                with self.assertRaises(InvalidAttestation):
                    self.verifier.assert_key(encoded(cbor2.dumps(altered)), public,
                                             self.challenge, "production", 0)


if __name__ == "__main__":
    unittest.main()
