// Isolated local database; genuine Solana DEVNET reset -> resale -> reset.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {Connection,Keypair,Transaction} from '@solana/web3.js';
import {DEVNET_GENESIS} from '../src/policy.mjs';
const base=process.env.DEMO_API_URL||'http://localhost:8095';
assert.ok(['localhost','127.0.0.1'].includes(new URL(base).hostname));
async function api(path,body,token){
 const r=await fetch(`${base}/v1${path}`,{method:body?'POST':'GET',headers:{'content-type':'application/json',...(token?{authorization:`Bearer ${token}`}:{})},...(body?{body:JSON.stringify(body)}:{})});
 const j=await r.json();if(!r.ok)throw Object.assign(new Error(j.message),{status:r.status});return j;
}
const chain=new Connection('https://api.devnet.solana.com','confirmed');assert.equal(await chain.getGenesisHash(),DEVNET_GENESIS);
const admin=Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(new URL('../.keys/presentation-admin.json',import.meta.url),'utf8'))));
const user=await api('/auth/login',{email:process.env.PRESENTATION_ADMIN_EMAIL,password:'milestone-pass-123'});
assert.ok(user.isAdmin);const token=user.sessionToken;
const before=await api('/collectibles/dashboard',null,token);
assert.equal(before.wallet,admin.publicKey.toBase58());
const edition=before.collectibles.find(c=>c.is_earner&&c.qualification_source==='admin_presentation');assert.ok(edition);
const original=before.sales.find(s=>s.collectible_id===edition.id&&s.status==='confirmed');assert.ok(original);
const initialBalance=await chain.getBalance(admin.publicKey);
const signed=transaction=>{const tx=Transaction.from(Buffer.from(transaction,'base64'));tx.partialSign(admin);return tx.serialize({requireAllSignatures:false}).toString('base64');};
async function reset(){
 const prepared=await api('/collectibles/presentation/reset',{id:edition.id},token);
 assert.equal(prepared.status,'signing');
 const alias=await api('/admin/reset-presentation',{id:edition.id},token);assert.equal(alias.id,prepared.id);
 let result=await api('/collectibles/presentation/reset/sign',{id:prepared.id,transaction:signed(prepared.transaction)},token);
 for(let i=0;i<30&&result.status!=='confirmed';i++){await new Promise(r=>setTimeout(r,750));result=await api('/collectibles/presentation/reset',{id:edition.id},token);}
 assert.equal(result.status,'confirmed');assert.equal(result.reset,true);
 const again=await api('/collectibles/presentation/reset',{id:edition.id},token);assert.equal(again.id,result.id);assert.equal(again.status,'confirmed');
 const dashboard=await api('/collectibles/dashboard',null,token);
 const card=dashboard.collectibles.find(c=>c.id===edition.id);
 assert.equal(card.owner,admin.publicKey.toBase58());assert.equal(card.asset_address,edition.asset_address);assert.equal(card.edition,edition.edition);
 assert.equal(dashboard.sales.some(s=>s.collectible_id===edition.id&&s.status==='confirmed'),false);
 const metadata=await api(`/collectibles/public/${edition.id}`,null,null);assert.ok(metadata.name);
 const receipt=await chain.getTransaction(new URL(result.transaction_url).pathname.split('/').pop(),{commitment:'confirmed',maxSupportedTransactionVersion:0});
 assert.ok(receipt);assert.equal(receipt.meta.err,null);
 return result.transaction_url;
}
const firstReset=await reset();console.log('Confirmed first reset:',firstReset);
assert.equal(await chain.getBalance(admin.publicKey),initialBalance-Number(original.lamports));
const resale=await api('/collectibles/presentation/sell',{id:edition.id},token);assert.notEqual(resale.id,original.id);
const tx=await api('/collectibles/transaction',{id:resale.id},token);
await api('/collectibles/sign',{id:resale.id,transaction:signed(tx.transaction)},token);
let completed;
for(let i=0;i<30;i++){
 const d=await api('/collectibles/dashboard',null,token);completed=d.sales.find(s=>s.id===resale.id);
 if(completed?.status==='confirmed')break;await new Promise(r=>setTimeout(r,750));
}
assert.equal(completed.status,'confirmed');console.log('Confirmed repeat sale:',completed.transaction_url);
const secondReset=await reset();
const collection=await api('/me/collection',null,token);const card=collection.cards.find(c=>c.card.playerId==edition.player_id);assert.equal(card.mastery.count,400);
const proof={network:'devnet',asset:edition.asset_address,edition:edition.edition,originalSale:original.transaction_url,firstReset,repeatSale:completed.transaction_url,secondReset,retainedMastery:400,sameAssetReused:true};
writeFileSync('collectibles/reset-proof.json',JSON.stringify(proof,null,2));console.log('RESET / RESELL / RESET VERIFIED',JSON.stringify(proof,null,2));
