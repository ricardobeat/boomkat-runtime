#!/usr/bin/env python3
"""Native method/path routing, static responses, params and async lifetimes."""
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import urllib.request
import urllib.error
ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('BKR_BIN', ROOT / 'out/bkr'))
with tempfile.TemporaryDirectory(prefix='bkr-http-routes-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    with open(Path(directory) / 'server.log', 'w+') as log:
        proc = subprocess.Popen([str(BIN), '--no-prompt', f'--allow-net=127.0.0.1:{port}',
            str(ROOT / 'tests/http-routes.js'), str(port)], stdout=log, stderr=log)
        try:
            for _ in range(100):
                try:
                    urllib.request.urlopen(f'http://127.0.0.1:{port}/missing', timeout=.2)
                    break
                except urllib.error.HTTPError: break
                except OSError:
                    if proc.poll() is not None: log.seek(0); raise AssertionError(log.read())
                    import time
                    time.sleep(.02)
            def call(path, method='GET', data=None, status=200):
                req = urllib.request.Request(f'http://127.0.0.1:{port}' + path, method=method, data=data)
                try: response = urllib.request.urlopen(req, timeout=5)
                except urllib.error.HTTPError as error: response = error
                body = response.read()
                assert response.status == status, (path, method, response.status, body)
                return body
            assert call('/items/new') == b'exact'
            assert json.loads(call('/items/123?hello=world')) == {'id':'123','query':'?hello=world'}
            assert json.loads(call('/items/a%2Fb'))['id'] == 'a/b'
            assert json.loads(call('/items/h%C3%A9llo'))['id'] == 'héllo'
            assert json.loads(call('/items/%FF'))['id'] == '\ufffd'
            assert json.loads(call('/items/a+b'))['id'] == 'a+b'
            assert json.loads(call('/pairs/one/two')) == {'first':'one','second':'two'}
            assert json.loads(call('/special/one/two')) == {'__proto__':'one','constructor':'two'}
            assert call('/api/exact') == b'exact-api'
            assert call('/api/value') == b'parameter:value'
            assert call('/api/value/extra') == b'wildcard'
            assert call('/method') == b'get'
            assert call('/method','POST',b'',202) == b'post'
            assert call('/method','DELETE') == b'delete'
            assert call('/method','HEAD') == b''
            for _ in range(3): assert call('/cached',status=201) == b'cached'
            assert call('/cached','HEAD',status=201) == b''
            assert call('/bytes','POST',b'') == bytes([0,1,255])
            assert call('/throw/1',status=503) == b'route error'
            assert call('/reject/1',status=503) == b'async route error'
            assert call('/disabled',status=404) == b'fallback'
            assert call('/missing',status=404) == b'fallback'
            def concurrent_request(i):
                name=f'request-{i}'
                payload=f'body-{i}'.encode()
                assert json.loads(call('/items/'+name,'POST',payload)) == {'id':name,'body':payload.decode()}
                assert call('/async/'+name) == name.encode()
            with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
                list(pool.map(concurrent_request,range(256)))
            assert proc.poll() is None
        finally:
            proc.terminate()
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill();proc.wait()
            log.seek(0)
            output = log.read()
            assert 'AddressSanitizer' not in output, output
print('Native routes: methods, precedence, cached bodies, decoded params, errors and async lifetimes: passed')
