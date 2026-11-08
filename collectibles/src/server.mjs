import http from 'node:http';
import { readFileSync } from 'node:fs';
import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import pg from 'pg';
import nacl from 'tweetnacl';
import bs58 from 'bs58';
import { Connection, Keypair, PublicKey, Transaction, SystemProgram } from '@solana/web3.js';
import { createUmi } from '@metaplex-foundation/umi-bundle-defaults';
import { createSignerFromKeypair, signerIdentity, publicKey, createNoopSigner } from '@metaplex-foundation/umi';
import { create, transfer, fetchAsset, mplCore } from '@metaplex-foundation/mpl-core';
import { toWeb3JsInstruction } from '@metaplex-foundation/umi-web3js-adapters';
import { address, price, mergeTransaction, DEVNET_GENESIS, eligibleSql } from './policy.mjs';

const secret=process.env.COLLECTIBLES_SERVICE_KEY;
if(!secret || secret.length<32)throw new Error('Set COLLECTIBLES_SERVICE_KEY to a random secret of at least 32 characters.');
const base=new URL(process.env.PUBLIC_BASE_URL||'http://localhost:8080');
const rpc=process.env.SOLANA_DEVNET_RPC||'https://api.devnet.solana.com';
const chain=new Connection(rpc,'confirmed');
if(await chain.getGenesisHash()!==DEVNET_GENESIS)throw new Error('Only Solana devnet is allowed.');
const issuer=Keypair.fromSecretKey(Uint8Array.from(JSON.parse(process.env.SOLANA_ISSUER_KEYPAIR_JSON || readFileSync(process.env.SOLANA_ISSUER_KEYPAIR,'utf8'))));
const umi=createUmi(rpc).use(mplCore());
umi.use(signerIdentity(createSignerFromKeypair(umi,umi.eddsa.createKeypairFromSecretKey(issuer.secretKey))));
const pool=new pg.Pool({connectionString:process.env.DATABASE_URL});
const hash=x=>createHash('sha256').update(x).digest('hex');
const explorer=(kind,id)=>`https://explorer.solana.com/${kind}/${id}?cluster=devnet`;
const metadata=id=>`${base.origin}/v1/collectibles/public/${id}`;
function fail(message,status=400){throw Object.assign(new Error(message),{status});}
async function tx(fn){const db=await pool.connect();try{await db.query('BEGIN');const out=await fn(db);await db.query('COMMIT');return out;}catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();}}
async function wallet(user){const r=await pool.query('SELECT address FROM collectible_wallets WHERE user_id=$1 AND verified',[user]);if(!r.rowCount)fail('Connect and verify your wallet first.');return r.rows[0].address;}
async function assetAt(c){try{return await fetchAsset(umi,publicKey(c.asset_address));}catch(e){if(await chain.getAccountInfo(new PublicKey(c.asset_address))===null)return null;throw e;}}
async function reconcileSale(s){
 if(!s.signature)return;
 const info=(await chain.getSignatureStatuses([s.signature],{searchTransactionHistory:true})).value[0];
 if(info && !info.err && ['confirmed','finalized'].includes(info.confirmationStatus)){
  const c=(await pool.query('SELECT * FROM diamond_collectibles WHERE id=$1',[s.collectible_id])).rows[0];
  const asset=await assetAt(c);
  if(asset?.owner!==s.buyer_wallet)fail('Sale confirmed, but ownership could not be verified. Try refreshing.',503);
  await pool.query("UPDATE collectible_sales SET status='confirmed',confirmed_at=COALESCE(confirmed_at,now()) WHERE id=$1",[s.id]);
 }else if(info?.err || await chain.getBlockHeight('finalized')>Number(s.block_height)){
  await pool.query("UPDATE collectible_sales SET status='expired' WHERE id=$1 AND status IN ('signing','submitted')",[s.id]);
 }
}
async function dispatch(path,method,b,user){
 if(path==='demo/settle' && method==='POST') {
  const local = ['localhost','127.0.0.1'].includes(new URL(process.env.DATABASE_URL).hostname);
  if(process.env.ENABLE_DIAMOND_DEMO!=='true' || !local)fail('The fictional demo controls are disabled.',403);
  return tx(async db=>{
   const r=await db.query(`SELECT m.id FROM entries e JOIN markets m ON m.id=e.single_market_id JOIN players p ON p.id=m.player_id JOIN users u ON u.id=e.user_id
    WHERE e.user_id=$1 AND e.status='pending' AND e.stake=0 AND p.collectible_demo AND u.email LIKE '%-demo-%@example.invalid' ORDER BY e.accepted_at DESC LIMIT 1 FOR UPDATE OF m`,[user]);
   if(!r.rowCount)fail('No final fictional demo pick is pending.');const id=r.rows[0].id;
   await db.query("UPDATE markets SET status='locked' WHERE id=$1",[id]);
   await db.query("INSERT INTO market_results(market_id,revision,value_x10,source) VALUES ($1,1,600,'admin_demo') ON CONFLICT DO NOTHING",[id]);
   await db.query("INSERT INTO jobs(kind,dedupe_key,payload) VALUES ('grade_market',$1,jsonb_build_object('marketId',$2::bigint)) ON CONFLICT DO NOTHING",[`diamond-demo:${id}`,id]);
   return {message:'Final fictional result recorded. The normal worker will settle it and unlock Diamond.'};
  });
 }

 if(path==='presentation/sell' && method==='POST'){
  const admin=(await pool.query('SELECT is_admin FROM users WHERE id=$1',[user])).rows[0]?.is_admin;
  if(!admin)fail('Presentation sales are admin-only.',403);
  const c=(await pool.query("SELECT c.* FROM diamond_collectibles c JOIN presentation_entitlements p ON p.user_id=c.earner_id AND p.player_id=c.player_id WHERE c.id=$1 AND c.earner_id=$2 AND c.qualification_source='admin_presentation'",[b.id,user])).rows[0];
  if(!c)fail('Only an admin presentation edition may use the demonstration buyer.',403);
  const buyerKeyPath=process.env.PRESENTATION_BUYER_KEYPAIR;
  const buyerKeyJson=process.env.PRESENTATION_BUYER_KEYPAIR_JSON;
  if(!buyerKeyPath&&!buyerKeyJson)fail('The presentation buyer is not configured. Fund and configure a dedicated devnet buyer wallet.');
  const buyer=Keypair.fromSecretKey(Uint8Array.from(JSON.parse(buyerKeyJson||readFileSync(buyerKeyPath,'utf8'))));
  const buyerAddress=buyer.publicKey.toBase58();
  if(buyerAddress===await wallet(user))fail('The presentation buyer must use a different wallet.');
  if(await chain.getBalance(buyer.publicKey)<101000000)fail(`The presentation buyer needs at least 0.101 devnet SOL. Fund ${buyerAddress}.`);
  let buyerUser=(await pool.query('SELECT user_id FROM collectible_wallets WHERE address=$1 AND verified',[buyerAddress])).rows[0]?.user_id;
  if(!buyerUser){
   buyerUser=await tx(async db=>{
    const id=(await db.query("INSERT INTO users(email,password_hash) VALUES ($1,'!presentation-wallet-only') ON CONFLICT DO NOTHING RETURNING id",[`presentation-buyer-${buyerAddress}@example.invalid`])).rows[0]?.id??(await db.query('SELECT id FROM users WHERE email=$1',[`presentation-buyer-${buyerAddress}@example.invalid`])).rows[0].id;
    await db.query("INSERT INTO profiles(user_id,display_name,handle,tag) VALUES ($1,'Presentation buyer · DEMO',$2,'0000') ON CONFLICT(user_id) DO NOTHING",[id,`DEMO${buyerAddress.slice(0,12).toUpperCase()}`]);
    await db.query('INSERT INTO collectible_wallets(user_id,address,verified) VALUES ($1,$2,true) ON CONFLICT(user_id) DO NOTHING',[id,buyerAddress]);return id;
   });
  }
  const history=(await pool.query("SELECT * FROM collectible_sales WHERE collectible_id=$1 AND seller_id=$2 AND status IN ('listed','signing','submitted','confirmed') ORDER BY created_at DESC LIMIT 1",[c.id,user])).rows[0];
  if(history?.status==='confirmed')return {id:history.id,status:'confirmed'};
  let listing=history;
  if(!listing)listing=await dispatch('list','POST',{id:c.id,price:'0.1'},user);
  let sale=(await pool.query('SELECT * FROM collectible_sales WHERE id=$1',[listing.id])).rows[0];
  if(sale.status==='listed')await dispatch('offer','POST',{id:listing.id},buyerUser);
  sale=(await pool.query('SELECT * FROM collectible_sales WHERE id=$1',[listing.id])).rows[0];
  if(sale.buyer_id!==buyerUser)fail('Another buyer has already reserved this sale. Review that sale before continuing.');
  if(sale.status==='signing'){
   const t=Transaction.from(Buffer.from(sale.transaction_bytes,'base64'));t.partialSign(buyer);
   await dispatch('sign','POST',{id:sale.id,transaction:t.serialize({requireAllSignatures:false}).toString('base64')},buyerUser);
  }
  return {id:sale.id,status:sale.status,buyer:buyerAddress,lamports:sale.lamports};
 }
 if(path==='handoff' && method==='POST'){
  const ticket=randomBytes(32).toString('hex');await pool.query("INSERT INTO collectible_sessions VALUES ($1,$2,'handoff',now()+interval '2 minutes')",[hash(ticket),user]);
  return {url:`${base.origin}/collectibles/index.html#${ticket}`};
 }
 if(path==='session' && method==='POST')return tx(async db=>{
  const r=await db.query("DELETE FROM collectible_sessions WHERE token_hash=$1 AND purpose='handoff' AND expires_at>now() RETURNING user_id",[hash(String(b.ticket))]);
  if(!r.rowCount)fail('This link expired. Open collectibles again from your profile.',401);
  const token=randomBytes(32).toString('hex');await db.query("INSERT INTO collectible_sessions VALUES ($1,$2,'session',now()+interval '30 minutes')",[hash(token),r.rows[0].user_id]);return {token};
 });
 if(path==='wallet/challenge' && method==='POST'){
  const addr=address(b.address);const old=(await pool.query('SELECT address,verified FROM collectible_wallets WHERE user_id=$1',[user])).rows[0];
  if(old?.verified && old.address!==addr)fail('Use your already linked demo wallet for this account.');
  const message=`Sports Swipe devnet wallet verification\nOrigin: ${base.origin}\nAccount: ${user}\nWallet: ${addr}\nNonce: ${randomBytes(24).toString('hex')}\nThis signature does not authorize a payment.`;
  await pool.query(`INSERT INTO collectible_wallets(user_id,address,challenge,challenge_expires) VALUES ($1,$2,$3,now()+interval '5 minutes')
   ON CONFLICT(user_id) DO UPDATE SET challenge=EXCLUDED.challenge,challenge_expires=EXCLUDED.challenge_expires,address=EXCLUDED.address`,[user,addr,message]);return {message};
 }
 if(path==='wallet/verify' && method==='POST')return tx(async db=>{
  const w=(await db.query('SELECT * FROM collectible_wallets WHERE user_id=$1 FOR UPDATE',[user])).rows[0];
  if(!w?.challenge||new Date(w.challenge_expires)<new Date())fail('Wallet challenge expired. Connect again.');
  if(!nacl.sign.detached.verify(Buffer.from(w.challenge),Buffer.from(b.signature,'base64'),new PublicKey(w.address).toBytes()))fail('Wallet signature could not be verified.');
  await db.query('UPDATE collectible_wallets SET verified=true,challenge=NULL WHERE user_id=$1',[user]);return {address:w.address};
 });
 if(path==='dashboard' && method==='GET'){
  const pending=await pool.query("SELECT * FROM collectible_sales WHERE status IN ('signing','submitted')");
  for(const s of pending.rows)await reconcileSale(s);
  const owned=(await pool.query('SELECT address FROM collectible_wallets WHERE user_id=$1 AND verified',[user])).rows[0]?.address;
  const cards=await pool.query(`SELECT p.id AS player_id,p.full_name,p.collectible_demo,COALESCE(q.earned_calls,0) AS qualifying_calls,q.qualification_source,mt.correct_count AS mastery_calls FROM mastery_totals mt JOIN players p ON p.id=mt.player_id
    LEFT JOIN (${eligibleSql}) q ON q.player_id=p.id WHERE mt.user_id=$1 ORDER BY p.full_name`,[user]);
  const collectibles=(await pool.query('SELECT * FROM diamond_collectibles ORDER BY edition DESC LIMIT 100')).rows;
  const out=[];
  for(const c of collectibles){
   const asset=c.asset_address?await assetAt(c):null;
   if(asset && !c.minted_at){await pool.query('UPDATE diamond_collectibles SET minted_at=now() WHERE id=$1',[c.id]);c.minted_at=new Date().toISOString();}
   const owner=asset?.owner??null;
   const ownerProfile=owner?(await pool.query('SELECT p.display_name FROM collectible_wallets w JOIN profiles p ON p.user_id=w.user_id WHERE w.address=$1 AND w.verified',[owner])).rows[0]?.display_name:null;
   out.push({...c,owner,owner_name:ownerProfile??null,is_owner:!!owned&&owner===owned,is_earner:c.earner_id===user,asset_url:c.asset_address?explorer('address',c.asset_address):null});
  }
  const sales=(await pool.query('SELECT * FROM collectible_sales ORDER BY created_at DESC LIMIT 200')).rows.map(s=>({...s,transaction_bytes:undefined,transaction_url:s.signature?explorer('tx',s.signature):null,is_seller:s.seller_id===user,is_buyer:s.buyer_id===user}));
  return {demo_controls:process.env.ENABLE_DIAMOND_DEMO==='true'&&['localhost','127.0.0.1'].includes(new URL(process.env.DATABASE_URL).hostname),network:'devnet',wallet:owned??null,issuer:issuer.publicKey.toBase58(),cards:cards.rows,collectibles:out,sales};
 }
 if(path==='claim' && method==='POST'){
  const owner=await wallet(user);
  const c=await tx(async db=>{
   await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',[user]);
   const eligible=(await db.query(eligibleSql,[user])).rows.find(c=>String(c.player_id)===String(b.playerId));
   if(!eligible||eligible.earned_calls<400)fail('This athlete needs 400 correct free, unstaked calls. Coin purchases and paid packs do not count.');
   const p=(await db.query('SELECT full_name,collectible_demo FROM players WHERE id=$1',[b.playerId])).rows[0];
   if(!p.collectible_demo)fail('This prototype mints fictional demo athletes only.');
   const name=(await db.query('SELECT display_name FROM profiles WHERE user_id=$1',[user])).rows[0].display_name;
   await db.query(`INSERT INTO diamond_collectibles(earner_id,player_id,earner_name,athlete_name,season,earned_calls,qualification_source) VALUES ($1,$2,$3,$4,$6,$5,$7) ON CONFLICT(earner_id,player_id) DO NOTHING`,[user,b.playerId,name,p.full_name,eligible.earned_calls,eligible.earned_season,eligible.qualification_source]);
   const row=(await db.query('SELECT * FROM diamond_collectibles WHERE earner_id=$1 AND player_id=$2 FOR UPDATE',[user,b.playerId])).rows[0];
   if(row.asset_address && await assetAt(row))return row;
   if(row.mint_transaction && await chain.getBlockHeight('finalized')<=Number(row.mint_block_height))return row;
   const key=Keypair.fromSeed(createHmac('sha256',issuer.secretKey).update(`Sports Swipe devnet asset:${row.id}`).digest());
   const signer=createSignerFromKeypair(umi,umi.eddsa.createKeypairFromSecretKey(key.secretKey));
   const latest=await chain.getLatestBlockhash();
   const builder=create(umi,{asset:signer,name:`SS Diamond #${row.edition}`,uri:metadata(row.id),owner:publicKey(owner),plugins:[{type:'Attributes',attributeList:[{key:'original_earner',value:user},{key:'season',value:String(row.season)},{key:'edition',value:String(row.edition)},{key:'qualifying_calls',value:String(row.earned_calls)}]}]}).useLegacyVersion().setBlockhash(latest.blockhash);
   const signed=await builder.buildAndSign(umi);const bytes=Buffer.from(umi.transactions.serialize(signed));const signature=bs58.encode(signed.signatures[0]);
   return (await db.query('UPDATE diamond_collectibles SET asset_address=$2,mint_transaction=$3,mint_signature=$4,mint_block_height=$5 WHERE id=$1 RETURNING *',[row.id,key.publicKey.toBase58(),bytes.toString('base64'),signature,latest.lastValidBlockHeight])).rows[0];
  });
  if(!await assetAt(c)){
   const signature=await chain.sendRawTransaction(Buffer.from(c.mint_transaction,'base64'),{skipPreflight:false});
   await chain.confirmTransaction({signature,blockhash:Transaction.from(Buffer.from(c.mint_transaction,'base64')).recentBlockhash,lastValidBlockHeight:Number(c.mint_block_height)},'confirmed');
  }
  const asset=await assetAt(c);if(!asset)fail('Mint is still confirming. Retry safely to check the same card.',503);
  await pool.query('UPDATE diamond_collectibles SET minted_at=COALESCE(minted_at,now()) WHERE id=$1',[c.id]);
  return {id:c.id,asset:c.asset_address,signature:c.mint_signature,transaction_url:explorer('tx',c.mint_signature)};
 }
 if(path==='list' && method==='POST'){
  const seller=await wallet(user);const c=(await pool.query('SELECT * FROM diamond_collectibles WHERE id=$1',[b.id])).rows[0];if(!c)fail('Card not found.',404);
  if((await assetAt(c))?.owner!==seller)fail('Only the current on-chain owner can list this card.');
  const sale=(await pool.query('INSERT INTO collectible_sales(collectible_id,seller_id,seller_wallet,lamports) VALUES ($1,$2,$3,$4) RETURNING id',[c.id,user,seller,price(b.price)])).rows[0];return sale;
 }
 if(path==='offer' && method==='POST'){
  const buyer=await wallet(user);
  return tx(async db=>{
   const s=(await db.query("SELECT * FROM collectible_sales WHERE id=$1 AND status='listed' FOR UPDATE",[b.id])).rows[0];if(!s)fail('Listing is no longer available.');if(s.seller_wallet===buyer)fail('Use the second demo account and wallet to buy.');
   const c=(await db.query('SELECT * FROM diamond_collectibles WHERE id=$1',[s.collectible_id])).rows[0];const asset=await assetAt(c);if(asset?.owner!==s.seller_wallet)fail('The seller no longer owns this card.');
   const latest=await chain.getLatestBlockhash();
   const t=new Transaction({feePayer:new PublicKey(buyer),...latest}).add(SystemProgram.transfer({fromPubkey:new PublicKey(buyer),toPubkey:new PublicKey(s.seller_wallet),lamports:BigInt(s.lamports)}));
   const instructions=transfer(umi,{asset,newOwner:publicKey(buyer),payer:createNoopSigner(publicKey(buyer)),authority:createNoopSigner(publicKey(s.seller_wallet))}).getInstructions();
   t.add(...instructions.map(toWeb3JsInstruction));
   await db.query("UPDATE collectible_sales SET buyer_id=$2,buyer_wallet=$3,transaction_bytes=$4,block_height=$5,status='signing' WHERE id=$1",[s.id,user,buyer,t.serialize({requireAllSignatures:false}).toString('base64'),latest.lastValidBlockHeight]);return {id:s.id};
  });
 }
 if(path==='transaction' && method==='POST'){
  const s=(await pool.query('SELECT * FROM collectible_sales WHERE id=$1',[b.id])).rows[0];
  if(!s||![s.buyer_id,s.seller_id].includes(user)||s.status!=='signing')fail('No sale is waiting for your signature.');
  if(await chain.getBlockHeight('finalized')>Number(s.block_height)){await pool.query("UPDATE collectible_sales SET status='expired' WHERE id=$1",[s.id]);fail('Transaction expired. Both fans must start a new sale.');}
  return {transaction:s.transaction_bytes,summary:`Pay ${Number(s.lamports)/1e9} devnet SOL to ${s.seller_wallet} and transfer the Diamond card to ${s.buyer_wallet}. Buyer pays network fee.`};
 }
 if(path==='sign' && method==='POST'){
  const signer=await wallet(user);
  const signed=await tx(async db=>{
   const s=(await db.query("SELECT * FROM collectible_sales WHERE id=$1 AND status='signing' FOR UPDATE",[b.id])).rows[0];
   if(!s||![s.buyer_id,s.seller_id].includes(user)||![s.buyer_wallet,s.seller_wallet].includes(signer))fail('This sale does not need your signature.');
   if(await chain.getBlockHeight('finalized')>Number(s.block_height))fail('This sale expired. Refresh and start again.');
   const t=mergeTransaction(s.transaction_bytes,b.transaction,signer);const bytes=t.serialize({requireAllSignatures:false});
   const ready=t.verifySignatures();const signature=ready?bs58.encode(t.signature):null;
   await db.query('UPDATE collectible_sales SET transaction_bytes=$2,status=$3,signature=$4 WHERE id=$1',[s.id,bytes.toString('base64'),ready?'submitted':'signing',signature]);return {...s,bytes,signature,ready};
  });
  if(signed.ready){try{await chain.sendRawTransaction(signed.bytes,{skipPreflight:false});}catch(e){console.error('Sale broadcast needs retry:',e.message);}}
  return {status:signed.ready?'submitted':'waiting_for_other_wallet'};
 }
 if(path==='retry' && method==='POST'){
  const s=(await pool.query("SELECT * FROM collectible_sales WHERE id=$1 AND status='submitted' AND (buyer_id=$2 OR seller_id=$2)",[b.id,user])).rows[0];if(!s)fail('No submitted sale found.');
  await reconcileSale(s);await chain.sendRawTransaction(Buffer.from(s.transaction_bytes,'base64'),{skipPreflight:false});return {status:'submitted'};
 }
 if(path==='cancel' && method==='POST'){
  // Signed transactions can still execute until expiry, so only unsigned listings may be cancelled.
  await pool.query("UPDATE collectible_sales SET status='cancelled' WHERE id=$1 AND seller_id=$2 AND status='listed'",[b.id,user]);return {ok:true};
 }
 fail('Unknown devnet action.',404);
}

