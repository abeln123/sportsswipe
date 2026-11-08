import { mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { Connection, Keypair } from '@solana/web3.js';
import { DEVNET_GENESIS } from './policy.mjs';
mkdirSync('.keys',{recursive:true});
if(existsSync('.keys/issuer.json'))throw new Error('Issuer already exists; keep it to preserve retryable claim addresses.');
const key=Keypair.generate();writeFileSync('.keys/issuer.json',JSON.stringify([...key.secretKey]),{mode:0o600,flag:'wx'});
console.log('Devnet issuer public address:',key.publicKey.toBase58());
if(process.argv.includes('--airdrop')){
 const rpc=new Connection(process.env.SOLANA_DEVNET_RPC||'https://api.devnet.solana.com','confirmed');
 if(await rpc.getGenesisHash()!==DEVNET_GENESIS)throw new Error('Devnet only.');
 try{const signature=await rpc.requestAirdrop(key.publicKey,1000000000);console.log('Devnet faucet request:',signature);}catch(e){console.log('Faucet unavailable. Fund the public address with test SOL at https://faucet.solana.com/.',e.message);}
}
