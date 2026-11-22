#!/usr/bin/env python3
"""Pipelined requests must survive the loop budget: no connection may be closed.

uWS closes a socket that parses a second request while the first response is
still pending, so a request deferred past the budget used to kill every
connection that pipelined behind it (64 connections x 16 deep was enough)."""
import os, socket, subprocess, tempfile, threading, time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
BIN=os.environ.get('BKR_BIN',str(ROOT/'out/bkr'))
CONNECTIONS,DEPTH,SECONDS=128,16,2
with socket.socket() as sock:
    sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='bkr-http-pipeline-') as directory:
    with open(Path(directory)/'server.log','w+') as log:
        server=subprocess.Popen([BIN,'--no-prompt',f'--allow-net=127.0.0.1:{port}',
            str(ROOT/'tests/http-pipeline.js'),str(port)],stdout=log,stderr=log)
        try:
            for _ in range(100):
                if server.poll() is not None:
                    log.seek(0);raise AssertionError(log.read())
                try:
                    socket.create_connection(('127.0.0.1',port),timeout=.2).close();break
                except OSError:time.sleep(.03)
            else:raise AssertionError('server startup timeout')
            failures=[];served=[0];lock=threading.Lock()
            def worker(index):
                try:
                    conn=socket.create_connection(('127.0.0.1',port),timeout=10)
                    deadline=time.time()+SECONDS;batch=0
                    while time.time()<deadline:
                        paths=[f'/{index}-{batch}-{i}' for i in range(DEPTH)]
                        conn.sendall(b''.join(f'GET {p} HTTP/1.1\r\nHost: t\r\n\r\n'.encode() for p in paths))
                        data=b''
                        expected=[f'content-length: {len(p)}\r\n'.encode() for p in paths]
                        while data.count(b'HTTP/1.1 200')<DEPTH or not data.endswith(paths[-1].encode()):
                            chunk=conn.recv(1<<16)
                            if not chunk:raise AssertionError(f'connection {index} closed by server in batch {batch}')
                            data+=chunk
                        positions=[data.find(p.encode(),data.find(b'\r\n\r\n')) for p in paths]
                        assert positions==sorted(positions) and -1 not in positions,f'connection {index} replies out of order'
                        batch+=1
                    with lock:served[0]+=batch*DEPTH
                except Exception as error:
                    with lock:failures.append(str(error))
            threads=[threading.Thread(target=worker,args=(i,)) for i in range(CONNECTIONS)]
            [t.start() for t in threads];[t.join() for t in threads]
            assert not failures,f'{len(failures)} of {CONNECTIONS} connections failed, e.g. {failures[0]}'
            assert served[0]>=CONNECTIONS*DEPTH,'no pipelined traffic was served'
            print(f'HTTP pipelining: {CONNECTIONS} connections x {DEPTH} deep, {served[0]} ordered responses, none closed',flush=True)
        finally:
            server.terminate()
            try:server.wait(timeout=5)
            except subprocess.TimeoutExpired:server.kill();server.wait()
