import { args } from "process";
const count = Number(args[0] || 20000);
let checksum = 0;
const resource = {[Symbol.dispose]() { checksum++; }};
const asyncResource = {[Symbol.asyncDispose]() { checksum++; return Promise.resolve(); }};
function manual() { const r=resource; try { return 1; } finally { r[Symbol.dispose](); } }
function scoped() { using r=resource; return 1; }
function multiple() { using a=resource; using b=resource; return 1; }
async function fallback() { await using r=resource; return 1; }
async function nativeAsync() { await using r=asyncResource; return 1; }
async function manualAsync() { const r=resource; try { return 1; } finally { await r[Symbol.dispose](); } }
const results = {};
for (const [name, fn, isAsync] of [["manual",manual,false],["using",scoped,false],["multiple",multiple,false],["finallyasync",manualAsync,true],["awaitusing",fallback,true],["asyncdispose",nativeAsync,true]]) {
  for (let i=0; i<1000; i++) { if (isAsync) await fn(); else fn(); }
  const start=Date.now();
  for (let i=0; i<count; i++) { if (isAsync) await fn(); else fn(); }
  results[name]=Date.now()-start;
}
console.log(JSON.stringify({count,checksum,ms:results}));