http.createServer(async(req,res)=>{
 try{
  const provided=Buffer.from(req.headers['x-service-key']||'');const expected=Buffer.from(secret);
  if(provided.length!==expected.length||!timingSafeEqual(provided,expected))fail('Unauthorized.',401);
  const path=decodeURIComponent(new URL(req.url,'http://localhost').pathname.slice(1));
  if(path.startsWith('public/')&&req.method==='GET'){
   const parts=path.split('/');const c=(await pool.query('SELECT * FROM diamond_collectibles WHERE id=$1',[parts[1]])).rows[0];if(!c)fail('Card not found.',404);
   if(parts[2]==='image'){
    res.writeHead(200,{'content-type':'image/svg+xml'});res.end(`<svg xmlns="http://www.w3.org/2000/svg" width="600" height="840"><defs><linearGradient id="g"><stop stop-color="#c9f6ff"/><stop offset=".5" stop-color="#e5ccff"/><stop offset="1" stop-color="#b5e8ff"/></linearGradient></defs><rect width="600" height="840" rx="32" fill="url(#g)"/><rect x="12" y="12" width="576" height="816" rx="24" fill="#102b25"/><text x="44" y="75" fill="#def4e9" font-family="sans-serif" font-size="24">SPORTS SWIPE · DEVNET DEMO</text><path d="M205 190L270 160Q300 200 330 160L395 190L450 295L380 325L365 280V560H235V280L220 325L150 295Z" fill="#784cc6" stroke="#d9ecff" stroke-width="5"/><text x="300" y="430" text-anchor="middle" font-family="sans-serif" font-weight="bold" font-size="110" fill="white">7</text><text x="44" y="640" fill="white" font-family="sans-serif" font-size="28">FICTIONAL ATHLETE · DIAMOND</text><text x="44" y="700" fill="#c9f6ff" font-family="sans-serif" font-size="32">EDITION #${c.edition} · ${c.season}</text><text x="44" y="775" fill="#b5c9c0" font-family="sans-serif" font-size="22">${c.qualification_source==='admin_presentation'?'ADMIN PRESENTATION · DEMO GRANT':'400 FREE CORRECT CALLS · TEST COLLECTIBLE'}</text></svg>`);return;
   }
   res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({name:`${c.athlete_name} Diamond #${c.edition}`,description:'Fictional Sports Swipe devnet collectible. No cash redemption or promised resale value. Mastery remains with the original earner.',image:`${metadata(c.id)}/image`,attributes:[{trait_type:'Season',value:c.season},{trait_type:'Edition',value:c.edition},{trait_type:'Original earner',value:c.earner_name},{trait_type:'Earner account',value:c.earner_id},{trait_type:'Qualification source',value:c.qualification_source},{trait_type:c.qualification_source==='admin_presentation'?'Admin demo grant calls':'Qualifying free calls',value:c.earned_calls},{trait_type:'Network',value:'Solana devnet'}]}));return;
  }
  let body='';for await(const chunk of req){body+=chunk;if(body.length>20000)fail('Request too large.',413);}const b=body?JSON.parse(body):{};
  let user=req.headers['x-user-id'];
  if(!user && path!=='session')user=(await pool.query("SELECT user_id FROM collectible_sessions WHERE token_hash=$1 AND purpose='session' AND expires_at>now()",[hash(req.headers['x-collectible-session']||'')])).rows[0]?.user_id;
  if(!user&&path!=='session')fail('Open collectibles from your signed-in Sports Swipe profile.',401);
  const result=await dispatch(path,req.method,b,user);res.writeHead(200,{'content-type':'application/json','cache-control':'no-store'});res.end(JSON.stringify(result));
 }catch(e){console.error(e.message);res.writeHead(e.status||400,{'content-type':'application/json','cache-control':'no-store'});res.end(JSON.stringify({message:e.code==='23505'?'This wallet, claim, or live listing already exists. Refresh to continue.':e.message}));}
}).listen(Number(process.env.COLLECTIBLES_PORT||8091),'0.0.0.0',()=>console.log('Sports Swipe collectibles: DEVNET ONLY'));
