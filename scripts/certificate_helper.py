#!/usr/bin/env python3
"""Inspect and locally trust Homepage TLS certificates without HTTP requests."""

from __future__ import annotations

import datetime as dt
import errno
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
import urllib.parse

MAX_PEM_BYTES = 1024 * 1024
PEM_CERT = re.compile(rb"-----BEGIN CERTIFICATE-----[\r\n]+.*?-----END CERTIFICATE-----", re.S)
PRIVATE_KEY = re.compile(rb"-----BEGIN (?:RSA |EC |ENCRYPTED |OPENSSH )?PRIVATE KEY-----", re.I)


class CertificateError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def result(**values):
    print(json.dumps(values, ensure_ascii=True, separators=(",", ":")))


def run(args, *, data=None, timeout=8):
    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
    try:
        return subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout, check=False, env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CertificateError("INSPECTION_FAILED", "Could not inspect the server certificate.") from error


def parse_url(value: str):
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme.lower() != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise CertificateError("INVALID_URL", "Certificate inspection requires an HTTPS address without credentials.")
    try:
        host = parsed.hostname.encode("idna").decode("ascii").lower()
        port = parsed.port or 443
    except (UnicodeError, ValueError) as error:
        raise CertificateError("INVALID_URL", "The Homepage address is invalid.") from error
    if any(ord(char) < 33 or ord(char) == 127 for char in host) or not 1 <= port <= 65535:
        raise CertificateError("INVALID_URL", "The Homepage address is invalid.")
    return host, port


def pem_blocks(raw: bytes):
    if not raw or len(raw) > MAX_PEM_BYTES:
        raise CertificateError("CA_FILE_INVALID", "The certificate file is empty or exceeds 1 MiB.")
    if PRIVATE_KEY.search(raw):
        raise CertificateError("CA_FILE_PRIVATE_KEY", "Private keys are not accepted. Select a public CA certificate only.")
    blocks = PEM_CERT.findall(raw)
    if not blocks:
        raise CertificateError("CA_FILE_INVALID", "The file does not contain a PEM CERTIFICATE.")
    remainder = PEM_CERT.sub(b"", raw)
    if re.search(rb"-----BEGIN [^-]+-----", remainder):
        raise CertificateError("CA_FILE_INVALID", "The file contains an unsupported PEM block.")
    return blocks


def write_temp_certificates(certificates):
    directory = tempfile.TemporaryDirectory(prefix="omahome-tls-")
    paths = []
    for index, cert in enumerate(certificates):
        path = pathlib.Path(directory.name) / f"cert-{index}.pem"
        path.write_bytes(cert + b"\n")
        os.chmod(path, 0o600)
        paths.append(path)
    return directory, paths


def fetch_chain(host, port):
    connect_host = f"[{host}]" if ":" in host else host
    command = ["openssl", "s_client", "-connect", f"{connect_host}:{port}", "-showcerts", "-no_ticket"]
    if ":" not in host:
        command += ["-servername", host]
    response = run(command, data=b"", timeout=10)
    blocks = PEM_CERT.findall(response.stdout + b"\n" + response.stderr)
    if not blocks:
        raise CertificateError("INSPECTION_FAILED", "The server did not present a readable TLS certificate.")
    return blocks


def x509_text(cert_path):
    response = run(["openssl", "x509", "-in", str(cert_path), "-noout", "-nameopt", "RFC2253",
                    "-subject", "-issuer", "-startdate", "-enddate", "-fingerprint", "-sha256"])
    san = run(["openssl", "x509", "-in", str(cert_path), "-noout", "-ext", "subjectAltName"])
    if response.returncode:
        raise CertificateError("CERTIFICATE_INVALID", "The presented certificate is invalid or unreadable.")
    return (response.stdout + b"\n" + san.stdout).decode("utf-8", "replace")


def parse_x509_info(text):
    fields = {}
    for line in text.splitlines():
        for key in ("subject", "issuer", "notBefore", "notAfter", "sha256 Fingerprint"):
            prefix = key + "="
            if line.startswith(prefix):
                fields[key] = line[len(prefix):].strip()
    sans = []
    in_san = False
    for line in text.splitlines():
        if line.startswith("X509v3 Subject Alternative Name:"):
            in_san = True
            continue
        if line.startswith("X509v3 ") and in_san:
            break
        if in_san:
            sans.extend(item.strip() for item in line.split(",") if item.strip())
    return fields, sans


