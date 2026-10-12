#!/usr/bin/env python3
"""Profile fixed 8 KiB stream bodies. Run sample, ops, or ablate.

sample: macOS CPU samples of bench/servers/bkr.js, optimized threaded build.
ops: diagnostic bkr-perf-prof (switch dispatch); instruction
     counts only, not production timings. Sends 1000 requests per case.
ablate: fresh server per case, 1s warm-up and 2s measured, wrk -t2 -c128.

BKR_BIN and BKR_PROFILE_BIN can select different binaries. Results go in bench/.
Node stream variants use Readable.fromWeb; /direct uses native HTTP writes.
"""
import argparse, collections, http.client, json, os, re, subprocess, tempfile, time
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
BINARY=os.environ.get('BKR_BIN',str(ROOT/'out/bkr-perf'))
PORT=18159
PREFIX = "const chunk1=new Uint8Array(8192).fill(120), chunk8=new Uint8Array(1024).fill(120), chunk64=new Uint8Array(128).fill(120);\n"
def source(runtime):
    cases=[]
    for route,count in [('one',1),('batch',8),('stream',8),('many',64)]:
        pull=f"for(let i=0;i<{count};i++)c.enqueue(chunk{count});c.close();" if route=='batch' else f"if(n++==={count})c.close();else c.enqueue(chunk{count});"
        stream="new ReadableStream({pull(c){"+pull+"}})"
        send=f"Readable.fromWeb({stream}).pipe(res)" if runtime=='node' else f"new Response({stream})"
        cases.append(f'case "/{route}":{{let n=0;return {send};}}')
    bytes_body='res.end(chunk1)' if runtime=='node' else 'new Response(chunk1)'
    switch='switch('+('req.url' if runtime=='node' else 'new URL(req.url).pathname')+'){case "/bytes":return '+bytes_body+';'+''.join(cases)
    if runtime=='node':
        switch+='case "/direct":for(let i=0;i<8;i++)res.write(chunk8);return res.end();'
        return 'import http from "node:http";import {Readable} from "node:stream";\n'+PREFIX+'http.createServer((req,res)=>{'+switch+'}}).listen(Number(process.argv[2]),"127.0.0.1");'
    if runtime=='bkr':
        return 'import {serve} from "http";import {args,exit} from "process";\n'+PREFIX+'serve({port:Number(args[0]),hostname:"127.0.0.1",onListen(){},fetch(req){'+switch+'case "/stop":exit();}}});'
    return PREFIX+'Bun.serve({port:Number(Bun.argv[2]),hostname:"127.0.0.1",fetch(req){'+switch+'}}});'
SOURCES={runtime:source(runtime) for runtime in ['bkr','bun','node']}
ROUTES=['bytes','one','batch','stream','many']

def start(runtime,script,log,binary=BINARY):
    cmd=[binary,'--no-sandbox','--allow-net',str(script),str(PORT),str(ROOT/'bench/payload.txt')] if runtime=='bkr' else [runtime,str(script),str(PORT)]
    p=subprocess.Popen(cmd,stdout=subprocess.DEVNULL,stderr=log)
    for _ in range(200):
        if p.poll() is not None: raise RuntimeError('server exited')
        try:
            c=http.client.HTTPConnection('127.0.0.1',PORT,timeout=.2);c.request('GET','/hello' if script.parent.name=='servers' else '/bytes');r=c.getresponse();assert r.status==200 and len(r.read())==(11 if script.parent.name=='servers' else 8192);c.close();return p
        except (OSError,http.client.HTTPException):time.sleep(.03)
        except BaseException:
            p.terminate();p.wait();raise
    p.terminate();p.wait()
    raise RuntimeError('server startup failed')

def wrk(route,duration):
    out=subprocess.check_output(['wrk','-t2','-c128',f'-d{duration}s','--latency',f'http://127.0.0.1:{PORT}/{route}'],text=True)
    errors = re.search(r'Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)', out)
    socket_errors=sum(map(int, errors.groups())) if errors else 0
    bad=re.search(r'Non-2xx or 3xx responses: (\d+)',out)
    latency={}
    for percent in [50,99]:
        v,u=re.search(rf'{percent}%\s+([\d.]+)(us|ms|s)',out).groups();latency[str(percent)]=float(v)*{'us':.001,'ms':1,'s':1000}[u]
    return {'req_s':float(re.search(r'Requests/sec:\s+([\d.]+)',out).group(1)),'latency_ms':latency,'socket_errors':socket_errors,'http_errors':int(bad.group(1)) if bad else 0}

