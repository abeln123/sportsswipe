import {PublicKey, Transaction, SystemProgram} from '@solana/web3.js';
import {createNoopSigner, publicKey} from '@metaplex-foundation/umi';
import {transfer} from '@metaplex-foundation/mpl-core';
import {toWeb3JsInstruction} from '@metaplex-foundation/umi-web3js-adapters';
import bs58 from 'bs58';
import {mergeTransaction} from './policy.mjs';

export function buildResetTransaction(umi, asset, sale, buyer, latest) {
 const transaction = new Transaction({feePayer:buyer.publicKey,...latest})
  .add(SystemProgram.transfer({fromPubkey:new PublicKey(sale.seller_wallet),toPubkey:buyer.publicKey,lamports:BigInt(sale.lamports)}));
 transaction.add(...transfer(umi,{asset,newOwner:publicKey(sale.seller_wallet),
  payer:createNoopSigner(publicKey(buyer.publicKey.toBase58())),
  authority:createNoopSigner(publicKey(buyer.publicKey.toBase58()))}).getInstructions().map(toWeb3JsInstruction));
 transaction.partialSign(buyer);
 return transaction;
}

export function presentationResetService({pool,chain,umi,assetAt,wallet,buyerKey,fail,explorer}) {
 async function atomic(fn) {
  const db=await pool.connect();
  try {await db.query('BEGIN');const result=await fn(db);await db.query('COMMIT');return result;}
  catch(e){await db.query('ROLLBACK');throw e;} finally {db.release();}
 }
 async function admin(user) {
  if(!(await pool.query('SELECT is_admin FROM users WHERE id=$1',[user])).rows[0]?.is_admin)fail('Presentation resets are admin-only.',403);
 }
 async function saleFor(user,cardId) {
  const s=(await pool.query(`SELECT s.*,c.asset_address,c.earner_id,c.qualification_source FROM collectible_sales s
   JOIN diamond_collectibles c ON c.id=s.collectible_id JOIN presentation_entitlements p ON p.user_id=c.earner_id AND p.player_id=c.player_id
   WHERE s.seller_id=$1 AND c.earner_id=$1 AND c.qualification_source='admin_presentation'
    AND ($2::uuid IS NULL OR c.id=$2) ORDER BY s.created_at DESC LIMIT 1`,[user,cardId??null])).rows[0];
  if(!s)fail('No presentation sale was found for this card.',404);
  if(await wallet(user)!==s.seller_wallet)fail('Connect the wallet that sold this card before resetting.');
  return s;
 }
 const response=r=>({id:r.id,status:r.status,reset:r.status==='confirmed',
  ...(r.status==='signing'?{transaction:r.transaction_bytes}:{}),
  transaction_url:r.signature?explorer('tx',r.signature):null,
  summary:'Return the Diamond to your wallet and refund 0.1 devnet SOL to the presentation buyer. Both happen together.'});
 async function reconcile(r) {
  if(r.status!=='submitted'||!r.signature)return r;
  const info=(await chain.getSignatureStatuses([r.signature],{searchTransactionHistory:true})).value[0];
  if(info&&!info.err&&['confirmed','finalized'].includes(info.confirmationStatus)){
   const s=(await pool.query('SELECT s.*,c.asset_address FROM collectible_sales s JOIN diamond_collectibles c ON c.id=s.collectible_id WHERE s.id=$1',[r.sale_id])).rows[0];
   if((await assetAt(s))?.owner!==s.seller_wallet)fail('Reset confirmed, but the returned card is still being verified. Refresh shortly.',503);
   return (await pool.query("UPDATE presentation_sale_resets SET status='confirmed',confirmed_at=COALESCE(confirmed_at,now()) WHERE id=$1 RETURNING *",[r.id])).rows[0];
  }
  if(info?.err||await chain.getBlockHeight('finalized')>Number(r.block_height)){
   return (await pool.query("UPDATE presentation_sale_resets SET status='expired' WHERE id=$1 RETURNING *",[r.id])).rows[0];
  }
  return r;
 }
 async function broadcast(r) {
  try{await chain.sendRawTransaction(Buffer.from(r.transaction_bytes,'base64'),{skipPreflight:false});}
  catch(e){console.error('Reset broadcast can be retried:',e.message);}
  return reconcile(r);
 }
 async function prepare(user,b) {
  await admin(user);
  const s=await saleFor(user,b.id);
  if(s.status!=='confirmed') {
   if(s.status==='listed') {
    await pool.query("UPDATE collectible_sales SET status='cancelled' WHERE id=$1 AND status='listed'",[s.id]);
    return {reset:true,status:'confirmed',summary:'Unsigned demo listing cancelled. The card stays in your wallet.'};
   }
   if(['cancelled','expired'].includes(s.status))return {reset:true,status:'confirmed'};
   fail('Wait for the sale to confirm or expire before resetting it.');
  }
  let existing=(await pool.query('SELECT * FROM presentation_sale_resets WHERE sale_id=$1',[s.id])).rows[0];
  if(existing){
   existing=await reconcile(existing);
   if(existing.status==='confirmed')return response(existing);
   if(existing.status==='submitted')return response(await broadcast(existing));
  }
  return atomic(async db=>{
   await db.query('SELECT id FROM collectible_sales WHERE id=$1 FOR UPDATE',[s.id]);
   let prior=(await db.query('SELECT * FROM presentation_sale_resets WHERE sale_id=$1 FOR UPDATE',[s.id])).rows[0];
   if(prior?.status==='confirmed'||prior?.status==='submitted')return response(prior);
   if(prior?.status==='signing'&&await chain.getBlockHeight('finalized')<=Number(prior.block_height))return response(prior);
   const buyer=buyerKey();
   if(buyer.publicKey.toBase58()!==s.buyer_wallet)fail('This sale was not made to the configured presentation buyer.');
   const asset=await assetAt(s);
   if(asset?.owner!==s.buyer_wallet)fail('The presentation buyer no longer owns this card.');
   if(await chain.getBalance(new PublicKey(s.seller_wallet))<Number(s.lamports))fail('Your devnet wallet needs the sale proceeds to refund the demo buyer.');
   if(await chain.getBalance(buyer.publicKey)<15000)fail('The presentation buyer needs a small amount of devnet SOL for the reset network fee.');
   const latest=await chain.getLatestBlockhash();
   const transaction=buildResetTransaction(umi,asset,s,buyer,latest).serialize({requireAllSignatures:false}).toString('base64');
   const row=(await db.query(`INSERT INTO presentation_sale_resets(sale_id,transaction_bytes,block_height,status) VALUES($1,$2,$3,'signing')
    ON CONFLICT(sale_id) DO UPDATE SET transaction_bytes=EXCLUDED.transaction_bytes,block_height=EXCLUDED.block_height,status='signing',signature=NULL,confirmed_at=NULL RETURNING *`,[s.id,transaction,latest.lastValidBlockHeight])).rows[0];
   return response(row);
  });
 }
 async function sign(user,b) {
  await admin(user);
  const signer=await wallet(user);
  const row=await atomic(async db=>{
   const r=(await db.query('SELECT r.*,s.seller_id,s.seller_wallet FROM presentation_sale_resets r JOIN collectible_sales s ON s.id=r.sale_id WHERE r.id=$1 FOR UPDATE OF r',[b.id])).rows[0];
   if(!r||r.seller_id!==user||r.seller_wallet!==signer)fail('This reset belongs to another wallet.',403);
   if(r.status==='confirmed'||r.status==='submitted')return r;
   if(r.status!=='signing'||await chain.getBlockHeight('finalized')>Number(r.block_height))fail('Reset approval expired. Tap Reset demo sale to prepare a fresh transaction.');
   const full=mergeTransaction(r.transaction_bytes,b.transaction,signer);
   if(!full.verifySignatures())fail('Both reset signatures are required.');
   return (await db.query("UPDATE presentation_sale_resets SET transaction_bytes=$2,signature=$3,status='submitted' WHERE id=$1 RETURNING *",[r.id,full.serialize().toString('base64'),bs58.encode(full.signature)])).rows[0];
  });
  return response(row.status==='confirmed'?row:await broadcast(row));
 }
 async function dashboard(user) {
  const rows=(await pool.query(`SELECT r.*,s.collectible_id FROM presentation_sale_resets r JOIN collectible_sales s ON s.id=r.sale_id WHERE s.seller_id=$1 ORDER BY r.created_at DESC`,[user])).rows;
  const out=[];
  for(const r of rows){const latest=await reconcile(r);out.push({...response(latest),collectible_id:r.collectible_id,sale_id:r.sale_id});}
  return out;
 }
 return {prepare,sign,dashboard};
}
