import {sha256,hex,randomBytes,timingSafeEqual,hashPassword,verifyPassword} from 'crypto';
function assert(ok,message){if(!ok)throw new Error(message)}
assert(hex(sha256('abc'))==='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad','SHA256 vector');
assert(hex(sha256(new Uint8Array([97,98,99])))===hex(sha256('abc')),'byte input');
assert(hex(new Uint8Array([255,0,1,128]).subarray(1,3))==='0001','hex view offset');
assert(hex(new Uint8Array(0))===''&&hex([0,15,255])==='000fff','hex empty and iterable fallback');
const custom=new Uint8Array([1]);custom[Symbol.iterator]=function*(){yield 255};assert(hex(custom)==='ff','hex custom iterator');
let iteratorReads=0;Object.defineProperty(custom,Symbol.iterator,{get(){iteratorReads++;return function*(){yield 1}}});
assert(hex(custom)==='01'&&iteratorReads===1,'hex iterator getter runs once');
const backing=new ArrayBuffer(4), detached=new Uint8Array(backing);backing.transfer();
let detachedError=false;try{hex(detached)}catch(e){detachedError=e instanceof TypeError}assert(detachedError,'hex detached view');
const resizable=new ArrayBuffer(4,{maxByteLength:8}), fixed=new Uint8Array(resizable,2,2);resizable.resize(1);
let boundsError=false;try{hex(fixed)}catch(e){boundsError=e instanceof TypeError}assert(boundsError,'hex out-of-bounds view');
assert(randomBytes(0).length===0&&randomBytes(65536).length===65536,'random byte sizes');
assert(!timingSafeEqual(randomBytes(32),randomBytes(32)),'independent randomness');
assert(timingSafeEqual(new Uint8Array([1,2]),new Uint8Array([1,2])),'equal bytes');
assert(!timingSafeEqual(new Uint8Array([1]),new Uint8Array([1,2])),'different lengths');
for(const size of [-1,0.5,65537,NaN,Infinity,'2']){let threw=false;try{randomBytes(size)}catch{threw=true}assert(threw,'invalid random size '+size)}
const pass='correct horse battery staple\0é😀';
const encoded=await hashPassword(pass);
assert(encoded.startsWith('$argon2id$v=19$m=19456,t=2,p=1$'),'Argon2id profile');
assert(encoded.split('$')[4].length===43,'32-byte salt default');
assert(await verifyPassword('legacy interoperability password','$argon2id$v=19$m=19456,t=2,p=1$hM9yHCmigUB10aHhBQUEoA$7XPUfhUnsZwki7aCYB5K39AOaKVAe3FeQYjOJqlBjms'),'legacy 16-byte salt');
assert(await verifyPassword(pass,encoded),'round trip');
assert(!await verifyPassword(pass+'x',encoded),'wrong password');
for(const bad of ['',encoded.replace('19456','99999999'),encoded.slice(0,-1),encoded+'x','$argon2id$v=19$m=19456,t=2,p=1$'+'!'.repeat(66)])assert(!await verifyPassword(pass,bad),'invalid hash rejected');
const other=await hashPassword(pass);assert(other!==encoded,'unique salts');
const a=hashPassword('a'),b=hashPassword('b');let busy=false;
try{await hashPassword('c')}catch(e){busy=e.code==='BUSY'}assert(busy,'bounded native work');await Promise.all([a,b]);
let long=false;try{await hashPassword('a'.repeat(4097))}catch(e){long=e.code==='RANGE_ERROR'}assert(long,'password length bound');
// Print a standard PHC hash for the independent OpenSSL comparison.
console.log(await hashPassword('interoperability password'));
console.log('Native crypto: passed');
