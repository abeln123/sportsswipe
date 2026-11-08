// Isolated local admin presentation test, live Solana DEVNET transactions only.
import assert from'node:assert/strict';
import{existsSync,writeFileSync,readFileSync}from'node:fs';
import{Connection,Keypair,Transaction,SystemProgram,sendAndConfirmTransaction}from'@solana/web3.js';
import nacl from'tweetnacl';
import{DEVNET_GENESIS}from'../src/policy.mjs';
const base=process.env.DEMO_API_URL||'http://localhost:8090';assert.ok(['localhost','127.0.0.1'].includes(new URL(base).hostname));
async function api(path,body,token){const r=await fetch(`${base}/v1${path}`,{method:body?'POST':'GET',headers:{'content-type':'application/json',...(token?{authorization:`Bearer ${token}`}:{})},...(body?{body:JSON.stringify(body)}:{})});const j=await r.json();if(!r.ok)throw new Error(`${r.status} ${j.message}`);return j;}
const user=await api('/auth/login',{email:process.env.PRESENTATION_ADMIN_EMAIL,password:'milestone-pass-123'});assert.ok(user.isAdmin);
const token=user.sessionToken;const owned=await api('/me/collection',null,token);const player=owned.cards.find(c=>c.presentation&&c.mastery.count>=400).card.playerId;
const path='collectibles/.keys/presentation-admin.json';if(!existsSync(path))writeFileSync(path,JSON.stringify([...Keypair.generate().secretKey]),{mode:0o600,flag:'wx'});
const admin=Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(path,'utf8'))));
const issuer=Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(process.env.SOLANA_ISSUER_KEYPAIR,'utf8'))));
const buyer=Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(process.env.PRESENTATION_BUYER_KEYPAIR,'utf8'))));
const chain=new Connection('https://api.devnet.solana.com','confirmed');assert.equal(await chain.getGenesisHash(),DEVNET_GENESIS);
const balance=await chain.getBalance(buyer.publicKey);if(balance<105000000){assert.ok(await chain.getBalance(issuer.publicKey)>125000000-balance);await sendAndConfirmTransaction(chain,new Transaction().add(SystemProgram.transfer({fromPubkey:issuer.publicKey,toPubkey:buyer.publicKey,lamports:105000000-balance})),[issuer]);}
const challenge=await api('/collectibles/wallet/challenge',{address:admin.publicKey.toBase58()},token);
await api('/collectibles/wallet/verify',{signature:Buffer.from(nacl.sign.detached(Buffer.from(challenge.message),admin.secretKey)).toString('base64')},token);
const mint=await api('/collectibles/claim',{playerId:player},token);console.log('Presentation Diamond minted:',mint.asset);
let dashboard=await api('/collectibles/dashboard',null,token);const edition=dashboard.collectibles.find(c=>c.id===mint.id);assert.equal(edition.qualification_source,'admin_presentation');
const sale=await api('/collectibles/presentation/sell',{id:mint.id},token);console.log('Demo buyer signed:',sale.id);
if(sale.status!=='confirmed'){
 const prepared=await api('/collectibles/transaction',{id:sale.id},token);const transaction=Transaction.from(Buffer.from(prepared.transaction,'base64'));transaction.partialSign(admin);
 await api('/collectibles/sign',{id:sale.id,transaction:transaction.serialize({requireAllSignatures:false}).toString('base64')},token);
}
let completed;for(let i=0;i<20;i++){
 dashboard=await api('/collectibles/dashboard',null,token);completed=dashboard.sales.find(s=>s.id===sale.id);if(completed.status==='confirmed')break;await new Promise(r=>setTimeout(r,2500));
}
assert.equal(completed.status,'confirmed');assert.equal(dashboard.collectibles.find(c=>c.id===mint.id).owner,buyer.publicKey.toBase58());
const collection=await api('/me/collection',null,token);const diamond=collection.cards.find(c=>c.card.playerId===player);assert.equal(diamond.mastery.count,400);assert.equal(diamond.finish,'diamond');
const tx=await chain.getTransaction(completed.signature,{commitment:'confirmed',maxSupportedTransactionVersion:0});assert.ok(tx);assert.equal(tx.meta.err,null);
const proof={network:'devnet',presentation:true,asset:mint.asset,mintSignature:mint.signature,saleSignature:completed.signature,saleExplorer:completed.transaction_url,priceDevnetSol:0.1,originalEarner:user.displayName,retainedMastery:400,buyer:buyer.publicKey.toBase58()};
writeFileSync('collectibles/presentation-proof.json',JSON.stringify(proof,null,2));console.log('CONFIRMED',JSON.stringify(proof,null,2));
