#!/usr/bin/env python3
"""Compare native TS/TSX execution with emitted JS executed by Node."""
import os, subprocess, tempfile
from json import dumps as json_quote
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('BKR_BIN', ROOT / 'out/bkr'))
CASES = {
 'types': '''interface User {name:string}; type ID = number|string;
 const identity = <T,>(x:T):T => x;
 const u:User={name:'héllo 😀'}; const x=(identity<number>(42) as number)!;
 console.log(JSON.stringify([u.name,x, typeof x, (u satisfies User).name]));''',
 'advanced_types': '''type M<T> = {[K in keyof T]?: T[K]}; interface A<T> {value:T};
 declare const unused:number; declare function unusedFn():void;
 function overloaded(x:string):string; function overloaded(x:number):number;
 function overloaded(x:any):any{return x}; class Box<T> implements A<T>{value!:T; constructor(x:T){this.value=x}}
 const b=new Box<number>(3); const o:M<{x:number}> = {x:4};
 console.log(JSON.stringify([b.value,o.x,overloaded(5),(o.x as number)+1]));''',
 'operators': '''let a:number=2; a+=3; const b = -a ** 2;
 console.log(JSON.stringify([a, ++a, a--, a?1:2, typeof missing, void a, ~(a|1), 12345678901234567890n.toString(), 1.2345678901234567]));'''.replace('-a ** 2','-(a ** 2)'),
 'chains': '''let calls=0; function arg(){calls++;return 1}; const no:any=null;
 const obj={x:4,f(v:number){return this.x+v}};
 let thrown=false;try{(no?.x).y}catch(e){thrown=true}
 console.log(JSON.stringify([no?.f(arg()), no?.x.y, obj?.f(2), obj.f?.(3), obj?.['x'], calls, thrown, delete no?.x]));''',
 'functions': '''function* g(x:number=1,...rest:number[]){yield x;yield* rest;return 9}
 async function f(x:number):Promise<number>{return await Promise.resolve(x+1)}
 const arrow=async (x:number)=>({value:x});
 console.log(JSON.stringify([[...g(2,3,4)],await f(5),await arrow(6)]));''',
 'classes': '''class Base {f(){return 2}} class C extends Base {
 private x:number=3; readonly y:number; static n:number=4; #secret:number=5;
 static {this.n++} constructor(){super();this.y=6}
 get value():number{return this.x+this.#secret+super.f()}
 set value(v:number){this.x=v} async m(){return this.value}
 has(o:any){return #secret in o} }
 const c=new C();c.value=7;console.log(JSON.stringify([await c.m(),c.y,C.n,c.has(c)]));''',
 'objects': '''const key='a'; const o={a:2,['b']:3,get value(){return this.a},set value(x:number){this.a=x},*g(){yield this.a},async m(){return this.b},...{c:4}};
 o.value=5; const {a:first,b=9,...rest}=o;const [x,,z,...tail]=[1,2,3,4];
 const arr=[,,];console.log(JSON.stringify([first,b,o.value,[...o.g()],await o.m(),x,z,tail,arr.length,0 in arr]));''',
 'numeric_keys': '''const o={1:2,0x10:3,1.2345678901234567:4,2n:5}; class C {1(){return 6} static 2(){return 7}}; const c=new C(); console.log(JSON.stringify([o[1],o[16],o[1.2345678901234567],o[2],c[1](),C[2]()]));''',
 'control': '''let a=0; outer:for(let i:number=0;i<5;i++){if(i===1)continue;if(i===4)break outer;a+=i}
 for(const n of [1,2])a+=n;for(const k in {x:1})a+=k.length;
 let i=0;while(i<2)i++;do{i--}while(i>0);
 switch(a){case 9:a=11;break;default:a=12}
 try{throw 1}catch{a++}finally{a++}
 console.log(JSON.stringify([a,i]));''',
 'templates': '''const x:number=3;function tag(s:TemplateStringsArray,...v:number[]){return [s[0],s.raw[0],v]};
 console.log(JSON.stringify([`a${x+1}b${x}c`,tag`a\\n${x}b`,/a+/gi.test('Aa')]));''',
 'jsx': '''/** @jsx h */\n/** @jsxFrag Fragment */
 function h(type:any,props:any,...children:any[]){return {type,props,children}}; const Fragment='fragment';
 const props={title:'value'};const name:string='Ada';
 const view=<><p {...props} data-id={2} title="a &amp; b">Hello {name}<br/></p><span>héllo 😀</span></>;
 console.log(JSON.stringify(view));''',
 'imports': '''import {type Foo, value as n} from './dep.js';import type {Bar} from './missing.js';
 export type {Foo} from './missing.js';export {n as named};export const x:number=n+1;
 export default function f(x:number){return x+1};console.log(n,x,f(2));''',
 'directives': '''"use\\x20strict";console.log((function(){return this===undefined})());''',
}

