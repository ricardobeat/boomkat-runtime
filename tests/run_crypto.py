#!/usr/bin/env python3
"""Crypto API and independent Argon2id output validation using OpenSSL 3.2+."""
import base64,os,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BIN=Path(os.environ.get('BKR_BIN',ROOT/'out/bkr'))
r=subprocess.run([str(BIN),'--no-sandbox','--no-prompt',str(ROOT/'tests/crypto.js')],capture_output=True,text=True,timeout=60)
assert r.returncode==0,r.stdout+r.stderr
print('Native crypto API: passed')
openssl=os.environ.get('OPENSSL_BIN') or ('/opt/homebrew/opt/openssl@3/bin/openssl' if Path('/opt/homebrew/opt/openssl@3/bin/openssl').exists() else shutil.which('openssl'))
if openssl:
 algorithms=subprocess.run([openssl,'list','-kdf-algorithms'],capture_output=True,text=True)
 if 'ARGON2ID' in algorithms.stdout:
  phc=r.stdout.splitlines()[0].split('$');salt=base64.b64decode(phc[4]+'='*(-len(phc[4])%4));expected=base64.b64decode(phc[5]+'='*(-len(phc[5])%4))
  reference=subprocess.run([openssl,'kdf','-keylen','32','-binary','-kdfopt','pass:interoperability password','-kdfopt','hexsalt:'+salt.hex(),'-kdfopt','iter:2','-kdfopt','lanes:1','-kdfopt','memcost:19456','ARGON2ID'],capture_output=True,timeout=30)
  assert reference.returncode==0,reference.stderr
  assert reference.stdout==expected,'C3/OpenSSL Argon2id mismatch'
  print('C3 Argon2id matches independent OpenSSL: passed')
 else:print('Independent comparison skipped: OpenSSL has no ARGON2ID KDF')
else:print('Independent comparison skipped: OpenSSL not found')