def certificate_date(value):
    try:
        return dt.datetime.strptime(value, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        raise CertificateError("CERTIFICATE_INVALID", "The certificate validity dates could not be read.")


def verify(host, leaf, chain, ca_file=None, self_signed=False):
    temporary, paths = write_temp_certificates([leaf] + list(chain))
    try:
        hostname_option = "-verify_ip" if _is_ip(host) else "-verify_hostname"
        command = ["openssl", "verify", "-purpose", "sslserver", hostname_option, host]
        if self_signed:
            command += ["-trusted", str(paths[0]), "-check_ss_sig"]
        elif ca_file:
            command += ["-CAfile", str(ca_file)]
        if chain:
            chain_path = pathlib.Path(temporary.name) / "untrusted.pem"
            chain_path.write_bytes(b"\n".join(chain) + b"\n")
            os.chmod(chain_path, 0o600)
            command += ["-untrusted", str(chain_path)]
        command.append(str(paths[0]))
        completed = run(command)
        return completed.returncode == 0, completed.stderr.decode("utf-8", "replace") + completed.stdout.decode("utf-8", "replace")
    finally:
        temporary.cleanup()


def verify_hostname(host, leaf):
    """Verify certificate identity independently of CA trust.

    `openssl x509 -noout -checkhost` can print a mismatch but still exit 0 on
    OpenSSL 3.0. Trust the presented leaf only for this identity-only check;
    evaluate_chain() separately validates its actual chain afterwards.
    """
    temporary, paths = write_temp_certificates([leaf])
    try:
        hostname_option = "-verify_ip" if _is_ip(host) else "-verify_hostname"
        completed = run(["openssl", "verify", "-partial_chain", "-trusted", str(paths[0]),
                         hostname_option, host, str(paths[0])])
        return completed.returncode == 0
    finally:
        temporary.cleanup()


def ca_file_info(path):
    source = pathlib.Path(path)
    try:
        descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise CertificateError("CA_FILE_INVALID", "Select a regular certificate file, not a symlink or special file.")
        if metadata.st_mode & 0o444 == 0:
            raise CertificateError("CA_FILE_NOT_READABLE", "The selected certificate file is not readable.")
        if metadata.st_size > MAX_PEM_BYTES:
            raise CertificateError("CA_FILE_INVALID", "The certificate file exceeds 1 MiB.")
        with os.fdopen(descriptor, "rb") as input_file:
            descriptor = -1
            raw = input_file.read(MAX_PEM_BYTES + 1)
            if len(raw) > MAX_PEM_BYTES:
                raise CertificateError("CA_FILE_INVALID", "The certificate file exceeds 1 MiB.")
    except CertificateError:
        raise
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise CertificateError("CA_FILE_INVALID", "Select a regular certificate file, not a symlink.") from error
        if isinstance(error, PermissionError):
            raise CertificateError("CA_FILE_NOT_READABLE", "The selected certificate file is not readable.") from error
        raise CertificateError("CA_FILE_NOT_FOUND", "The selected certificate file cannot be read.") from error
    finally:
        if "descriptor" in locals() and descriptor >= 0:
            os.close(descriptor)
    blocks = pem_blocks(raw)
    temporary, paths = write_temp_certificates(blocks)
    try:
        for cert_path in paths:
            info = run(["openssl", "x509", "-in", str(cert_path), "-noout", "-ext", "basicConstraints"])
            if info.returncode or b"CA:TRUE" not in info.stdout:
                raise CertificateError("CA_FILE_INVALID", "The selected file must contain a CA certificate with CA:TRUE.")
        return raw, hashlib.sha256(raw).hexdigest()
    finally:
        temporary.cleanup()


def trust_directory():
    path = pathlib.Path.home()
    for component in (".config", "omaops", "homepage", "trust"):
        path = path / component
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            pass
        metadata = path.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise CertificateError("TRUST_STORE_INVALID", "OmaHomepage's local trust path must contain user-owned real directories.")
    os.chmod(path, 0o700)
    return path


def host_filename(host):
    return re.sub(r"[^a-z0-9.-]", "_", host.lower())


def trust_index_path(directory, host):
    return directory / ("." + host_filename(host) + ".index.json")


def read_trust_index(directory, host):
    index = trust_index_path(directory, host)
    if not index.exists() and not index.is_symlink():
        return []
    try:
        metadata = index.lstat()
        if index.is_symlink() or not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_size > 16384:
            raise CertificateError("TRUST_STORE_INVALID", "OmaHomepage's local trust index is not a safe user-owned file.")
        values = json.loads(index.read_text(encoding="utf-8"))
    except CertificateError:
        raise
    except (OSError, ValueError) as error:
        raise CertificateError("TRUST_STORE_INVALID", "OmaHomepage's local trust index cannot be read safely.") from error
    if not isinstance(values, list) or any(not isinstance(name, str) or not re.fullmatch(
        re.escape(host_filename(host)) + r"-[a-f0-9]{16}\.pem", name
    ) for name in values):
        raise CertificateError("TRUST_STORE_INVALID", "OmaHomepage's local trust index contains an invalid entry.")
    return list(dict.fromkeys(values))


def write_trust_index(directory, host, filenames):
    index = trust_index_path(directory, host)
    fd, temporary = tempfile.mkstemp(prefix=".index-", suffix=".json", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(filenames, output, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, index)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def store_certificate(host, fingerprint, raw):
    directory = trust_directory()
    filename = f"{host_filename(host)}-{fingerprint[:16]}.pem"
    target = directory / filename
    if target.is_symlink():
        raise CertificateError("TRUST_STORE_INVALID", "A symbolic link blocks the selected trust file.")
    filenames = read_trust_index(directory, host)
    if filename not in filenames:
        write_trust_index(directory, host, filenames + [filename])
    fd, temporary = tempfile.mkstemp(prefix=".oma-", suffix=".pem", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as output:
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, target)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    return str(target)


def evaluate_chain(host, chain, ca_file=None):
    temporary, paths = write_temp_certificates(chain)
    try:
        text = x509_text(paths[0])
        fields, sans = parse_x509_info(text)
        required = ("subject", "issuer", "notBefore", "notAfter", "sha256 Fingerprint")
        if any(not fields.get(key) for key in required):
            raise CertificateError("CERTIFICATE_INVALID", "The presented certificate is missing required metadata.")
        fingerprint = fields["sha256 Fingerprint"].replace(":", "").lower()
        metadata = {"host": host, "subject": fields["subject"], "issuer": fields["issuer"], "sans": sans,
                    "validFrom": fields["notBefore"], "validUntil": fields["notAfter"],
                    "fingerprint": fields["sha256 Fingerprint"], "fingerprintHex": fingerprint}
        validity = certificate_validity(fields["notBefore"], fields["notAfter"])
        if validity == "CERTIFICATE_NOT_YET_VALID":
            return {"ok": False, "kind": "CERTIFICATE_NOT_YET_VALID", "message": "The server certificate is not valid yet.", **metadata}
        if validity == "CERTIFICATE_EXPIRED":
            return {"ok": False, "kind": "CERTIFICATE_EXPIRED", "message": "The server certificate has expired.", **metadata}
        if not verify_hostname(host, chain[0]):
            return {"ok": False, "kind": "HOSTNAME_MISMATCH", "message": "The certificate does not match the configured hostname.", **metadata}
        is_self_signed, _ = verify(host, chain[0], chain[1:], self_signed=True)
        is_self_signed = is_self_signed and fields["subject"] == fields["issuer"]
        is_system_trusted, system_error = verify(host, chain[0], chain[1:])
        mode, trust_error = "SYSTEM TRUST", ""
        if ca_file:
            is_custom_trusted, trust_error = verify(host, chain[0], chain[1:], ca_file=ca_file)
            if is_custom_trusted:
                mode = "CUSTOM CA"
            else:
                return {"ok": False, "kind": "CA_FILE_INVALID", "message": "The selected CA does not verify the server certificate and hostname.",
                        **metadata, "selfSigned": is_self_signed}
        elif is_system_trusted:
            mode = "SYSTEM TRUST"
        elif is_self_signed:
            mode = "SELF-SIGNED TRUST AVAILABLE"
        else:
            return {"ok": False, "kind": "PRIVATE_CA_REQUIRED", "message": "TLS certificate not trusted. A private CA is required.",
                    **metadata, "selfSigned": is_self_signed, "trustAvailable": True, "systemError": system_error[-400:]}
        message = "Certificate chain and hostname verified with " + mode + "." if mode in ("SYSTEM TRUST", "CUSTOM CA") else \
            "Unverified certificate presented by server; hostname and validity inspected, but it is not trusted yet."
        return {"ok": True, "kind": mode, "message": message,
                **metadata, "selfSigned": is_self_signed, "systemTrusted": is_system_trusted,
                "trustAvailable": mode == "SELF-SIGNED TRUST AVAILABLE"}
    finally:
        temporary.cleanup()


def inspect(url, ca_file=None):
    host, port = parse_url(url)
    chain = fetch_chain(host, port)
    return evaluate_chain(host, chain, ca_file)


def certificate_validity(not_before_text, not_after_text, now=None):
    current = now or dt.datetime.now(dt.timezone.utc)
    not_before, not_after = certificate_date(not_before_text), certificate_date(not_after_text)
    if current < not_before:
        return "CERTIFICATE_NOT_YET_VALID"
    if current > not_after:
        return "CERTIFICATE_EXPIRED"
    return "VALID"


def _is_ip(host):
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def import_ca(url, source_path):
    host, _ = parse_url(url)
    raw, fingerprint = ca_file_info(source_path)
    with tempfile.TemporaryDirectory(prefix="omahome-ca-verify-") as directory:
        selected_ca = pathlib.Path(directory) / "selected-ca.pem"
        selected_ca.write_bytes(raw)
        os.chmod(selected_ca, 0o600)
        check = inspect(url, ca_file=str(selected_ca))
        if not check.get("ok") or check.get("kind") != "CUSTOM CA":
            raise CertificateError("CA_FILE_INVALID", check.get("message", "The selected CA does not verify this Homepage server."))
    destination = store_certificate(host, fingerprint, raw)
    return {"ok": True, "kind": "CUSTOM CA", "host": host, "caPath": destination,
            "fingerprint": fingerprint}


def trust_leaf(url, expected_fingerprint):
    host, port = parse_url(url)
    chain = fetch_chain(host, port)
    check = evaluate_chain(host, chain)
    if not check.get("trustAvailable"):
        raise CertificateError(check.get("kind", "CERTIFICATE_INVALID"), check.get("message", "This certificate is not eligible for explicit trust."))
    fingerprint = check["fingerprintHex"]
    if fingerprint != str(expected_fingerprint or "").replace(":", "").lower():
        raise CertificateError("CERTIFICATE_CHANGED", "The server certificate changed after inspection. Inspect and confirm the new fingerprint.")
    destination = store_certificate(host, fingerprint, chain[0] + b"\n")
    return {"ok": True, "kind": "TRUSTED CERTIFICATE PENDING VERIFICATION", "host": host, "caPath": destination,
            "fingerprint": fingerprint, "subject": check["subject"], "issuer": check["issuer"]}


def remove_trust(host, certificate_path):
    directory = trust_directory()
    candidate = pathlib.Path(certificate_path)
    if candidate.is_symlink() or candidate.parent.resolve() != directory or not re.fullmatch(
        re.escape(host_filename(host)) + r"-[a-f0-9]{16}\.pem", candidate.name
    ):
        raise CertificateError("TRUST_PATH_INVALID", "Only OmaHomepage's certificate copy for this hostname can be removed.")
    filenames = read_trust_index(directory, host)
    if candidate.name not in filenames:
        raise CertificateError("TRUST_PATH_INVALID", "The selected certificate is not recorded as an OmaHomepage-managed copy.")
    metadata = candidate.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise CertificateError("TRUST_PATH_INVALID", "The local certificate copy is not a regular file owned by this user.")
    candidate.unlink()
    remaining = [filename for filename in filenames if filename != candidate.name]
    if remaining:
        write_trust_index(directory, host, remaining)
    else:
        trust_index_path(directory, host).unlink(missing_ok=True)
    return {"ok": True, "host": host}


def main(argv):
    if len(argv) < 3:
        raise CertificateError("USAGE", "Invalid certificate helper request.")
    action, url = argv[1], argv[2]
    if action == "inspect" and len(argv) in (3, 4):
        result(**inspect(url, ca_file=argv[3] if len(argv) == 4 else None))
    elif action == "import-ca" and len(argv) == 4:
        result(**import_ca(url, argv[3]))
    elif action == "trust-leaf" and len(argv) == 4:
        result(**trust_leaf(url, argv[3]))
    elif action in ("remove-trust", "rollback-leaf") and len(argv) == 4:
        host, _ = parse_url(url)
        result(**remove_trust(host, argv[3]))
    else:
        raise CertificateError("USAGE", "Invalid certificate helper request.")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except CertificateError as error:
        result(ok=False, kind=error.code, message=str(error))
        sys.exit(1)
