#!/usr/bin/env python3
"""Exercise disconnect/reconnect bursts while request handlers occupy the loop."""
import os, re, shutil, socket, subprocess, tempfile, time, urllib.request
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
BIN=os.environ.get('BKR_BIN',str(ROOT/'out/bkr'))
WRK=os.environ.get('WRK_BIN') or shutil.which('wrk')
assert WRK, 'wrk is required for the HTTP overload regression'
with tempfile.TemporaryDirectory(prefix='bkr-http-fair-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    origin=f'http://127.0.0.1:{port}'
    with open(Path(directory)/'server.log','w+') as log:
        server=subprocess.Popen([BIN,'--no-prompt',f'--allow-net=127.0.0.1:{port}',
            f'--allow-read={ROOT}/tests',str(ROOT/'tests/http-fair.js'),str(port)],stdout=log,stderr=log)
        try:
            for _ in range(100):
                if server.poll() is not None:
                    log.seek(0);raise AssertionError(log.read())
                try:
                    with urllib.request.urlopen(origin+'/ready',timeout=.2) as response:
                        assert response.read()==b'x'*79040
                    break
                except OSError:time.sleep(.03)
            else:raise AssertionError('server startup timeout')
            lua=Path(directory)/'response.lua'
            lua.write_text('function response(status,headers,body) end\n')
            for rep in range(3):
                command=[WRK,'-t2','-c128','--timeout','2s','-s',str(lua),origin+'/slow']
                for seconds in [1,2]:
                    run=subprocess.run(command[:3]+[f'-d{seconds}s']+command[3:],capture_output=True,text=True,timeout=seconds+10)
                    assert run.returncode==0,run.stdout+run.stderr
                    assert 'Socket errors:' not in run.stdout,run.stdout
                    assert 'Non-2xx or 3xx responses:' not in run.stdout,run.stdout
                print(f'HTTP reconnect burst {rep+1}: zero errors',flush=True)
        finally:
            server.terminate()
            try:server.wait(timeout=5)
            except subprocess.TimeoutExpired:server.kill();server.wait()
