import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,chmodSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {CloudStore} from './store.mjs';
import {invokeCloudTool} from './tools.mjs';
import {executeCanonicalTransition,runCanonicalProcess} from './canonical.mjs';

const decode=r=>JSON.parse(r.content[0].text);
async function fixture(fn){
 const store=new CloudStore(':memory:');
 try{
   const account=store.createAccount('canonical@example.com','Canonical fixture password');
   const task=decode(invokeCloudTool(store,account.id,'create_task',{title:'Original'})).task;
   await fn(store,account.id,task);
 }finally{store.close();}
}
// Mock workflow output exercises the process/transaction boundary only. Actual
// recurrence semantics are tested by cloud/native using the original Swift Core.
function response(input){
 const row=input.envelopes.find(e=>e.entity_type==='task'&&e.entity_id===input.arguments.id);
 const physical=Math.max(...input.envelopes.map(e=>Number(e.version.slice(0,13))))+1;
 const version=String(physical)+'_0000_fffffffffffffffd';
 const task={...JSON.parse(row.payload),status:'completed',completed_at:input.now,lifecycle_version:version,version};
 return {envelopes:[{...row,version,payload:JSON.stringify(task),device_id:input.device_id}],result:{task},changed:true};
}

test('canonical adapter retries concurrent account writes and isolates snapshots and receipts',()=>fixture(async(s,a,t)=>{
 const other=s.createAccount('other@example.com','Another fixture password');
 invokeCloudTool(s,other.id,'create_task',{title:'Private other account'});
 s.run('UPDATE accounts SET timezone=? WHERE id=?','Asia/Hebron',a);
 let calls=0;
 const execute=async input=>{
   calls++;assert.equal(input.timezone,'Asia/Hebron');assert.equal(input.envelopes.length,1);
   assert.equal(input.envelopes[0].entity_id,t.id);
   if(calls===1)invokeCloudTool(s,a,'update_task',{id:t.id,title:'Concurrent server title'});
   return response(input);
 };
 const args={id:t.id,request_id:'canonical-retry-0001'};
 const result=await executeCanonicalTransition(s,a,'complete_task',args,{execute});
 assert.equal(calls,2);assert.equal(result.title,'Concurrent server title');assert.equal(result.status,'completed');
 const replay=await executeCanonicalTransition(s,a,'complete_task',args,{execute:()=>{throw Error('must not run');}});
 assert.deepEqual(replay,result);
 await assert.rejects(executeCanonicalTransition(s,a,'reopen_task',args,{execute}),/idempotency_conflict/);
 assert.equal(s.list(other.id,'task')[0].status,'open');
}));

test('canonical adapter rolls back every emitted entity if any winner is stale',()=>fixture(async(s,a,t)=>{
 const before=s.changes(a,0).cursor;
 await assert.rejects(executeCanonicalTransition(s,a,'complete_task',{id:t.id,request_id:'atomic-failure-0001'},{execute:async input=>{
   const out=response(input),source=input.envelopes[0];
   const id='00000000-0000-4000-8000-000000000099';
   out.envelopes.unshift({...out.envelopes[0],entity_id:id,payload:JSON.stringify({...JSON.parse(out.envelopes[0].payload),id})});
   out.envelopes[1]={...source,payload:JSON.stringify({...JSON.parse(source.payload),title:'Same-HLC conflicting payload'})};
   return out;
 }}),/canonical_result_stale/);
 assert.equal(s.list(a,'task').length,1);assert.equal(s.entity(a,'task',t.id).status,'open');
 assert.equal(s.changes(a,before).envelopes.length,0);
 assert.equal(s.get('SELECT count(*) AS n FROM receipts WHERE account_id=?',a).n,0);
}));

test('canonical adapter bounds contention without dropping a concurrent mutation',()=>fixture(async(s,a,t)=>{
 let calls=0;
 await assert.rejects(executeCanonicalTransition(s,a,'complete_task',{id:t.id},{execute:async input=>{
   invokeCloudTool(s,a,'update_task',{id:t.id,title:'Concurrent '+(++calls)});
   return response(input);
 }}),/canonical_snapshot_changed_retry/);
 assert.equal(calls,3);assert.equal(s.entity(a,'task',t.id).title,'Concurrent 3');
 assert.equal(s.entity(a,'task',t.id).status,'open');
}));

test('canonical process boundary enforces timeout and output cap',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'lorvex-canonical-'));
 try{
   const executable=join(dir,'helper');
   writeFileSync(executable,'#!/usr/bin/env node\nsetInterval(()=>{},1000);\n');chmodSync(executable,0o700);
   await assert.rejects(runCanonicalProcess({timezone:'UTC'},{executable,timeoutMs:100}),/canonical_transition_timeout/);
   writeFileSync(executable,'#!/usr/bin/env node\nprocess.stdout.write("x".repeat(2048));\n');
   await assert.rejects(runCanonicalProcess({timezone:'UTC'},{executable,maxBytes:1024}),/canonical_output_too_large/);
   assert.throws(()=>runCanonicalProcess({value:'x'.repeat(2048)},{executable,maxBytes:1024}),/canonical_snapshot_too_large/);
 }finally{rmSync(dir,{recursive:true,force:true});}
});

test('configured canonical helper owns ordinary task lifecycle actions',()=>fixture(async(s,a,t)=>{
 const dir=mkdtempSync(join(tmpdir(),'lorvex-canonical-route-'));
 const configured=process.env.LORVEX_CANONICAL_CORE_EXECUTABLE;
 try{
   const executable=join(dir,'helper');
   const body='#!/usr/bin/env node\nconst response='+response.toString()+';\n'+
     'let data="";process.stdin.on("data",b=>data+=b);process.stdin.on("end",()=>{const out=response(JSON.parse(data));out.envelopes[0].device_id="canonical-route-test";process.stdout.write(JSON.stringify(out));});\n';
   writeFileSync(executable,body);chmodSync(executable,0o700);
   process.env.LORVEX_CANONICAL_CORE_EXECUTABLE=executable;
   const task=decode(await invokeCloudTool(s,a,'complete_task',{id:t.id,request_id:'ordinary-route-0001'})).task;
   assert.equal(task.status,'completed');
   assert.equal(s.get('SELECT device_id FROM entities WHERE account_id=? AND entity_type=? AND entity_id=?',a,'task',t.id).device_id,'canonical-route-test');
 }finally{
   if(configured===undefined)delete process.env.LORVEX_CANONICAL_CORE_EXECUTABLE;
   else process.env.LORVEX_CANONICAL_CORE_EXECUTABLE=configured;
   rmSync(dir,{recursive:true,force:true});
 }
}));

test('canonical schema3 output is preserved and unknown native schema is rejected',()=>fixture(async(s,a,t)=>{
 const task=await executeCanonicalTransition(s,a,'complete_task',{id:t.id},{execute:async input=>{
   const out=response(input);out.envelopes[0].payload_schema_version=3;return out;
 }});
 assert.equal(task.status,'completed');
 const row=s.get('SELECT payload_schema_version,version FROM entities WHERE account_id=? AND entity_type=? AND entity_id=?',a,'task',t.id);
 assert.equal(row.payload_schema_version,3);
 await assert.rejects(executeCanonicalTransition(s,a,'complete_task',{id:t.id},{execute:async input=>{
   const out=response(input);out.envelopes[0].payload_schema_version=5;return out;
 }}),/invalid_canonical_envelope/);
 assert.equal(s.entity(a,'task',t.id).version,row.version);
}));
