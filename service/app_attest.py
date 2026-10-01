"""Verify Apple App Attest proofs for relay pairing approval.

The pinned root is Apple's public App Attestation Root CA certificate, from
https://www.apple.com/certificateauthority/private/ . Neither APNs tokens nor
an app-supplied bundle identifier establish app identity.
"""
from __future__ import annotations

import base64
from datetime import datetime, timezone
import hashlib
import io
from pathlib import Path
import struct

import cbor2
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa


ROOT = Path(__file__).parent / "certs/Apple_App_Attestation_Root_CA.pem"
NONCE_OID = x509.ObjectIdentifier("1.2.840.113635.100.8.2")


class InvalidAttestation(ValueError):
    pass


def _decode64(value: object, limit: int) -> bytes:
    if not isinstance(value, str) or not 1 <= len(value) <= limit:
        raise InvalidAttestation("Invalid proof encoding")
    try:
        data = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except (ValueError, base64.binascii.Error) as error:
        raise InvalidAttestation("Invalid proof encoding") from error
    if base64.urlsafe_b64encode(data).decode().rstrip("=") != value.rstrip("="):
        raise InvalidAttestation("Invalid proof encoding")
    return data


def _cbor(value: bytes) -> object:
    try:
        stream = io.BytesIO(value)
        decoded = cbor2.CBORDecoder(stream).decode()
        if stream.read(1):
            raise InvalidAttestation("Trailing CBOR proof data")
        return decoded
    except (ValueError, EOFError, TypeError, cbor2.CBORDecodeError) as error:
        raise InvalidAttestation("Invalid CBOR proof") from error


def _public_bytes(key) -> bytes:
    if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
        raise InvalidAttestation("App Attest key must use P-256")
    return key.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def _verify_certificate(child: x509.Certificate, issuer: x509.Certificate) -> None:
    if child.issuer != issuer.subject:
        raise InvalidAttestation("Invalid App Attest certificate chain")
    key = issuer.public_key()
    try:
        if isinstance(key, ec.EllipticCurvePublicKey):
            key.verify(child.signature, child.tbs_certificate_bytes, ec.ECDSA(child.signature_hash_algorithm))
        elif isinstance(key, rsa.RSAPublicKey):
            key.verify(child.signature, child.tbs_certificate_bytes,
                       padding.PKCS1v15(), child.signature_hash_algorithm)
        else:
            raise InvalidAttestation("Unsupported certificate signature")
    except InvalidSignature as error:
        raise InvalidAttestation("Invalid App Attest certificate chain") from error


def _certificates(encoded: object, root: x509.Certificate, now: datetime) -> x509.Certificate:
    if not isinstance(encoded, list) or not 2 <= len(encoded) <= 4 or any(
            not isinstance(item, bytes) or not 100 <= len(item) <= 4096 for item in encoded):
        raise InvalidAttestation("Invalid App Attest certificate chain")
    try:
        chain = [x509.load_der_x509_certificate(item) for item in encoded]
    except ValueError as error:
        raise InvalidAttestation("Invalid App Attest certificate chain") from error
    for certificate in [*chain, root]:
        if not certificate.not_valid_before_utc <= now <= certificate.not_valid_after_utc:
            raise InvalidAttestation("Expired App Attest certificate")
    try:
        if chain[0].extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
            raise InvalidAttestation("App Attest leaf is a CA")
        for certificate in [*chain[1:], root]:
            if not certificate.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
                raise InvalidAttestation("Invalid App Attest issuer")
    except x509.ExtensionNotFound as error:
        raise InvalidAttestation("Missing certificate constraints") from error
    for child, issuer in zip(chain, [*chain[1:], root]):
        _verify_certificate(child, issuer)
    return chain[0]


def _credential_data(data: bytes, environment: str, key_id: bytes) -> tuple[bytes, bytes]:
    if len(data) < 87:
        raise InvalidAttestation("Invalid attested credential")
    expected_aaguid = b"appattestdevelop" if environment == "development" else b"appattest" + b"\0" * 7
    if data[37:53] != expected_aaguid:
        raise InvalidAttestation("App Attest environment mismatch")
    length = struct.unpack(">H", data[53:55])[0]
    if length != 32 or data[55:87] != key_id:
        raise InvalidAttestation("Credential ID mismatch")
    stream = io.BytesIO(data[87:])
    try:
        cose = cbor2.CBORDecoder(stream).decode()
    except (ValueError, EOFError, TypeError, cbor2.CBORDecodeError) as error:
        raise InvalidAttestation("Invalid credential key") from error
    if (not isinstance(cose, dict) or set(cose) != {1, 3, -1, -2, -3}
            or cose[1] != 2 or cose[3] != -7 or cose[-1] != 1
            or not isinstance(cose[-2], bytes) or len(cose[-2]) != 32
            or not isinstance(cose[-3], bytes) or len(cose[-3]) != 32):
        raise InvalidAttestation("Invalid credential key")
    return b"\x04" + cose[-2] + cose[-3], stream.read()


