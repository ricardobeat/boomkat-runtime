import {transpile} from "typescript";
function assert(ok, message) { if (!ok) throw new Error(message); }
const out = transpile('interface U {name:string}; const u:U={name:"abc"}; export {u};');
assert(!out.includes('interface'), 'interface erased');
assert(out.includes('export'), 'value export retained');
for (const source of ['enum X {A}', 'const x: number = ;', 'namespace X {export const n=1}', 'const x =']) {
    let threw = false;
    try { transpile(source); } catch(e) { threw = e instanceof SyntaxError; }
    assert(threw, 'reject: '+source);
}
const jsx = transpile('export const element = <p title="a &amp; b">Hi</p>', {filename:'view.tsx'});
assert(jsx.includes('preact/jsx-runtime'), 'automatic JSX imports');
assert(!jsx.includes('<p'), 'JSX lowered');
let invalid = false;
try { transpile(3); } catch(e) { invalid = e instanceof TypeError; }
assert(invalid,'source type validation');
assert(transpile('const a: number=1').includes('const'), 'parser restored after failures');
for (const options of [
    {filename:'view.tsx',module:false},
    {filename:'view.tsx',jsx:'classic',jsxFactory:'invalid-name'},
]) {
    let threw=false;
    try { transpile('<p/>',options); } catch(e) { threw=e instanceof SyntaxError; }
    assert(threw,'reject invalid emitted syntax');
}
console.log('TypeScript/JSX emission API: passed');
