import { PublicKey, Transaction } from '@solana/web3.js';
import nacl from 'tweetnacl';
export const DEVNET_GENESIS = 'EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG';
const earnedSql = `SELECT me.player_id, count(*)::int AS earned_calls, (array_agg(g.season ORDER BY me.created_at,me.market_id))[400] AS earned_season
 FROM mastery_events me JOIN entries e ON e.id=me.entry_id
 JOIN entry_legs el ON el.entry_id=e.id AND el.market_id=me.market_id
 JOIN players p ON p.id=me.player_id JOIN markets m ON m.id=me.market_id JOIN games g ON g.id=m.game_id
 JOIN market_results mr ON mr.market_id=me.market_id AND mr.revision=el.result_revision
 WHERE me.user_id=$1 AND e.kind='single' AND e.stake=0 AND e.status='won' AND el.result='win'
 AND (mr.source='espn' OR (p.collectible_demo AND mr.source='admin_demo'))
 AND NOT EXISTS(SELECT 1 FROM pack_cards pc JOIN pack_purchases pp ON pp.id=pc.purchase_id WHERE pc.entry_id=e.id AND pp.price>0)
 GROUP BY me.player_id`;
export const eligibleSql = `SELECT player_id,max(earned_calls)::int AS earned_calls,max(earned_season)::int AS earned_season,
 CASE WHEN bool_or(source='admin_presentation') THEN 'admin_presentation' ELSE 'earned' END AS qualification_source
 FROM (SELECT q.*,'earned' AS source FROM (${earnedSql}) q UNION ALL
 SELECT pe.player_id,pe.calls,pe.season,'admin_presentation' FROM presentation_entitlements pe
 JOIN users u ON u.id=pe.user_id AND u.is_admin JOIN players p ON p.id=pe.player_id AND p.collectible_demo
 WHERE pe.user_id=$1) eligible GROUP BY player_id`;

export function address(value) { return new PublicKey(value).toBase58(); }
export function price(value) {
 if(typeof value!=='string' || !/^\d+(\.\d{1,9})?$/.test(value)) throw new Error('Enter a price with at most nine decimal places.');
 const [whole, decimal='']=value.split('.'); const n=BigInt(whole)*1000000000n+BigInt(decimal.padEnd(9,'0'));
 if(n<1n||n>10000000000n) throw new Error('Devnet demo prices must be above zero and at most 10 SOL.');
 return Number(n);
}
export function mergeTransaction(expected, incoming, wallet) {
 const original=Transaction.from(Buffer.from(expected,'base64'));
 const candidate=Transaction.from(Buffer.from(incoming,'base64'));
 if(!original.serializeMessage().equals(candidate.serializeMessage())) throw new Error('Transaction changed. Both wallets must sign the exact prepared sale.');
 const entry=candidate.signatures.find(s=>s.publicKey.toBase58()===wallet);
 if(!entry?.signature || !nacl.sign.detached.verify(candidate.serializeMessage(),entry.signature,new PublicKey(wallet).toBytes())) throw new Error('Wallet signature is missing or invalid.');
 original.addSignature(new PublicKey(wallet),entry.signature);
 return original;
}