def sample_self(path):
    text=Path(path).read_text(); graph=text.split('Call graph:\n')[1].split('Total number in stack')[0]
    frames=[]; counts=collections.Counter();total=0
    for line in graph.splitlines():
        if 'Thread_' in line:
            if total:break
            continue
        m=re.match(r'([ +!:|]+)(\d+) (.+?)  \(in ',line)
        if not m:continue
        prefix,count,name=m.groups();count=int(count);depth=len(prefix)
        if not frames:total=count
        while frames and frames[-1][0]>=depth:frames.pop()
        if frames:counts[frames[-1][1]]-=count
        counts[name]+=count;frames.append((depth,name))
    assert sum(counts.values())==total and all(n>=0 for n in counts.values()),(total,counts)
    return {'samples':total,'self_samples':dict(counts.most_common())}

parser=argparse.ArgumentParser();parser.add_argument('mode',choices=['sample','ablate','ops'])
parser.add_argument('--prefix',default='stream-profile',help='Result filename prefix in bench/')
parser.add_argument('--route',default='stream',help='Workload route for sample mode')
args=parser.parse_args()
if not re.fullmatch(r'[a-zA-Z0-9_-]+',args.prefix):parser.error('prefix must be a filename component')
results={}
with tempfile.TemporaryDirectory(prefix='bkr-stream-profile-',dir='/private/tmp') as temp:
    temp=Path(temp)
    for runtime,script_source in SOURCES.items():(temp/(runtime+'.mjs')).write_text(script_source)
    if args.mode=='sample':
        for rep in range(3):
            with (temp/'server.log').open('w') as log:
                p=start('bkr',ROOT/'bench/servers/bkr.js',log)
                try:
                    wrk(args.route,1)
                    w=subprocess.Popen(['wrk','-t2','-c128','-d5s',f'http://127.0.0.1:{PORT}/{args.route}'],stdout=subprocess.DEVNULL)
                    time.sleep(.5)
                    path=f'/private/tmp/bkr-stream-current-{rep}.sample.txt'
                    subprocess.run(['sample',str(p.pid),'2','-file',path],capture_output=True,check=True)
                    w.wait();results[str(rep)]=sample_self(path)
                    print('sample',rep,results[str(rep)]['samples'],flush=True)
                finally:p.terminate();p.wait()
    elif args.mode=='ablate':
        for runtime in SOURCES:
            results[runtime]={}
            for route in ROUTES+(['direct'] if runtime=='node' else []):
                with (temp/'server.log').open('w') as log:
                    p=start(runtime,temp/(runtime+'.mjs'),log)
                    try:
                        wrk(route,1);results[runtime][route]=wrk(route,2)
                        print(runtime,route,results[runtime][route],flush=True)
                    finally:p.terminate();p.wait()
    else:
        for route in ['zero']+ROUTES:
            logfile=temp/'server.log'
            with logfile.open('w') as log:
                p=start('bkr',temp/'bkr.mjs',log,os.environ.get('BKR_PROFILE_BIN',str(ROOT/'out/bkr-perf-prof')))
                try:
                    c=http.client.HTTPConnection('127.0.0.1',PORT,timeout=10)
                    if route!='zero':
                        for _ in range(1000):
                            c.request('GET','/'+route);r=c.getresponse();assert len(r.read())==8192
                    c.request('GET','/stop');
                    try:c.getresponse()
                    except http.client.HTTPException:pass
                    c.close();p.wait(timeout=10)
                finally:
                    if p.poll() is None:p.terminate();p.wait()
            data=logfile.read_text();results[route]={'total_dispatches':int(re.search(r'total_dispatches=(\d+)',data).group(1))}
            opcode_prefix='stream-opcodes' if args.prefix=='stream-profile' else args.prefix+'-opcodes'
            (ROOT/'bench'/f'{opcode_prefix}-{route}.txt').write_text(data)
            print(route,results[route],flush=True)
(ROOT/'bench'/f'{args.prefix}-{args.mode}.json').write_text(json.dumps(results,indent=2)+'\n')
