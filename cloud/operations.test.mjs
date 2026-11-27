import test from 'node:test';
import assert from 'node:assert/strict';
import {CloudStore} from './store.mjs';
import {CLOUD_TOOLS,invokeCloudTool} from './tools.mjs';
import {executeCanonicalTransition} from './canonical.mjs';

const decode=result=>JSON.parse(result.content[0].text);
function fixture(t) {
  const store=new CloudStore(':memory:');t.after(()=>store.close());
  const account=store.createAccount('operations@example.invalid','Operations fixture password');
  return {store,account:account.id,call:(name,args={})=>invokeCloudTool(store,account.id,name,args)};
}
test('Cloud exposes dependency read/write and recoverable delete without removing existing tools',()=>{
  assert.equal(CLOUD_TOOLS.length,26);
  const byName=new Map(CLOUD_TOOLS.map(t=>[t.name,t]));
  assert.equal(byName.get('list_dependencies')?.annotations.readOnlyHint,true);
  for(const name of ['add_dependency','remove_dependency','delete_task']){
    assert.equal(byName.get(name)?.writes,true);
    assert.equal(byName.get(name)?.inputSchema.properties.request_id.maxLength,128);
  }
  assert.equal(byName.get('delete_task').annotations.destructiveHint,true);
  assert.match(byName.get('delete_task').description,/Trash/);
});
test('A write request binds full arguments and tool, and replay returns its original response',t=>{
  const f=fixture(t),args={title:'Original',tags:['עברית'],request_id:'same-intent-0001'};
  const first=f.call('create_task',args),task=decode(first).task;
  f.call('update_task',{id:task.id,title:'Later change',tags:[]});
  assert.deepEqual(f.call('create_task',args),first);
  assert.throws(()=>f.call('create_task',{...args,title:'Changed'}),/idempotency_conflict/);
  assert.throws(()=>f.call('create_list',{name:'Other tool',request_id:args.request_id}),/idempotency_conflict/);
  assert.equal(f.store.list(f.account,'task').length,1);
  const other=f.store.createAccount('other-operations@example.invalid','Other operations fixture');
  const second=decode(invokeCloudTool(f.store,other.id,'create_task',args)).task;
  assert.notEqual(second.id,task.id);
});
test('An error after entity creation rolls back the entity, all related writes and the receipt',t=>{
  const f=fixture(t),original=f.store.writeEntity.bind(f.store);
  f.store.writeEntity=(...args)=>{if(args[1]==='task_tag')throw Error('Injected relationship failure');return original(...args);};
  assert.throws(()=>f.call('create_task',{title:'Atomic task',tags:['work'],request_id:'rollback-0001'}),/Injected/);
  for(const kind of ['task','tag','task_tag'])assert.equal(f.store.list(f.account,kind).length,0);
  assert.equal(f.store.get('SELECT count(*) AS n FROM receipts').n,0);
  assert.equal(f.store.get('SELECT count(*) AS n FROM audit').n,0);
});
test('Unknown legacy receipt payloads fail closed instead of accepting a mismatched intent',t=>{
  const f=fixture(t);
  f.store.run('INSERT INTO receipts(account_id,request_id,response,created) VALUES(?,?,?,?)',
    f.account,'legacy-0001',JSON.stringify({entity:{id:'existing'}}),Date.now());
  assert.throws(()=>f.call('create_task',{title:'Unprovable prior intent',request_id:'legacy-0001'}),/idempotency_reconciliation_required/);
  assert.equal(f.store.list(f.account,'task').length,0);
});
test('Canonical dependency receipts bind both endpoints and forward exact typed arguments',async t=>{
  const f=fixture(t),task=decode(f.call('create_task',{title:'Dependent'})).task;
  const prerequisite=decode(f.call('create_task',{title:'Prerequisite'})).task;
  let executions=0;
  const args={id:task.id,depends_on_id:prerequisite.id,request_id:'relation-0001'};
  const execute=async input=>{
    executions++;assert.deepEqual(input.arguments,{id:task.id,depends_on_id:prerequisite.id});
    return {envelopes:[],result:{task},changed:false};
  };
  const first=await executeCanonicalTransition(f.store,f.account,'add_dependency',args,{execute});
  assert.deepEqual(await executeCanonicalTransition(f.store,f.account,'add_dependency',args,{execute}),first);
  await assert.rejects(executeCanonicalTransition(f.store,f.account,'add_dependency',{...args,depends_on_id:task.id},{execute}),/idempotency_conflict/);
  assert.equal(executions,1);
});
test('Canonical dependency tombstones retain their historical payload version and reject future snapshots',async t=>{
  const f=fixture(t),task=decode(f.call('create_task',{title:'Dependent'})).task;
  const prerequisite=decode(f.call('create_task',{title:'Prerequisite'})).task;
  const id=task.id+':'+prerequisite.id;
  f.store.writeEntity(f.account,'task_dependency',id,{task_id:task.id,depends_on_task_id:prerequisite.id,created_at:'2026-11-27T00:00:00.000Z'});
  const source=f.store.wire(f.store.get('SELECT * FROM entities WHERE account_id=? AND entity_type=? AND entity_id=?',f.account,'task_dependency',id));
  const deletionVersion='1999999999998_0000_abcdabcdabcdabcd';
  const tombstone={...source,operation:'delete',version:deletionVersion};
  const args={id:task.id,depends_on_id:prerequisite.id,request_id:'canonical-delete-snapshot'};
  await assert.rejects(executeCanonicalTransition(f.store,f.account,'remove_dependency',args,{execute:async()=>({
    envelopes:[{...tombstone,payload:JSON.stringify({...JSON.parse(source.payload),version:'1999999999999_0000_abcdabcdabcdabcd'})}],result:{task},changed:true
  })}),/invalid_canonical_envelope/);
  assert.ok(f.store.entity(f.account,'task_dependency',id));
  await executeCanonicalTransition(f.store,f.account,'remove_dependency',args,{execute:async()=>({envelopes:[tombstone],result:{task},changed:true})});
  assert.equal(f.store.entity(f.account,'task_dependency',id),null);
  const saved=f.store.changes(f.account,0).envelopes.at(-1);
  assert.equal(saved.version,deletionVersion);
  assert.equal(saved.payload,source.payload);
});
test('Archived tasks stay readable by ID and are excluded from ordinary task views',t=>{
  const f=fixture(t),task=decode(f.call('create_task',{title:'Recoverable trash'})).task;
  f.store.writeEntity(f.account,'task',task.id,{...task,archived_at:'2026-11-27T00:00:00Z'});
  assert.equal(decode(f.call('list_tasks')).tasks.length,0);
  assert.equal(decode(f.call('search_tasks',{query:'Recoverable'})).tasks.length,0);
  assert.equal(decode(f.call('get_summary')).totalMatching,0);
  assert.equal(decode(f.call('get_task',{id:task.id})).task.archived_at,'2026-11-27T00:00:00Z');
});
test('Sync request IDs reject changed batches without mutating either account',t=>{
  const f=fixture(t),task=decode(f.call('create_task',{title:'Sync source'})).task;
  const envelope=f.store.changes(f.account,0).envelopes[0];
  const first=f.store.push(f.account,[envelope],'push-request-0001');
  assert.deepEqual(f.store.push(f.account,[envelope],'push-request-0001'),first);
  const changed={...envelope,payload:JSON.stringify({...JSON.parse(envelope.payload),title:'Changed'})};
  assert.throws(()=>f.store.push(f.account,[changed],'push-request-0001'),/idempotency_conflict/);
  assert.throws(()=>f.call('update_task',{id:task.id,title:'Changed',request_id:'push-request-0001'}),/idempotency_conflict/);
  assert.equal(f.store.entity(f.account,'task',task.id).title,'Sync source');
});
test('A legacy committed outbox receipt is safely upgraded using its immutable change sequence',t=>{
  const f=fixture(t),task=decode(f.call('create_task',{title:'Before old upload'})).task;
  const source=f.store.changes(f.account,0).envelopes[0];
  const version='1999999999999_0000_abcdabcdabcdabcd';
  const envelope={...source,version,payload:JSON.stringify({...JSON.parse(source.payload),title:'Old committed upload',content_version:version,version})};
  const response=f.store.push(f.account,[envelope],'legacy-upload-0001');
  assert.equal(response.results[0].status,'accepted');
  f.store.run('UPDATE receipts SET response=? WHERE account_id=? AND request_id=?',JSON.stringify(response),f.account,'legacy-upload-0001');
  const before=f.store.changes(f.account,0).cursor;
  assert.deepEqual(f.store.push(f.account,[envelope],'legacy-upload-0001'),response);
  assert.equal(f.store.changes(f.account,0).cursor,before);
  assert.equal(f.store.entity(f.account,'task',task.id).title,'Old committed upload');
  assert.throws(()=>f.store.push(f.account,[{...envelope,payload:source.payload}],'legacy-upload-0001'),/idempotency_conflict/);
});
test('Unverifiable legacy sync receipts request reconciliation without applying any input',t=>{
  const f=fixture(t);f.call('create_task',{title:'Existing'});
  const envelope=f.store.changes(f.account,0).envelopes[0];
  f.store.run('INSERT INTO receipts(account_id,request_id,response,created) VALUES(?,?,?,?)',f.account,
    'legacy-duplicate-0001',JSON.stringify({results:[{status:'duplicate'}]}),Date.now());
  const before=f.store.changes(f.account,0).cursor;
  assert.throws(()=>f.store.push(f.account,[envelope],'legacy-duplicate-0001'),/idempotency_reconciliation_required/);
  assert.equal(f.store.changes(f.account,0).cursor,before);
});
