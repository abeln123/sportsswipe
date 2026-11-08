import test from 'node:test';
import assert from 'node:assert/strict';
import { Keypair, Transaction, SystemProgram } from '@solana/web3.js';
import { createUmi } from '@metaplex-foundation/umi-bundle-defaults';
import { createSignerFromKeypair, signerIdentity, publicKey, createNoopSigner } from '@metaplex-foundation/umi';
import { create, transfer, mplCore } from '@metaplex-foundation/mpl-core';
import { toWeb3JsInstruction } from '@metaplex-foundation/umi-web3js-adapters';
import bs58 from 'bs58';
import { price, mergeTransaction } from '../src/policy.mjs';
const buyer=Keypair.generate(), seller=Keypair.generate(), key=Keypair.generate();
const blockhash=Keypair.generate().publicKey.toBase58();
const umi=createUmi('https://api.devnet.solana.com').use(mplCore());
umi.use(signerIdentity(createSignerFromKeypair(umi,umi.eddsa.createKeypairFromSecretKey(seller.secretKey))));
const encode=t=>t.serialize({requireAllSignatures:false}).toString('base64');
function sale(){return new Transaction({feePayer:buyer.publicKey,recentBlockhash:blockhash})
 .add(SystemProgram.transfer({fromPubkey:buyer.publicKey,toPubkey:seller.publicKey,lamports:100000000}))
 .add(...transfer(umi,{asset:{publicKey:publicKey(key.publicKey.toBase58()),owner:publicKey(seller.publicKey.toBase58())},newOwner:publicKey(buyer.publicKey.toBase58()),payer:createNoopSigner(publicKey(buyer.publicKey.toBase58())),authority:createNoopSigner(publicKey(seller.publicKey.toBase58()))}).getInstructions().map(toWeb3JsInstruction));}
test('price uses exact lamports, rejects floating ambiguity and invalid ranges',()=>{
 assert.equal(price('0.1'),100000000);assert.equal(price('0.000000001'),1);
 for(const value of ['0','-1','1e-3','0.0000000001','11',NaN,0.1])assert.throws(()=>price(value));
});
test('both wallets sign same payment and Core transfer; neither can change the price',()=>{
 const original=sale();assert.equal(original.instructions.length,2);
 const a=Transaction.from(Buffer.from(encode(original),'base64'));a.partialSign(buyer);
 const half=mergeTransaction(encode(original),encode(a),buyer.publicKey.toBase58());assert.equal(half.verifySignatures(),false);
 const b=Transaction.from(Buffer.from(encode(half),'base64'));b.partialSign(seller);
 const full=mergeTransaction(encode(half),encode(b),seller.publicKey.toBase58());assert.equal(full.verifySignatures(),true);
 assert.equal(Transaction.from(full.serialize()).instructions.length,2);
 const changed=sale();changed.instructions[0]=SystemProgram.transfer({fromPubkey:buyer.publicKey,toPubkey:seller.publicKey,lamports:1});changed.partialSign(buyer);
 assert.throws(()=>mergeTransaction(encode(original),encode(changed),buyer.publicKey.toBase58()),/changed/);
 assert.throws(()=>mergeTransaction(encode(original),encode(a),seller.publicKey.toBase58()),/missing/);
});
test('mint serializes to real Solana transaction and issuer signature is recoverable',async()=>{
 const signer=createSignerFromKeypair(umi,umi.eddsa.createKeypairFromSecretKey(key.secretKey));
 const tx=await create(umi,{asset:signer,name:'Fictional Diamond #1',uri:'https://example.test/metadata',owner:publicKey(buyer.publicKey.toBase58()),plugins:[{type:'Attributes',attributeList:[{key:'original_earner',value:'demo-earner'}]}]}).useLegacyVersion().setBlockhash(blockhash).buildAndSign(umi);
 const decoded=Transaction.from(umi.transactions.serialize(tx));assert.ok(decoded.verifySignatures());
 assert.equal(bs58.encode(tx.signatures[0]),bs58.encode(decoded.signature));
 assert.equal(decoded.feePayer.toBase58(),seller.publicKey.toBase58());
});
