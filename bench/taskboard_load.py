#!/usr/bin/env python3
"""Load the real Taskboard API using disposable accounts/data and wrk.

No application shortcuts: requests use real session cookies and CSRF tokens.
Fixtures are bulk-populated outside measured runs; the server keeps its normal
WAL/FULL durability, authentication, authorization and image size checks.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import random
import re
import socket
import shutil
import sqlite3
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import zlib
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'examples/taskboard'
BIN = Path(os.environ.get('BKR_BIN', ROOT / 'out/bkr')).resolve()
WORKLOADS = ['asset', 'board', 'image', 'update', 'mixed', 'upload_delete']
LABELS = {'asset':'JS entry module', 'board':'Board JSON (200 cards)', 'image':'Image read (128 KiB)',
          'update':'Card update (250 B)', 'mixed':'Mixed 70% board / 20% image / 10% update',
          'upload_delete':'Image upload + delete (128 KiB)'}
PASSWORD = 'disposable taskboard load test password'

class Client:
    def __init__(self, origin):
        self.origin, self.cookie, self.csrf = origin, '', ''

    def call(self, path, method='GET', data=None, expected=200, raw=False):
        headers = {'Origin':self.origin,'Cookie':self.cookie,'X-CSRF-Token':self.csrf}
        if data is not None:
            data = json.dumps(data).encode()
            headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(self.origin+path, data=data, headers=headers, method=method)
        try:
            response = urllib.request.urlopen(request, timeout=10)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            payload = response.read()
            if expected is not None:
                assert response.status == expected, (path,response.status,payload[:200])
            if response.headers.get('Set-Cookie'):
                self.cookie = response.headers['Set-Cookie'].split(';',1)[0]
            result = payload if raw else json.loads(payload)
            if not raw and isinstance(result,dict) and 'csrf' in result:
                self.csrf = result['csrf']
            return response.status, result


def png(size=131072):
    def chunk(name, data):
        return struct.pack('>I',len(data))+name+data+struct.pack('>I',zlib.crc32(name+data))
    rng = random.Random(41)
    width, height = 128, 128
    pixels = b''.join(b'\x00'+rng.randbytes(width*3) for _ in range(height))
    data = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))
    data += chunk(b'IDAT',zlib.compress(pixels))
    data += chunk(b'tEXt',b'Comment\x00'+b'x'*(size-len(data)-12-12-8))
    data += chunk(b'IEND',b'')
    assert len(data)==size
    return data


def process_stats(pid):
    out = subprocess.check_output(['ps','-o','rss=,time=','-p',str(pid)], text=True).strip().split()
    rss = int(out[0])/1024
    parts = out[1].split(':')
    cpu = sum(float(value)*60**i for i,value in enumerate(reversed(parts)))
    return rss,cpu


def run_checked(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    assert result.returncode==0, result.stdout+result.stderr
    return result.stdout


def parse_wrk(output):
    def match(pattern):
        found = re.search(pattern,output)
        if not found:
            raise ValueError('Missing wrk metric: '+pattern+'\n'+output)
        return found
    result = {'rps':float(match(r'Requests/sec:\s+([\d.]+)')[1])}
    units = {'us':.001,'ms':1,'s':1000}
    for label,pct in [('p50',50),('p90',90),('p99',99)]:
        value,unit = match(rf'{pct}%\s+([\d.]+)(us|ms|s)').groups()
        result[label+'_ms'] = float(value)*units[unit]
    latency = match(r'Latency\s+([\d.]+)(us|ms|s)\s+[\d.]+(?:us|ms|s)\s+([\d.]+)(us|ms|s)')
    result['mean_ms'] = float(latency[1])*units[latency[2]]
    result['max_ms'] = float(latency[3])*units[latency[4]]
    total = match(r'(\d+) requests in ([\d.]+)s,').groups()
    result['requests'],result['duration_s'] = int(total[0]),float(total[1])
    statuses = {int(k):int(v) for k,v in re.findall(r'STATUS (\d+) (\d+)',output)}
    result['statuses'] = statuses
    socket_errors = re.search(r'Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)',output)
    result['socket_errors'] = dict(zip(['connect','read','write','timeout'],map(int,socket_errors.groups()))) if socket_errors else {}
    http_errors = re.search(r'Non-2xx or 3xx responses: (\d+)',output)
    result['errors'] = (int(http_errors[1]) if http_errors else 0)+sum(result['socket_errors'].values())
    return result


LUA = '''
local users = USERS
local origin = ORIGIN
local image = IMAGE
local kind = KIND
local description = string.rep("x",250)
local threads = {}
function setup(thread)
    thread:set("slot",#threads)
    table.insert(threads,thread)
end
function init(args)
    counter=0
    pending_deletes={}
    for code=100,599 do _G["status_"..code]=0 end
end
function request()
    counter=counter+1
    local u=users[((counter+slot)%#users)+1]
    local method,path,body="GET","/app.js",nil
    local headers={Cookie=u.cookie,["X-CSRF-Token"]=u.csrf,Origin=origin}
    local action=kind
    if action=="mixed" then
        local i=counter%10
        action=i<7 and "board" or (i<9 and "image" or "update")
    end
    if action=="board" then
        path="/api/boards/"..u.boards[(math.floor(counter/#users)+slot)%#u.boards+1]
    elseif action=="image" then
        path="/api/images/"..u.images[(counter+slot)%#u.images+1]
    elseif action=="update" then
        method="PATCH"
        path="/api/cards/"..u.cards[(counter*17+slot*31)%#u.cards+1]
        headers["Content-Type"]="application/json"
        body='{"description":"'..description..'"}'
    elseif action=="upload_delete" then
        if #pending_deletes>0 then
            method="DELETE"
            path="/api/images/"..table.remove(pending_deletes)
        else
            method="POST"
            -- Reserve independent card sets by worker; at most 64 uploads
            -- can be outstanding per worker at the tested 128 connections.
            path="/api/cards/"..u.cards[(counter*17+slot*31)%#u.cards+1].."/images"
            headers["Content-Type"]="image/png"
            headers["X-File-Name"]="load-upload-image.png"
            body=image
        end
    end
    return wrk.format(method,path,headers,body)
end
function response(status,headers,body)
    _G["status_"..status]=(_G["status_"..status] or 0)+1
    if kind=="upload_delete" and status==201 then
        local id=string.match(body,'"id":(%d+)')
        -- All fixture users are also members of both load-test teams, so
        -- the first authenticated session can delete any queued upload.
        if id then table.insert(pending_deletes,id) end
    end
end
function done(summary,latency,requests)
    for code=100,599 do
        local count=0
        for _,thread in ipairs(threads) do count=count+(thread:get("status_"..code) or 0) end
        if count>0 then io.write("STATUS "..code.." "..count.."\\n") end
    end
end
'''


def lua_string(value):
    # Fixture tokens/URLs are ASCII; JSON string quoting also quotes Lua strings.
    return json.dumps(value)


def lua_users(users):
    def numbers(values):
        return '{'+','.join(map(str,values))+'}'
    return '{'+','.join('{cookie='+lua_string(u['cookie'])+',csrf='+lua_string(u['csrf'])+
                       ',boards='+numbers(u['boards'])+',cards='+numbers(u['cards'])+
                       ',images='+numbers(u['images'])+'}' for u in users)+'}'


def table(results,connections):
    cols=['Workload']+[f'req/s @{c}' for c in connections]+[f'p50 / p99 ms @{max(connections)}','Errors',f'Peak RSS MiB @{max(connections)}']
    lines=['| '+' | '.join(cols)+' |','| '+' | '.join(['---']+['---:']*(len(cols)-1))+' |']
    for kind in WORKLOADS:
        rows={r['connections']:r for r in results if r['workload']==kind}
        high=rows[max(connections)]
        lines.append('| '+LABELS[kind]+' | '+' | '.join(f"{rows[c]['rps']:,.0f}" for c in connections)+
                     f" | {high['p50_ms']:.2f} / {high['p99_ms']:.2f} | {sum(r['errors'] for r in rows.values())} | {high['peak_rss_mib']:.1f} |")
    return '\n'.join(lines)


def main():
    global WORKLOADS, BIN
    bkr_binary=BIN
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime',choices=['bkr','bun'],default='bkr')
    parser.add_argument('--seconds',type=int,default=8)
    parser.add_argument('--warmup',type=int,default=1)
    parser.add_argument('--connections',default='1,32,128')
    parser.add_argument('--workloads',default=','.join(WORKLOADS))
    parser.add_argument('--close-connections',action='store_true')
    parser.add_argument('--byte-json',action='store_true',help='Diagnostic copy of the app encodes JSON as Uint8Array')
    parser.add_argument('--output',type=Path,default=ROOT/'bench/taskboard-load.json')
    parser.add_argument('--profile-dir',type=Path,help='Diagnostic CPU samples and server logs; timings are instrumented')
    opts=parser.parse_args()
    if opts.profile_dir: opts.profile_dir.mkdir(parents=True,exist_ok=True)
    if opts.runtime=='bun' and opts.byte_json:
        parser.error('--byte-json is a BKR-only diagnostic')
    if opts.runtime=='bun':
        BIN=Path(os.environ.get('BUN_BIN') or shutil.which('bun')).resolve()
    connections=[int(c) for c in opts.connections.split(',')]
    WORKLOADS=opts.workloads.split(',')
    assert all(kind in LABELS for kind in WORKLOADS)
    assert opts.seconds>0 and opts.warmup>=0 and all(c>0 for c in connections)
    with tempfile.TemporaryDirectory(prefix='bkr-taskboard-load-') as directory:
        directory=Path(directory)
        app=APP
        if opts.byte_json:
            app=directory/'app'
            shutil.copytree(APP,app,ignore=shutil.ignore_patterns('data'))
            server=app/'lib/http.ts'
            text=server.read_text()
            assert 'new Response(JSON.stringify(value)' in text
            server.write_text(text.replace('new Response(JSON.stringify(value)','new Response(enc.encode(JSON.stringify(value))',1))
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        origin=f'http://127.0.0.1:{port}'
        proc=None
        log=None
        def stop():
            nonlocal proc,log
            if proc:
                proc.terminate()
                try:proc.wait(timeout=5)
                except subprocess.TimeoutExpired:proc.kill();proc.wait()
                proc=None
            if log:log.close();log=None
        def start(runtime=opts.runtime):
            nonlocal proc,log
            stop()
            log=open(directory/'server.log','w+')
            command=([str(BIN),str(app/'server.bun.ts'),str(port),str(directory)] if runtime=='bun' else
                [str(bkr_binary),'--no-prompt',f'--allow-net=127.0.0.1:{port}',
                f'--allow-read={app},{directory}',f'--allow-write={directory}',str(app/'server.ts'),str(port),str(directory)])
            env=os.environ.copy()
            if runtime=='bun': env['TASKBOARD_BENCH_ASSET']=str(directory/'common-app.js')
            proc=subprocess.Popen(command,stdout=log,stderr=log,env=env)
            for _ in range(100):
                if proc.poll() is not None:
                    log.seek(0);raise RuntimeError(log.read())
                try:
                    with urllib.request.urlopen(origin,timeout=.2):return
                except (OSError,urllib.error.URLError):time.sleep(.05)
            raise RuntimeError('Server startup timed out')
        try:
            if opts.runtime=='bun':
                # Capture the baseline browser artifact outside measured intervals.
                # API implementation, native static routes and payload sizes match.
                start('bkr')
                with urllib.request.urlopen(origin+'/app.js') as response:
                    (directory/'common-app.js').write_bytes(response.read())
                stop()
            start()
            clients=[];users=[]
            for n in range(10):
                client=Client(origin)
                _,account=client.call('/api/register','POST',{'name':f'Load User {n+1}',
                    'email':f'load{n+1}@example.com','password':PASSWORD},201)
                _,workspace=client.call('/api/workspace')
                clients.append(client)
                users.append({'id':account['user']['id'],'email':account['user']['email'],
                    'cookie':client.cookie,'csrf':client.csrf,'team':workspace['teams'][0]['id'],
                    'boards':[workspace['boards'][0]['id']]})
            # Two team owners; all ten fixture accounts can access either team.
            # This also makes asynchronous upload/delete response queues safe.
            for owner_index in [0,5]:
                owner=users[owner_index]
                for member in users:
                    clients[owner_index].call(f"/api/teams/{owner['team']}/members",'POST',{'email':member['email']})
                _,board=clients[owner_index].call('/api/boards','POST',{'team_id':owner['team'],'name':'Load Project'},201)
                owner['boards'].append(board['id'])
            board_ids=users[0]['boards']+users[5]['boards']
            data=png()
            with sqlite3.connect(directory/'taskboard.sqlite') as db:
                db.execute('PRAGMA foreign_keys=ON')
                for board_id in board_ids:
                    lists=[r[0] for r in db.execute('SELECT id FROM lists WHERE board_id=? ORDER BY position',(board_id,))]
                    db.execute('DELETE FROM cards WHERE list_id IN (SELECT id FROM lists WHERE board_id=?)',(board_id,))
                    for n in range(200):
                        db.execute('INSERT INTO cards(list_id,title,description,color,created_by,created,updated) VALUES(?,?,?,?,?,?,?)',
                            (lists[n%3],f'Load card {n+1:03}',('A real project description. '*10)[:250],
                             ['none','mint','peach','lavender','sky'][n%5],users[0]['id'],1_790_000_000_000,1_790_000_000_000))
                    cards=[r[0] for r in db.execute('SELECT c.id FROM cards c JOIN lists l ON l.id=c.list_id WHERE l.board_id=? ORDER BY c.id',(board_id,))]
                    for card in cards[:4]:
                        db.execute('INSERT INTO images(card_id,name,mime,data,size,created_by,created) VALUES(?,?,?,?,?,?,?)',
                            (card,'fixture.png','image/png',data,len(data),users[0]['id'],1_790_000_000_000))
                db.commit()
                all_cards=[r[0] for r in db.execute('SELECT c.id FROM cards c JOIN lists l ON l.id=c.list_id WHERE l.board_id IN (?,?,?,?) ORDER BY c.id',board_ids)]
                all_images=[r[0] for r in db.execute('SELECT id FROM images ORDER BY id')]
                for u in users:
                    u['boards']=board_ids[:];u['cards']=all_cards[:];u['images']=all_images[:]
                pragma={'journal_mode':db.execute('PRAGMA journal_mode').fetchone()[0],
                        'synchronous':db.execute('PRAGMA synchronous').fetchone()[0]}
            _,board_payload=clients[0].call(f'/api/boards/{board_ids[0]}',raw=True)
            _,asset=clients[0].call('/app.js',raw=True)
            _,blob=clients[0].call(f'/api/images/{all_images[0]}',raw=True)
            assert blob==data
            assert len(json.loads(board_payload)['cards'])==200
            fixture={'accounts':10,'shared_teams':2,'boards':4,'cards_per_board':200,'images':16,
                     'board_json_bytes':len(board_payload),'asset_bytes':len(asset),'image_bytes':len(data),**pragma}
            report={'date_utc':datetime.now(timezone.utc).isoformat(),'binary':str(BIN),
                    'profiled':bool(opts.profile_dir),
                    'runtime':opts.runtime,'runtime_version':run_checked([str(BIN),'--version']).strip() if opts.runtime=='bun' else None,
                    'asset_sha256':hashlib.sha256(asset).hexdigest(),
                    'binary_sha256':hashlib.sha256(BIN.read_bytes()).hexdigest(),
                    'runtime_commit':run_checked(['git','rev-parse','HEAD'],cwd=ROOT).strip(),
                    'working_tree_dirty':bool(run_checked(['git','status','--porcelain'],cwd=ROOT).strip()),
                    'system':run_checked(['sw_vers']).strip(),'wrk':subprocess.run(['wrk','-v'],capture_output=True,text=True).stdout.splitlines()[0],
                    'fixture':fixture,'seconds_per_run':opts.seconds,'warmup_seconds':opts.warmup,
                    'client_threads':2,'response_body':'bytes' if opts.byte_json else 'string','close_connections':opts.close_connections,'results':[]}
            print('Fixture: '+json.dumps(fixture),flush=True)
            image_literal=''.join('\\%03d'%byte for byte in data)
            for kind in WORKLOADS:
                for c in connections:
                    start()
                    # Clear upload leftovers outside measured intervals.
                    with sqlite3.connect(directory/'taskboard.sqlite') as db:
                        db.execute("DELETE FROM images WHERE name LIKE 'load-upload-%'")
                    script=directory/'workload.lua'
                    source=LUA
                    if opts.close_connections:
                        source=source.replace('Origin=origin}', 'Origin=origin,Connection="close"}')
                    script.write_text(source.replace('local users = USERS','local users = '+lua_users(users))
                        .replace('local origin = ORIGIN','local origin = '+lua_string(origin))
                        .replace('local image = IMAGE','local image = "'+image_literal+'"')
                        .replace('local kind = KIND','local kind = '+lua_string(kind)))
                    command=['wrk',f'-t{min(2,c)}',f'-c{c}','--latency','--timeout','2s','-s',str(script),origin]
                    print(f'Running {kind}: {c} connections',flush=True)
                    if opts.warmup:
                        run_checked(command[:3]+[f'-d{opts.warmup}s']+command[3:],timeout=opts.warmup+10)
                    if kind=='upload_delete':
                        with sqlite3.connect(directory/'taskboard.sqlite') as db:
                            db.execute("DELETE FROM images WHERE name LIKE 'load-upload-%'")
                    baseline,cpu0=process_stats(proc.pid)
                    profile=None
                    if opts.profile_dir:
                        profile=subprocess.Popen(['sample',str(proc.pid),'2','-file',str(opts.profile_dir/f'{kind}-{c}.sample.txt')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                    begin=time.monotonic()
                    load=subprocess.Popen(command[:3]+[f'-d{opts.seconds}s']+command[3:],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                    peak=baseline
                    while load.poll() is None:
                        if proc.poll() is not None:
                            load.terminate();log.seek(0);raise RuntimeError('Server exited: '+log.read())
                        rss,_=process_stats(proc.pid);peak=max(peak,rss)
                        if rss>2048:
                            load.terminate();raise RuntimeError('Server RSS exceeded 2 GiB')
                        if time.monotonic()-begin>opts.seconds+10:
                            load.kill();raise RuntimeError('wrk timed out')
                        time.sleep(.2)
                    output,err=load.communicate(timeout=5)
                    if profile: profile.wait(timeout=10)
                    if opts.profile_dir:
                        log.flush()
                        shutil.copyfile(directory/'server.log',opts.profile_dir/f'{kind}-{c}.server.log')
                    assert load.returncode==0,output+err
                    _,cpu1=process_stats(proc.pid)
                    elapsed=time.monotonic()-begin
                    row=parse_wrk(output)
                    row.update(workload=kind,connections=c,peak_rss_mib=round(peak,2),
                               idle_rss_mib=round(baseline,2),cpu_percent=round(100*(cpu1-cpu0)/elapsed,1),
                               raw=output)
                    if err: row['raw_stderr']=err
                    report['results'].append(row)
                    opts.output.write_text(json.dumps(report,indent=2)+'\n')
                    print(f"  {row['rps']:,.0f} req/s; p50 {row['p50_ms']:.2f} ms; p99 {row['p99_ms']:.2f} ms; {row['errors']} errors; RSS {peak:.1f} MiB",flush=True)
            # Separate auth protection checks: these 429s are intentional.
            start()
            def login(n):
                client=Client(origin);user=users[n%len(users)]
                status,result=client.call('/api/login','POST',{'email':user['email'],'password':PASSWORD},expected=None)
                return status,result
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                burst=list(pool.map(login,range(32)))
            report['login_burst']={'requests':32,'concurrency':8,'statuses':{str(s):sum(status==s for status,_ in burst) for s in sorted({s for s,_ in burst})},
                'reasons':{reason:sum(r.get('error')==reason for _,r in burst) for reason in sorted({r['error'] for _,r in burst if 'error'in r})}}
            start()
            sequential=[login(n) for n in range(45)]
            report['login_rate_limit']={'requests':45,'statuses':{str(s):sum(status==s for status,_ in sequential) for s in sorted({s for s,_ in sequential})}}
            with sqlite3.connect(directory/'taskboard.sqlite') as db:
                assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
                assert not db.execute('PRAGMA foreign_key_check').fetchall()
                assert db.execute('SELECT count(*) FROM cards WHERE title LIKE "Load card %"').fetchone()[0]==800
                invalid=db.execute('SELECT count(*) FROM images WHERE length(data)!=size').fetchone()[0]
                assert invalid==0
            report['integrity']='SQLite integrity, foreign keys, fixture card count and BLOB lengths passed'
            opts.output.write_text(json.dumps(report,indent=2)+'\n')
            markdown=table(report['results'],connections)
            report_path=opts.output.with_suffix('.md')
            report_path.write_text('# Taskboard load test\n\n'+markdown+'\n\n'+json.dumps(fixture)+'\n\n'
                'Loopback wrk; real sessions and CSRF checks; isolated SQLite database; default WAL/FULL durability. '
                f'{opts.seconds}s measured and {opts.warmup}s warmup per run, fresh server per case. '
                'Upload/delete throughput counts both API operations, about two requests per completed image cycle. '
                'Peak RSS is sampled every 200 ms; CPU percentages are recorded in the JSON. '
                'These are closed-loop saturation results without user think time.\n\n'
                'Login burst: '+json.dumps(report['login_burst'])+'\n\nLogin rate limit: '+json.dumps(report['login_rate_limit'])+'\n\n'+report['integrity']+'\n')
            print('\n'+markdown,flush=True)
            print('Login protection: '+json.dumps(report['login_burst'])+' / '+json.dumps(report['login_rate_limit']),flush=True)
            print(report['integrity'],flush=True)
        finally:
            stop()

if __name__=='__main__':main()
