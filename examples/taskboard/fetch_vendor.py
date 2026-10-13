#!/usr/bin/env python3
"""Download the complete pinned Preact package directly; no npm required."""
import base64,hashlib,io,tarfile,urllib.request
from pathlib import Path,PurePosixPath
VERSION='11.0.1'
INTEGRITY='TNNwEq++jYNHy747LziCjPRVgEwnLSOIOAw/oYcjI3Tdnubx2EXtt76I0an8PATvUWtx/DX1kFIg1eFN+O/fkw=='
URL=f'https://registry.npmjs.org/preact/-/preact-{VERSION}.tgz'

def main():
 data=urllib.request.urlopen(URL,timeout=30).read()
 if base64.b64encode(hashlib.sha512(data).digest()).decode()!=INTEGRITY:
  raise RuntimeError('Preact archive integrity mismatch')
 root=Path(__file__).resolve().parent/'vendor/preact'
 with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as archive:
  for member in archive.getmembers():
   path=PurePosixPath(member.name)
   if path.parts[0]!='package' or '..' in path.parts:raise RuntimeError('Invalid archive path')
   if not member.isfile():continue
   target=root.joinpath(*path.parts[1:]);target.parent.mkdir(parents=True,exist_ok=True)
   target.write_bytes(archive.extractfile(member).read())
 print(f'Preact {VERSION}: full sources, browser modules, types and license downloaded to {root}')
if __name__=='__main__':main()
