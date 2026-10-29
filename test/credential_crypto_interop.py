"""Compare the Luau vault primitives with Python's independent implementations.

Requires the cryptography package with AESSIV support and LuaJIT on PATH (or
--luajit /path/to/luajit). All inputs are deterministic synthetic fixtures.
Run only after the project's source/build review sequence has completed.
"""

import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import subprocess

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESSIV
from cryptography.hazmat.primitives.cmac import CMAC


ROOT = Path(__file__).resolve().parents[1]


def fixture_bytes(label, length):
    """Reproducible varied bytes, including binary data, without a random source."""
    blocks = []
    for index in range((length + 31) // 32):
        blocks.append(hashlib.sha256(label.encode("ascii") + index.to_bytes(4, "big")).digest())
    return b"".join(blocks)[:length]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luajit", default=os.environ.get("LUAJIT", "luajit"))
    options = parser.parse_args()
    requests, expected, labels = [], [], []

    def add(label, operation, result, **fields):
        request = {"op": operation}
        for name, value in fields.items():
            if isinstance(value, bytes):
                request[name] = value.hex()
            elif name == "aad":
                request[name] = [part.hex() for part in value]
            else:
                request[name] = value
        requests.append(request)
        expected.append(result.hex() if result is not None else None)
        labels.append(label)

    lengths = (0, 1, 15, 16, 17, 31, 32, 55, 56, 63, 64, 65, 257, 4097, 16384, 65535)
    aad_cases = (
        [],
        [b""],
        [b"ab", b"c"],
        [b"a", b"bc"],
        [b"", b"vault-v2", b"provider-one", bytes(range(256))],
    )
    for key_size in (32, 48, 64):
        key = fixture_bytes(f"siv-key-{key_size}", key_size)
        reference = AESSIV(key)
        for length in lengths:
            plaintext = fixture_bytes(f"siv-plain-{length}", length)
            for aad_index, associated in enumerate(aad_cases):
                label = f"SIV key={key_size} bytes={length} aad={aad_index}"
                sealed = reference.encrypt(plaintext, associated)
                # Reference decryption also checks that each generated case is valid.
                assert reference.decrypt(sealed, associated) == plaintext, label
                add(label + " seal", "seal", sealed, key=key, text=plaintext, aad=associated)
                add(label + " open", "open", plaintext, key=key, text=sealed, aad=associated)

        for length in (0, 17, 4097):
            plaintext = fixture_bytes("tamper-plain", length)
            associated = [b"vault-v2", b"provider-one"]
            sealed = reference.encrypt(plaintext, associated)
            damaged = []
            for offset in range(16):
                changed = bytearray(sealed)
                changed[offset] ^= 1 << (offset % 8)
                damaged.append((f"tag byte {offset}", key, bytes(changed), associated))
            if plaintext:
                for offset in (16, len(sealed) - 1):
                    changed = bytearray(sealed)
                    changed[offset] ^= 0x80
                    damaged.append((f"cipher byte {offset}", key, bytes(changed), associated))
            changed_key = bytearray(key)
            # Alter the MAC half: with an empty plaintext, the CTR half is unused.
            changed_key[0] ^= 1
            damaged.extend((
                ("wrong key", bytes(changed_key), sealed, associated),
                ("reordered AAD", key, sealed, list(reversed(associated))),
                ("changed AAD", key, sealed, [b"vault-v2", b"provider-two"]),
                ("missing AAD", key, sealed, associated[:1]),
                ("added empty AAD", key, sealed, associated + [b""]),
                ("missing bytes", key, sealed[:-1], associated),
                ("added bytes", key, sealed + b"\0", associated),
            ))
            for name, candidate_key, candidate, candidate_aad in damaged:
                label = f"SIV rejects key={key_size} bytes={length} {name}"
                try:
                    AESSIV(candidate_key).decrypt(candidate, candidate_aad)
                except InvalidTag:
                    pass
                else:
                    raise AssertionError(label + ": reference accepted invalid input")
                add(label, "open", None, key=candidate_key, text=candidate, aad=candidate_aad)

    for key_size in (16, 24, 32):
        key = fixture_bytes(f"aes-key-{key_size}", key_size)
        for index in range(4):
            block = fixture_bytes(f"aes-block-{index}", 16)
            encryptor = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
            result = encryptor.update(block) + encryptor.finalize()
            add(f"AES key={key_size} block={index}", "aes", result, key=key, text=block)
        for length in lengths:
            text = fixture_bytes(f"cmac-{length}", length)
            mac = CMAC(algorithms.AES(key))
            mac.update(text)
            add(f"CMAC key={key_size} bytes={length}", "cmac", mac.finalize(), key=key, text=text)

    for length in (0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 129, 1024, 65535):
        text = fixture_bytes(f"sha256-{length}", length)
        add(f"SHA256 bytes={length}", "digest", hashlib.sha256(text).digest(), text=text)

    for key_size in (0, 1, 63, 64, 65, 131):
        key = fixture_bytes(f"hmac-key-{key_size}", key_size)
        for length in (0, 1, 31, 32, 55, 56, 63, 64, 65, 129, 1024):
            text = fixture_bytes(f"hmac-plain-{length}", length)
            result = hmac.new(key, text, hashlib.sha256).digest()
            add(f"HMAC key={key_size} bytes={length}", "hmac", result, key=key, text=text)

    passwords = (
        (b"", b""),
        (b"password", b"salt"),
        (b"pass\0word\xff", b"sa\0lt\x80"),
        ("password with \u00e9 and \U0001f512".encode("utf-8"), b"unicode-fixture"),
        (fixture_bytes("password64", 64), fixture_bytes("salt52", 52)),
        (fixture_bytes("password65", 65), fixture_bytes("salt53", 53)),
    )
    for index, (password, salt) in enumerate(passwords):
        for iterations in (1, 2, 3, 1023, 1024, 1025, 4096):
            result = hashlib.pbkdf2_hmac("sha256", password, salt, iterations, dklen=64)
            add(f"PBKDF2 case={index} iterations={iterations}", "derive", result,
                password=password, salt=salt, iterations=iterations)
    for size in (131, 1024):
        password, salt = fixture_bytes("long-password", size), fixture_bytes("long-salt", size)
        result = hashlib.pbkdf2_hmac("sha256", password, salt, 3, dklen=64)
        add(f"PBKDF2 password/salt bytes={size}", "derive", result, password=password, salt=salt, iterations=3)

    completed = subprocess.run(
        [options.luajit, "test/credential_crypto_oracle.lua"],
        cwd=ROOT,
        input=json.dumps(requests, separators=(",", ":")),
        text=True,
        encoding="utf-8",
        capture_output=True,
        timeout=240,
        check=False,
    )
    if completed.returncode != 0:
        raise AssertionError(f"LuaJIT oracle failed ({completed.returncode}):\n{completed.stderr}\n{completed.stdout}")
    actual = json.loads(completed.stdout)
    if len(actual) != len(expected):
        raise AssertionError(f"LuaJIT returned {len(actual)} results for {len(expected)} cases")
    rejected = 0
    errors = set()
    for label, result, wanted in zip(labels, actual, expected):
        if wanted is None:
            if result.get("ok") is not False or "value" in result or not result.get("error"):
                raise AssertionError(label + ": LuaJIT did not reject invalid input")
            rejected += 1
            errors.add(result["error"])
        elif result.get("ok") is not True or result.get("value") != wanted:
            raise AssertionError(label + ": LuaJIT result differs from the independent reference")
    if len(errors) != 1:
        raise AssertionError("Authentication failures did not use one generic error")
    print(f"Credential crypto interoperability: {len(expected)} checks passed, including {rejected} authentication rejections")


if __name__ == "__main__":
    main()
