import{Transaction}from'@solana/web3.js';
import{Buffer}from'buffer';
let provider;
window.sportsSwipeWallet={
 async connect(){provider=window.phantom?.solana??window.solflare;if(!provider)throw new Error('Install Phantom or Solflare and set it to devnet. This presentation flow uses a browser wallet.');await provider.connect();return provider.publicKey.toString();},
 async signMessage(message){if(!provider)throw new Error('Connect a wallet first.');const s=await provider.signMessage(new TextEncoder().encode(message),'utf8');return Buffer.from(s.signature??s).toString('base64');},
 async signTransaction(bytes){if(!provider)throw new Error('Connect a wallet first.');const signed=await provider.signTransaction(Transaction.from(Buffer.from(bytes,'base64')));return Buffer.from(signed.serialize({requireAllSignatures:false})).toString('base64');}
};
