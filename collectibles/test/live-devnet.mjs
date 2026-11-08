// Explicit live-devnet integration. Creates test wallets only in ignored .keys/.
import {readFileSync,writeFileSync,existsSync,mkdirSync}from'node:fs';
import{Connection,Keypair,SystemProgram,Transaction,sendAndConfirmTransaction,PublicKey}from'@solana/web3.js';
import nacl from'tweetnacl';
import assert from'node:assert/strict';
import {DEVNET_GENESIS}from'../src/policy.mjs';
const chain=new Connection(process.env.SOLANA_DEVNET_RPC||'https://api.devnet.solana.com','confirmed');
assert.equal(await chain.getGenesisHash(),DEVNET_GENESIS);
const base=process.env.DEMO_API_URL||'http://localhost:8090';assert.ok(['localhost','127.0.0.1'].includes(new URL(base).hostname));
const fixture=JSON.parse(readFileSync(process.env.DIAMOND_FIXTURE_FILE,'utf8').split('\nSeeded')[0]);
const issuer=Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(process.env.SOLANA_ISSUER_KEYPAIR,'utf8'))));
mkdirSync('collectibles/.keys',{recursive:true});
function key(name){const path=`collectibles/.keys/${name}.json`;if(!existsSync(path))writeFileSync(path,JSON.stringify([...Keypair.generate().secretKey]),{mode:0o600,flag:'wx'});return Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(path,'utf8'))));}
const maya=key('maya-demo'),jordan=key('jordan-demo');
async function call(path,body,token){const r=await fetch(`${base}/v1${path}`,{method:body?'POST':'GET',headers:{'content-type':'application/json',authorization:`Bearer ${token}`},...(body?{body:JSON.stringify(body)}:{})});const j=await r.json();if(!r.ok)throw new Error(`${r.status}: ${j.message}`);return j;}
const a=(await call('/auth/login',{email:fixture.earnerEmail,password:fixture.password})).sessionToken;
const b=(await call('/auth/login',{email:fixture.buyerEmail,password:fixture.password})).sessionToken;
async function link(pair,token){const c=await call('/collectibles/wallet/challenge',{address:pair.publicKey.toBase58()},token);await call('/collectibles/wallet/verify',{signature:Buffer.from(nacl.sign.detached(Buffer.from(c.message),pair.secretKey)).toString('base64')},token);}
await link(maya,a);await link(jordan,b);
const balance=await chain.getBalance(jordan.publicKey);
if(balance<105000000){
 const deficit=105000000-balance;
 assert.ok(await chain.getBalance(issuer.publicKey)>deficit+15000000,'Fund issuer with at least 0.12 devnet SOL for the mint and 0.1 sale test.');
 const fund=new Transaction().add(SystemProgram.transfer({fromPubkey:issuer.publicKey,toPubkey:jordan.publicKey,lamports:deficit}));
 console.log('Funding buyer with test SOL:',await sendAndConfirmTransaction(chain,fund,[issuer]));
}
const mint=await call('/collectibles/claim',{playerId:fixture.playerId},a);console.log('MINT',JSON.stringify(mint));
const retry=await call('/collectibles/claim',{playerId:fixture.playerId},a);assert.equal(retry.id,mint.id);assert.equal(retry.asset,mint.asset);
let dashboard=await call('/collectibles/dashboard',null,a);
let listing=dashboard.sales.find(s=>s.collectible_id===mint.id&&s.status==='confirmed');
if(!listing){
 listing=dashboard.sales.find(s=>s.collectible_id===mint.id&&['listed','signing','submitted'].includes(s.status));
 if(!listing)listing=await call('/collectibles/list',{id:mint.id,price:'0.1'},a);
 dashboard=await call('/collectibles/dashboard',null,a);
 let sale=dashboard.sales.find(s=>s.id===listing.id);
 if(sale.status==='listed')await call('/collectibles/offer',{id:listing.id},b);
 if(sale.status!=='submitted'){
  for(const[pair,token]of[[jordan,b],[maya,a]]){
   const prepared=await call('/collectibles/transaction',{id:listing.id},token);
   const t=Transaction.from(Buffer.from(prepared.transaction,'base64'));t.partialSign(pair);
   console.log('SIGN',await call('/collectibles/sign',{id:listing.id,transaction:t.serialize({requireAllSignatures:false}).toString('base64')},token));
  }
 }
 for(let i=0;i<30;i++){
  dashboard=await call('/collectibles/dashboard',null,a);sale=dashboard.sales.find(s=>s.id===listing.id);
  if(sale.status==='confirmed'){listing=sale;break;}
  if(sale.status==='expired')throw new Error('Sale expired; restart the test to relist.');
  await new Promise(resolve=>setTimeout(resolve,1500));
 }
}
assert.equal(listing.status,'confirmed');
const tx=await chain.getTransaction(listing.signature,{commitment:'confirmed',maxSupportedTransactionVersion:0});assert.ok(tx);assert.equal(tx.meta.err,null);
const {fetchAsset,mplCore}=await import('@metaplex-foundation/mpl-core');const{createUmi}=await import('@metaplex-foundation/umi-bundle-defaults');const{publicKey}=await import('@metaplex-foundation/umi');
const asset=await fetchAsset(createUmi(chain.rpcEndpoint).use(mplCore()),publicKey(mint.asset));assert.equal(asset.owner,jordan.publicKey.toBase58());
const ownerDashboard=await call('/collectibles/dashboard',null,b);assert.ok(ownerDashboard.collectibles.find(c=>c.id===mint.id).is_owner);
const earnerDashboard=await call('/collectibles/dashboard',null,a);assert.equal(earnerDashboard.cards[0].qualifying_calls,400);
assert.equal(earnerDashboard.collectibles.find(c=>c.id===mint.id).earner_name,'Maya · DEMO');
const proof={network:'devnet',asset:mint.asset,mintSignature:mint.signature,saleSignature:listing.signature,lamports:listing.lamports,originalEarner:fixture.earnerEmail,originalEarnerQualifyingCalls:400,currentOwner:jordan.publicKey.toBase58(),seller:maya.publicKey.toBase58(),saleExplorer:listing.transaction_url};
writeFileSync('/tmp/sportsswipe-diamond-proof.json',JSON.stringify(proof,null,2));console.log('VERIFIED',JSON.stringify(proof,null,2));