def _authenticator_data(data: object, app_id: str, *, attestation: bool,
                        environment: str, key_id: bytes = b"",
                        expected_public: bytes = b"") -> tuple[int, bytes]:
    if not isinstance(data, bytes) or len(data) < 37:
        raise InvalidAttestation("Invalid authenticator data")
    if data[:32] != hashlib.sha256(app_id.encode()).digest():
        raise InvalidAttestation("App ID mismatch")
    flags = data[32]
    counter = struct.unpack(">I", data[33:37])[0]
    if not attestation:
        remainder = data[37:]
        if flags & 0x40:
            # iOS 27 assertions can carry signed validation extensions with
            # this bit set. Accept that map, or validate a full credential
            # block against the key established by the original attestation.
            if remainder and remainder[0] >> 5 == 5:
                has_validation_extension = _check_extensions(remainder, flags, environment)
                if not has_validation_extension:
                    raise InvalidAttestation("Unexpected credential data")
            else:
                public, remainder = _credential_data(data, environment, key_id)
                if public != expected_public:
                    raise InvalidAttestation("Credential and assertion key mismatch")
                _check_extensions(remainder, flags, environment)
        else:
            _check_extensions(remainder, flags, environment)
        return counter, data
    if not flags & 0x40 or counter != 0 or len(data) < 87:
        raise InvalidAttestation("Invalid attested credential")
    public, remainder = _credential_data(data, environment, key_id)
    _check_extensions(remainder, flags, environment)
    return counter, public


def _check_extensions(remainder: bytes, flags: int, environment: str) -> bool:
    if not remainder:
        if flags & 0x80:
            raise InvalidAttestation("Missing authenticator extensions")
        return False
    # Apple's iOS 27 samples append extension CBOR even when the ED flag is clear.
    value = _cbor(remainder)
    if not isinstance(value, dict):
        raise InvalidAttestation("Invalid authenticator extensions")
    category = value.get("apple_validation_category_01")
    version = value.get("apple_bundle_version_01")
    if category is not None:
        if not isinstance(category, bytes) or len(category) != 4:
            raise InvalidAttestation("Invalid app validation category")
        allowed = {3} if environment == "development" else {2, 4}
        if int.from_bytes(category, "little") not in allowed:
            raise InvalidAttestation("Unexpected app validation category")
    if version is not None and (not isinstance(version, str) or not 1 <= len(version) <= 40):
        raise InvalidAttestation("Invalid bundle version")
    return category is not None


class AppAttestVerifier:
    def __init__(self, app_ids: dict[str, str], root_path: Path = ROOT):
        self.app_ids = app_ids
        self.root = x509.load_pem_x509_certificate(root_path.read_bytes())

    def attest(self, proof: str, key_id: str, challenge: str, environment: str,
               *, now: datetime | None = None) -> bytes:
        if environment not in self.app_ids:
            raise InvalidAttestation("Unavailable App Attest environment")
        key_bytes = _decode64(key_id, 100)
        if len(key_bytes) != 32:
            raise InvalidAttestation("Invalid App Attest key ID")
        value = _cbor(_decode64(proof, 32768))
        if (not isinstance(value, dict) or value.get("fmt") != "apple-appattest"
                or not isinstance(value.get("attStmt"), dict)
                or not isinstance(value.get("authData"), bytes)):
            raise InvalidAttestation("Invalid attestation object")
        leaf = _certificates(value["attStmt"].get("x5c"), self.root, now or datetime.now(timezone.utc))
        key = leaf.public_key()
        public = _public_bytes(key)
        if hashlib.sha256(public).digest() != key_bytes:
            raise InvalidAttestation("App Attest key ID mismatch")
        _, cose_public = _authenticator_data(value["authData"], self.app_ids[environment],
                                             attestation=True, environment=environment, key_id=key_bytes)
        if cose_public != public:
            raise InvalidAttestation("Credential and certificate key mismatch")
        nonce = hashlib.sha256(value["authData"] + hashlib.sha256(challenge.encode()).digest()).digest()
        try:
            extension = leaf.extensions.get_extension_for_oid(NONCE_OID).value
        except x509.ExtensionNotFound as error:
            raise InvalidAttestation("Missing App Attest nonce") from error
        if not isinstance(extension, x509.UnrecognizedExtension) or extension.value != b"\x30\x24\xa1\x22\x04\x20" + nonce:
            raise InvalidAttestation("App Attest challenge mismatch")
        return key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)

    def assert_key(self, proof: str, public_der: bytes, challenge: str, environment: str,
                   previous_counter: int) -> int:
        if environment not in self.app_ids:
            raise InvalidAttestation("Unavailable App Attest environment")
        value = _cbor(_decode64(proof, 8192))
        if (not isinstance(value, dict) or not isinstance(value.get("signature"), bytes)
                or not isinstance(value.get("authenticatorData"), bytes)):
            raise InvalidAttestation("Invalid assertion object")
        try:
            key = serialization.load_der_public_key(public_der)
            public = _public_bytes(key)
        except ValueError as error:
            raise InvalidAttestation("Invalid App Attest assertion key") from error
        counter, auth_data = _authenticator_data(value["authenticatorData"], self.app_ids[environment],
                                                  attestation=False, environment=environment,
                                                  key_id=hashlib.sha256(public).digest(), expected_public=public)
        if counter <= previous_counter:
            raise InvalidAttestation("Replayed App Attest assertion")
        try:
            key.verify(value["signature"], auth_data + hashlib.sha256(challenge.encode()).digest(),
                       ec.ECDSA(hashes.SHA256()))
        except (ValueError, InvalidSignature) as error:
            raise InvalidAttestation("Invalid App Attest assertion") from error
        return counter
