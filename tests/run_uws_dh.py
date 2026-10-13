#!/usr/bin/env python3
"""Check the shim's OpenSSL 3 parameter loading and ownership paths."""
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SSL = Path(subprocess.check_output(["brew", "--prefix", "openssl@3"], text=True).strip())
target = re.search(r'"macos-min-version"\s*:\s*"([0-9.]+)"', (ROOT / "project.json").read_text())[1]
with tempfile.TemporaryDirectory(prefix="bkr-dh-") as directory:
    path = Path(directory)
    dh, ec, invalid = path / "dh.pem", path / "ec.pem", path / "invalid.pem"
    invalid.write_text("not a PEM parameter file")
    for algorithm, option, output in [("DH", "group:ffdhe2048", dh), ("EC", "ec_paramgen_curve:P-256", ec)]:
        subprocess.run([str(SSL / "bin/openssl"), "genpkey", "-genparam", "-algorithm", algorithm,
                        "-pkeyopt", option, "-out", str(output)], check=True, capture_output=True)
    obj, binary = path / "test.o", path / "test"
    subprocess.run(["clang", "-std=c11", "-Werror", f"-mmacosx-version-min={target}",
                    "-I" + str(ROOT / "vendor/uWebSockets/uSockets/src"), "-c",
                    str(ROOT / "tests/uws-dh.c"), "-o", str(obj)], check=True)
    subprocess.run(["clang++", f"-mmacosx-version-min={target}", str(obj),
                    str(ROOT / "vendor/libuws_shim.a"), str(SSL / "lib/libssl.a"),
                    str(SSL / "lib/libcrypto.a"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(dh), str(invalid), str(ec)], check=True)
print("OpenSSL DH parameters: valid, malformed, wrong type, missing file and context cleanup: passed")