def run(cmd):
 r=subprocess.run(cmd,capture_output=True,text=True,timeout=30)
 assert r.returncode==0, ' '.join(map(str,cmd))+'\n'+r.stdout+r.stderr
 return r.stdout
run([str(BIN),'--no-sandbox','--no-prompt',str(ROOT/'tests/transpile.js')])
with tempfile.TemporaryDirectory(prefix='bkr-transpile-') as tmp:
 p=Path(tmp)
 (p/'dep.js').write_text('export const value=10;')
 for name,source in CASES.items():
  original=p/(name+('.tsx' if name=='jsx' else '.ts'));original.write_text(source)
  expected=run([str(BIN),'--no-sandbox','--no-prompt',str(original)])
  emitted=run([str(BIN),'--no-sandbox','--no-prompt',f'--allow-read={p}',str(ROOT/'tests/transpile/emit.js'),str(original)])
  js=p/(name+'.mjs');js.write_text(emitted)
  actual=run(['node',str(js)])
  assert actual==expected, name+'\nExpected: '+expected+'\nActual: '+actual+'\nJS:\n'+emitted
  print(name+': passed')
 # Script goal: preserve escaped directives, Annex B bindings and with.
 scripts=[
  '"use\\x20strict";console.log((function(){return this===undefined})());',
  '"use strict";console.log((function(){return this===undefined})());',
  'if(false) function f(){}; console.log(typeof f);',
  'with({x:3}) console.log(x);',
  'let x=0; label:while(true){x++;break label};console.log(x);',
 ]
 for i,source in enumerate(scripts):
  original=p/f'script{i}.cjs';original.write_text(source)
  expected=run(['node',str(original)])
  emitted=run([str(BIN),'--no-sandbox','--no-prompt',f'--allow-read={p}',str(ROOT/'tests/transpile/emit.js'),str(original),'script'])
  js=p/f'emitted{i}.cjs';js.write_text(emitted)
  assert run(['node',str(js)])==expected,source+'\n'+emitted
 print('Script goal and directive semantics: passed')
 # The automatic JSX runtime is the actual vendored Preact package.
 tsx=p/'automatic.tsx'
 tsx.write_text("const element=<section title=\"a &amp; b\"><span>hello</span></section>;console.log(JSON.stringify([element.type,element.props.title,element.props.children.type]));")
 emitted=run([str(BIN),'--no-sandbox','--no-prompt',f'--allow-read={p}',str(ROOT/'tests/transpile/emit.js'),str(tsx),'automatic'])
 preact=(ROOT/'examples/taskboard/vendor/preact/dist/preact.mjs').as_uri()
 (p/'jsx-runtime.mjs').write_text(Path(ROOT/'examples/taskboard/vendor/preact/jsx-runtime/dist/jsxRuntime.mjs').read_text().replace('"preact"',json_quote(preact)).replace("'preact'",json_quote(preact)))
 js=p/'automatic.mjs';js.write_text(emitted.replace('preact/jsx-runtime','./jsx-runtime.mjs'))
 assert run(['node',str(js)])=='["section","a & b","span"]\n'
 print('Automatic Preact JSX runtime: passed')
print('Native TS/TSX -> browser JS semantic comparisons: passed')
