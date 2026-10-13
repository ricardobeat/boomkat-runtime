#!/usr/bin/env python3
"""Exercise the real TS server, membership checks, sessions and SQLite BLOBs."""
import base64,hashlib,json,os,socket,sqlite3,subprocess,tempfile,time,urllib.request,urllib.error
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BIN=Path(os.environ.get('BKR_BIN',ROOT/'out/bkr'))
APP=ROOT/'examples/taskboard'
RUNTIME=os.environ.get('TASKBOARD_RUNTIME','bkr')
BUN=os.environ.get('BUN_BIN','bun')
PNG=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jFMsAAAAASUVORK5CYII=')
class Client:
 def __init__(self,base):self.base=base;self.cookie='';self.csrf=''
 def call(self,path,method='GET',data=None,expected=200,headers=None,raw=False):
  h={'Origin':self.base,'Cookie':self.cookie,'X-CSRF-Token':self.csrf}
  if data is not None and not isinstance(data,bytes):data=json.dumps(data).encode();h['Content-Type']='application/json'
  if headers:h.update(headers)
  req=urllib.request.Request(self.base+path,data=data,headers=h,method=method)
  try:r=urllib.request.urlopen(req,timeout=10)
  except urllib.error.HTTPError as e:r=e
  b=r.read();assert r.status==expected,(method,path,r.status,b)
  if r.headers.get('Set-Cookie'):self.cookie=r.headers['Set-Cookie'].split(';',1)[0]
  if raw:return b,r.headers
  v=json.loads(b)
  if isinstance(v,dict) and 'csrf' in v:self.csrf=v['csrf']
  return v

