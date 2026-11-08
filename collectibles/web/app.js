import { Transaction } from '@solana/web3.js';
import { Buffer } from 'buffer';
window.Buffer=Buffer;
const $=id=>document.getElementById(id);
const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let token=sessionStorage.getItem('ss.devnet.session')||'', provider, state, busy=false;
async function api(path,body){const r=await fetch(`/v1/collectibles/${path}`,{method:body?'POST':'GET',headers:{'content-type':'application/json',...(token?{'x-collectible-session':token}:{})},...(body?{body:JSON.stringify(body)}:{})});const j=await r.json();if(!r.ok)throw new Error(j.message||'Request failed.');return j;}
function notice(message){$('notice').textContent=message;}
async function act(fn){if(busy)return;busy=true;document.querySelectorAll('button').forEach(b=>b.disabled=true);try{await fn();await load();}catch(e){notice(e.message);}finally{busy=false;document.querySelectorAll('button').forEach(b=>b.disabled=false);}}
function button(label,fn,primary=false){const b=document.createElement('button');b.textContent=label;b.className=primary?'primary':'';b.onclick=()=>act(fn);return b;}
async function connect(kind){
 provider=kind==='phantom'?window.phantom?.solana:window.solflare;
 if(!provider)throw new Error(`Open this page in ${kind==='phantom'?'Phantom':'Solflare'}’s browser or install its browser extension. Set the wallet network to devnet.`);
 const {publicKey}=await provider.connect();const address=publicKey.toString();
 if(state?.wallet&&state.wallet!==address)throw new Error('This account is linked to another wallet. Switch to that wallet before continuing.');
 const {message}=await api('wallet/challenge',{address});const signature=await provider.signMessage(new TextEncoder().encode(message),'utf8');
 await api('wallet/verify',{signature:Buffer.from(signature.signature??signature).toString('base64')});notice('Wallet verified. Test SOL only.');
}
async function sign(id){
 if(!provider)throw new Error('Connect the linked wallet in this browser first.');
 if(provider.publicKey.toString()!==state.wallet)throw new Error('Switch back to the wallet linked to this account.');
 const prepared=await api('transaction',{id});notice(prepared.summary);
 const tx=Transaction.from(Buffer.from(prepared.transaction,'base64'));const signed=await provider.signTransaction(tx);
 const r=await api('sign',{id,transaction:Buffer.from(signed.serialize({requireAllSignatures:false})).toString('base64')});
 notice(r.status==='submitted'?'Both signatures collected. Waiting for chain confirmation.':'Signature saved. The other fan can now approve the same transaction.');
}
async function load(){
 state=await api('dashboard');$('wallet').replaceChildren();
 const text=document.createElement('p');text.textContent=state.wallet?`Linked devnet wallet · ${state.wallet}`:'Connect a devnet wallet to claim or collect.';$('wallet').append(text,button('Connect Phantom',()=>connect('phantom')),document.createTextNode('　'),button('Connect Solflare',()=>connect('solflare')));
 $('progress').replaceChildren();
 if(!state.cards.length)$('progress').textContent='Your first correct free prediction starts an athlete’s record. The hackathon setup guide includes a clearly labeled 399-call demo account.';
 for(const p of state.cards){const el=document.createElement('div');el.className='item';el.innerHTML=`<div class="row"><strong>${esc(p.full_name)}</strong><span>${p.qualifying_calls} / 400 free correct calls</span></div><progress max="400" value="${Math.min(400,p.qualifying_calls)}"></progress><small>${p.mastery_calls} total mastery calls · ${p.collectible_demo?'Fictional demo athlete':'Tradable claims are limited to fictional demo athletes in this prototype'}</small>`;
  const existing=state.collectibles.find(c=>String(c.player_id)===String(p.player_id)&&c.is_earner);
  if(state.demo_controls && p.collectible_demo && p.qualifying_calls===399)el.append(button('DEMO · Settle final fictional pick',async()=>{const r=await api('demo/settle',{});notice(r.message);}));
  if(p.qualifying_calls>=400&&p.collectible_demo&&(!existing||!existing.minted_at))el.append(button(existing?'Resume same claim':'Claim devnet Diamond',async()=>{notice('Minting your numbered edition…');const r=await api('claim',{playerId:p.player_id});notice(`Mint confirmed. ${r.transaction_url}`);},true));
  else if(existing?.minted_at){const s=document.createElement('p');s.textContent='Edition already issued. This athlete’s mastery stays with you after a sale.';el.append(s);}$('progress').append(el);
 }
 $('cards').replaceChildren();
 if(!state.collectibles.length)$('cards').textContent='The first earned edition will appear here.';
 for(const c of state.collectibles){const el=document.createElement('article');el.className='edition';el.innerHTML=`<img src="/v1/collectibles/public/${encodeURIComponent(c.id)}/image" alt="Fictional Sports Swipe Diamond jersey"><h3>${esc(c.athlete_name)}</h3><p>Diamond #${c.edition} · Earned ${c.season}</p><p>Original earner · ${esc(c.earner_name)}</p><p>Current owner · ${esc(c.owner_name??(c.owner?'External wallet':'Mint pending'))}</p><code>${esc(c.owner??'Not yet minted')}</code><p>${c.earned_calls} qualifying free calls at claim</p>${c.asset_url?`<p><a href="${esc(c.asset_url)}" target="_blank" rel="noopener">Verify asset on devnet ↗</a></p>`:''}`;
  const live=state.sales.find(s=>s.collectible_id===c.id&&['listed','signing','submitted'].includes(s.status));
  if(c.is_owner&&!live){const f=document.createElement('form');f.innerHTML='<label>Devnet SOL <input name="price" value="0.1" inputmode="decimal" aria-label="Asking price in devnet SOL" required></label>';const b=document.createElement('button');b.type='submit';b.textContent='List edition';f.append(b);f.onsubmit=e=>{e.preventDefault();act(async()=>{await api('list',{id:c.id,price:f.elements.price.value});notice('Listed. A buyer must still agree to your asking price.');});};el.append(f);}
  $('cards').append(el);
 }
 $('sales').replaceChildren();
 for(const s of state.sales){const c=state.collectibles.find(c=>c.id===s.collectible_id);const el=document.createElement('div');el.className='item';el.innerHTML=`<strong>${esc(c?.athlete_name??'Diamond')} #${c?.edition??''}</strong><p>${Number(s.lamports)/1e9} devnet SOL · ${esc(s.status)}</p><small>Seller ${esc(s.seller_wallet)}${s.buyer_wallet?` → Buyer ${esc(s.buyer_wallet)}`:''}</small>`;
  if(s.status==='listed'){if(s.is_seller)el.append(button('Cancel listing',()=>api('cancel',{id:s.id})));else el.append(button('Agree to price & prepare sale',async()=>{await api('offer',{id:s.id});notice('Sale prepared. Buyer and seller must sign before the blockhash expires.');}));}
  if(s.status==='signing'&&(s.is_buyer||s.is_seller))el.append(button('Review & sign atomic sale',()=>sign(s.id),true));
  if(s.status==='submitted'&&(s.is_buyer||s.is_seller))el.append(button('Retry same signed transaction',()=>api('retry',{id:s.id})));
  if(s.transaction_url){const a=document.createElement('a');a.href=s.transaction_url;a.target='_blank';a.rel='noopener';a.textContent=' Verify devnet transaction ↗';el.append(a);}$('sales').append(el);
 }
}
$('refresh').onclick=()=>act(load);
try{
 const ticket=location.hash.slice(1);if(ticket){history.replaceState(null,'',location.pathname);const r=await api('session',{ticket});token=r.token;sessionStorage.setItem('ss.devnet.session',token);}
 await load();notice('Solana devnet. Test SOL has no real monetary value. Connect both fans in separate browser profiles.');
}catch(e){notice(e.message);}
setInterval(()=>{if(!busy&&!document.hidden)load().catch(e=>notice(e.message));},10000);
