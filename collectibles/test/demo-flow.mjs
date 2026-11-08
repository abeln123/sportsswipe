// Run after local seeding. Checks real DB eligibility and ownership boundaries, no mainnet.
import assert from 'node:assert/strict';
import pg from 'pg';
import{readFileSync}from'node:fs';
import {eligibleSql} from '../src/policy.mjs';
const pool=new pg.Pool({connectionString:process.env.DATABASE_URL});
const fixture=JSON.parse(readFileSync(process.env.DIAMOND_FIXTURE_FILE,'utf8').split('\nSeeded')[0]);
const earner=(await pool.query('SELECT id FROM users WHERE email=$1',[fixture.earnerEmail])).rows[0].id;
const count=async()=>Number((await pool.query(eligibleSql,[earner])).rows.find(r=>String(r.player_id)===String(fixture.playerId))?.earned_calls??0);
const stage=process.argv[2];
if(stage==='before')assert.equal(await count(),399);else assert.equal(await count(),400);
await pool.query('BEGIN');
// A purchased cosmetic cannot create a qualifying mastery event.
const before=await count();
await pool.query("INSERT INTO cosmetic_purchases(user_id,command_id,finish,price) VALUES ($1,gen_random_uuid(),'diamond',31250)",[earner]);
assert.equal(await count(),before);
const record=(await pool.query('SELECT correct_count FROM mastery_totals WHERE user_id=$1 AND player_id=$2',[earner,fixture.playerId])).rows[0];
assert.equal(Number(record.correct_count),stage==='before'?399:400);
await pool.query('ROLLBACK');
console.log(`PASS ${stage}: ${await count()} qualifying calls; cosmetic purchase does not alter entitlement or mastery.`);
await pool.end();