def main():
 with tempfile.TemporaryDirectory(prefix='bkr-taskboard-') as directory:
  with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
  base=f'http://127.0.0.1:{port}'
  def start():
   log=open(Path(directory)/'server.log','w+')
   command=([BUN,str(APP/'server.bun.ts'),str(port),directory] if RUNTIME=='bun' else [str(BIN),'--no-prompt',f'--allow-net=127.0.0.1:{port}',f'--allow-read={APP},{directory}',f'--allow-write={directory}',str(APP/'server.ts'),str(port),directory])
   p=subprocess.Popen(command,stdout=log,stderr=log)
   for _ in range(100):
    if p.poll() is not None:log.seek(0);raise AssertionError(log.read())
    try:urllib.request.urlopen(base,timeout=.2);return p,log
    except (OSError,urllib.error.URLError):time.sleep(.05)
   p.terminate();p.wait();log.seek(0);raise AssertionError('Server startup timeout: '+log.read())
  p,log=start()
  try:
   a,b,outsider=[Client(base) for _ in range(3)]
   html,headers=a.call('/',raw=True)
   assert headers['Content-Type'].startswith('text/html')
   assert 'frame-ancestors' in headers['Content-Security-Policy']
   importmap=html.decode().split('<script type="importmap">')[1].split('</script>')[0]
   assert 'sha256-'+base64.b64encode(hashlib.sha256(importmap.encode()).digest()).decode() in headers['Content-Security-Policy']
   js,headers=a.call('/app.js',raw=True)
   assert headers['Content-Type'].startswith('text/javascript') and b'preact/jsx-runtime' in js
   head,head_headers=a.call('/app.js','HEAD',raw=True)
   assert head==b'' and head_headers['Content-Type']==headers['Content-Type']
   a.call('/app.js','POST',expected=404)
   assert b'interface User' not in js and b'<App/>' not in js and b'import type' not in js
   emitted=Path(directory)/'app.mjs';emitted.write_bytes(js);subprocess.run(['node','--check',str(emitted)],check=True,capture_output=True)
   for route in ['/style.css','/vendor/preact.mjs','/vendor/hooks.mjs','/vendor/jsx-runtime.mjs']:a.call(route,raw=True)
   a.call('/api/me',expected=401)
   a.call('/api/register','POST',{'name':'Alice','email':'alice@example.com','password':'short'},expected=400)
   alice=a.call('/api/register','POST',{'name':'Alice','email':'ALICE@example.com','password':'my first secure password'},201)['user']
   bob=b.call('/api/register','POST',{'name':'Bob','email':'bob@example.com','password':'my second secure password'},201)['user']
   outsider.call('/api/register','POST',{'name':'Other','email':'other@example.com','password':'my third secure password'},201)
   a.call('/api/register','POST',{'name':'Alice','email':'alice@example.com','password':'my first secure password'},409)
   assert a.call('/api/me')['user']==alice
   w=a.call('/api/workspace');team=w['teams'][0];board=w['boards'][0]
   data=a.call(f'/api/boards/{board["id"]}');assert len(data['lists'])==3 and len(data['cards'])==1
   card=data['cards'][0];list0,list1=data['lists'][:2]
   b.call(f'/api/boards/{board["id"]}',expected=404)
   a.call('/api/cards','POST',{'list_id':list0['id'],'title':'CSRF'},403,headers={'X-CSRF-Token':''})
   a.call('/api/cards','POST',{'list_id':list0['id'],'title':'Cross origin'},403,headers={'Origin':'https://evil.example'})
   a.call(f'/api/teams/{team["id"]}/members','POST',{'email':'bob@example.com'})
   assert len(b.call(f'/api/teams/{team["id"]}/members'))==2
   b.call(f'/api/teams/{team["id"]}/members','POST',{'email':'other@example.com'},403)
   b.call(f'/api/teams/{team["id"]}/members/{alice["id"]}','DELETE',expected=403)
   a.call(f'/api/teams/{team["id"]}/members/{alice["id"]}','DELETE',expected=400)
   created=b.call('/api/cards','POST',{'list_id':list0['id'],'title':'Shared card'},201)['id']
   b.call(f'/api/cards/{created}','PATCH',{'title':'Edited by Bob','description':'Hello <script>no</script>','color':'peach','list_id':list1['id']})
   a.call(f'/api/cards/{created}','PATCH',{'color':'invalid'},400)
   foreign=outsider.call('/api/workspace')['boards'][0]
   foreignlist=outsider.call(f'/api/boards/{foreign["id"]}')['lists'][0]
   a.call(f'/api/cards/{created}','PATCH',{'list_id':foreignlist['id']},404)
   board2=a.call('/api/boards','POST',{'team_id':team['id'],'name':'Second board'},201)['id']
   otherlist=a.call(f'/api/boards/{board2}')['lists'][0]
   a.call(f'/api/cards/{created}','PATCH',{'list_id':otherlist['id']},400)
   image=b.call(f'/api/cards/{created}/images','POST',PNG,201,headers={'Content-Type':'image/png','X-File-Name':'pixel.png'})['id']
   out,h=a.call(f'/api/images/{image}',raw=True);assert out==PNG and h['Content-Type']=='image/png'
   out,h=a.call(f'/api/images/{image}','HEAD',raw=True);assert out==b'' and h['Content-Type']=='image/png'
   outsider.call(f'/api/images/{image}',expected=404)
   b.call(f'/api/cards/{created}/images','POST',b'<svg/>',415,headers={'Content-Type':'image/svg+xml'})
   b.call(f'/api/cards/{created}/images','POST',PNG,415,headers={'Content-Type':'image/jpeg'})
   b.call(f'/api/cards/{created}/images','POST',PNG,400,headers={'Content-Type':'image/png','X-File-Name':'%ZZ'})
   outsider.call(f'/api/cards/{created}','DELETE',expected=404)
   db=sqlite3.connect(Path(directory)/'taskboard.sqlite')
   assert db.execute('SELECT typeof(data),data FROM images WHERE id=?',(image,)).fetchone()==('blob',PNG)
   hashes=[r[0] for r in db.execute('SELECT password_hash FROM users')];assert all(h.startswith('$argon2id$') for h in hashes)
   assert db.execute('SELECT token_hash FROM sessions WHERE user_id=?',(alice['id'],)).fetchone()[0]!=a.cookie.split('=',1)[1]
   db.close()
   p.terminate();p.wait(timeout=5);log.close();p,log=start()
   assert a.call('/api/me')['user']['id']==alice['id']
   assert a.call(f'/api/images/{image}',raw=True)[0]==PNG
   a.call(f'/api/teams/{team["id"]}/members/{bob["id"]}','DELETE')
   b.call(f'/api/boards/{board["id"]}',expected=404);b.call(f'/api/images/{image}',expected=404)
   a.call(f'/api/images/{image}','DELETE');a.call(f'/api/images/{image}',expected=404)
   a.call(f'/api/cards/{created}','DELETE');a.call(f'/api/cards/{created}','DELETE',expected=404)
   a.call(f'/api/boards/{board2}','DELETE')
   a.call('/api/logout','POST');a.call('/api/me',expected=401)
   a.call('/api/login','POST',{'email':'alice@example.com','password':'wrong'},401)
   a.call('/api/login','POST',{'email':'nobody@example.com','password':'wrong'},401)
   a.call('/api/login','POST',{'email':'alice@example.com','password':'my first secure password'})
   assert a.call('/api/me')['user']['name']=='Alice'
   print('Taskboard: native TSX assets, accounts, sessions, CSRF, teams, cards, BLOBs, isolation and restart persistence: passed')
  finally:
   p.terminate();p.wait(timeout=5);log.seek(0);output=log.read();log.close()
   assert 'ERROR: AddressSanitizer' not in output,output
if __name__=='__main__':main()
