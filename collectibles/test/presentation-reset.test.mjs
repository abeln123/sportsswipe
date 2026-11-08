import test from 'node:test';
import assert from 'node:assert/strict';
import {Keypair,Transaction,SystemInstruction,SystemProgram} from '@solana/web3.js';
import {createUmi} from '@metaplex-foundation/umi-bundle-defaults';
import {publicKey} from '@metaplex-foundation/umi';
import {mplCore} from '@metaplex-foundation/mpl-core';
import {buildResetTransaction,presentationResetService} from '../src/presentation-reset.mjs';
import {mergeTransaction} from '../src/policy.mjs';
const buyer=Keypair.generate(),seller=Keypair.generate(),assetKey=Keypair.generate();
const umi=createUmi('https://api.devnet.solana.com').use(mplCore());
const asset={publicKey:publicKey(assetKey.publicKey.toBase58()),owner:publicKey(buyer.publicKey.toBase58())};
const sale={seller_wallet:seller.publicKey.toBase58(),lamports:'100000000'};
const latest={blockhash:Keypair.generate().publicKey.toBase58(),lastValidBlockHeight:100};
const encode=t=>t.serialize({requireAllSignatures:false}).toString('base64');
test('reset atomically refunds the exact sale payment and returns the existing Core asset',()=>{
 const half=buildResetTransaction(umi,asset,sale,buyer,latest);
 assert.equal(half.instructions.length,2);
 const payment=SystemInstruction.decodeTransfer(half.instructions[0]);
 assert.equal(payment.fromPubkey.toBase58(),seller.publicKey.toBase58());
 assert.equal(payment.toPubkey.toBase58(),buyer.publicKey.toBase58());
 assert.equal(payment.lamports,100000000n);
 assert.equal(half.feePayer.toBase58(),buyer.publicKey.toBase58());
 assert.equal(half.verifySignatures(),false);
 const approved=Transaction.from(Buffer.from(encode(half),'base64'));approved.partialSign(seller);
 assert.equal(mergeTransaction(encode(half),encode(approved),seller.publicKey.toBase58()).verifySignatures(),true);
});
test('reset rejects a changed refund or a missing seller signature',()=>{
 const expected=buildResetTransaction(umi,asset,sale,buyer,latest);
 const changed=Transaction.from(Buffer.from(encode(expected),'base64'));
 changed.instructions[0]=SystemProgram.transfer({fromPubkey:seller.publicKey,toPubkey:buyer.publicKey,lamports:1});changed.partialSign(seller);
 assert.throws(()=>mergeTransaction(encode(expected),changed.serialize({requireAllSignatures:false,verifySignatures:false}).toString('base64'),seller.publicKey.toBase58()),/changed/);
 assert.throws(()=>mergeTransaction(encode(expected),encode(expected),seller.publicKey.toBase58()),/missing/);
});
test('reset rejects non-admin accounts before touching any sale',async()=>{
 let queries=0;
 const service=presentationResetService({pool:{query:async()=>{queries++;return {rows:[{is_admin:false}]};}},
 fail:(message,status)=>{throw Object.assign(new Error(message),{status});}});
 await assert.rejects(service.prepare('ordinary',{}),e=>e.status===403);
 assert.equal(queries,1);
});
