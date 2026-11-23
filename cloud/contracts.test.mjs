import {test} from 'node:test';
import assert from 'node:assert/strict';
import {CloudStore} from './store.mjs';
import {invokeCloudTool} from './tools.mjs';
import {payloadContract,taskGroups} from './payload.mjs';
import {execFileSync} from 'node:child_process';

const decode=r=>JSON.parse(r.content[0].text);
function fixture(fn){const store=new CloudStore(':memory:');try{const account=store.createAccount('contract@example.com','Contract test password 2026');return fn(store,account.id);}finally{store.close();}}
function contractCheck(envelope){
 const payload=JSON.parse(envelope.payload),spec=payloadContract.entities[envelope.entity_type];
 assert.ok(spec,envelope.entity_type);
 const shape=envelope.operation==='delete'?spec.operations.delete.shapes[0]:spec.operations.upsert;
 for(const key of shape.required_keys)assert.ok(key in payload,envelope.entity_type+'.'+key);
 for(const key of Object.keys(payload))assert.ok(key in spec.fields,envelope.entity_type+'.'+key);
 assert.equal(payload.version,envelope.version);
 if(envelope.operation==='upsert')for(const [k,v] of Object.entries(payload)){
   const f=spec.fields[k];
   if(v!==null&&f.format==='civil-date')assert.match(v,/^\d{4}-\d{2}-\d{2}$/);
   if(v!==null&&f.format==='hlc')assert.match(v,/^\d{13}_\d{4}_[0-9a-f]{16}$/);
   if(v!==null&&f.format==='uuid')assert.match(v,/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
 }
}

test('cloud-created task/list/event/completion use exact canonical native schema',()=>fixture((s,a)=>{
 const call=(name,args)=>decode(invokeCloudTool(s,a,name,args));
 const list=call('create_list',{name:'Cloud list'}).list;
 assert.equal(call('list_lists',{}).lists[0].id,list.id);
 const task=call('create_task',{title:'Hebrew \u05de\u05e9\u05d9\u05de\u05d4',list_id:list.id,due_date:'2026-12-01',tags:['work','urgent']}).task;
 assert.deepEqual(task.tags.sort(),['urgent','work']);
 call('create_event',{title:'Meeting',start_date:'2026-12-01',start_time:'09:00',end_time:'10:00'});
 const h='00000000-0000-4000-8000-000000000001';
 s.writeEntity(a,'habit',h,{id:h,name:'Read',archived:false,frequency_type:'daily',weekdays:[],position:0,target_count:1,per_period_target:1,created_at:new Date().toISOString()});
 call('complete_habit',{id:h,date:'2026-12-01'});
 assert.equal(call('list_habits',{date:'2026-12-01'}).habits[0].completed,true);
 call('uncomplete_habit',{id:h,date:'2026-12-01'});
 assert.equal(call('list_habits',{date:'2026-12-01'}).habits[0].completed,false);
 for(const e of s.changes(a,0,200).envelopes)contractCheck(e);
}));

test('server field clocks follow native TaskRegisterDescriptor and preserve unrelated groups',()=>fixture((s,a)=>{
 const source=execFileSync('git',['show','HEAD:apps/apple/core/Sources/LorvexSync/TaskRegisterDescriptor.swift'],{cwd:new URL('..',import.meta.url),encoding:'utf8'});
 for(const [clock,keys] of Object.entries(taskGroups)){
   const name=clock.replace('_version','Fields');
   const body=source.match(new RegExp('static let '+name+' = \\[([\\s\\S]*?)\\]'))[1];
   assert.deepEqual(keys,[...body.matchAll(/"([^"]+)"/g)].map(m=>m[1]));
 }
 const task=decode(invokeCloudTool(s,a,'create_task',{title:'Original'})).task;
 const planned=decode(invokeCloudTool(s,a,'plan_task',{id:task.id,date:'2026-12-01'})).task;
 assert.equal(planned.content_version,task.content_version);
 assert.equal(planned.lifecycle_version,task.lifecycle_version);
 assert.notEqual(planned.schedule_version,task.schedule_version);
 const done=decode(invokeCloudTool(s,a,'complete_task',{id:task.id})).task;
 assert.equal(done.schedule_version,planned.schedule_version);
 assert.notEqual(done.lifecycle_version,planned.lifecycle_version);
}));

test('same-HLC conflicting snapshots are returned for canonical client reconciliation',()=>fixture((s,a)=>{
 const id='00000000-0000-4000-8000-000000000002',version='1795000000000_0001_abcdabcdabcdabcd';
 const wire={entity_type:'task',entity_id:id,operation:'upsert',version,payload_schema_version:4,device_id:'ipad-test',payload:JSON.stringify({id,title:'First',version})};
 assert.equal(s.receive(a,wire).status,'accepted');
 assert.equal(s.receive(a,wire).status,'duplicate');
 for(const title of ['AAA','ZZZ']){
   const result=s.receive(a,{...wire,payload:JSON.stringify({id,title,version})});
   assert.equal(result.status,'stale');assert.equal(JSON.parse(result.winner.payload).title,'First');
 }
 assert.equal(s.changes(a,0).envelopes.length,1);
}));

test('task tags are canonical edges, idempotent and removable without deleting tags',()=>fixture((s,a)=>{
 const args={title:'Tagged',tags:['work'],request_id:'contract-task-id-0001'};
 const task=decode(invokeCloudTool(s,a,'create_task',args)).task;
 const replay=decode(invokeCloudTool(s,a,'create_task',args)).task;
 assert.equal(task.id,replay.id);assert.equal(s.list(a,'task').length,1);assert.equal(s.list(a,'tag').length,1);assert.equal(s.list(a,'task_tag').length,1);
 invokeCloudTool(s,a,'update_task',{id:task.id,tags:[]});
 assert.equal(s.list(a,'task_tag').length,0);assert.equal(s.list(a,'tag').length,1);
 assert.deepEqual(decode(invokeCloudTool(s,a,'get_task',{id:task.id})).task.tags,[]);
 for(const e of s.changes(a,0,200).envelopes)contractCheck(e);
}));

test('invalid native dates and ranges are rejected before any data mutation',()=>fixture((s,a)=>{
 for(const args of [{title:'x',due_date:'2026-02-30'},{title:'x',due_date:'2026-12-01T10:00:00Z'},{title:'x',estimated_minutes:1441},{title:'  '}])assert.throws(()=>invokeCloudTool(s,a,'create_task',args));
 assert.throws(()=>invokeCloudTool(s,a,'create_event',{title:'x',start_date:'2026-12-01',start_time:'25:00'}));
 assert.equal(s.changes(a,0).envelopes.length,0);
}));

test('conditional outbox protects newer server groups even when the offline HLC is greater',()=>fixture((s,a)=>{
 const task=decode(invokeCloudTool(s,a,'create_task',{title:'First'})).task;
 const base=s.changes(a,0).envelopes[0],key='task:'+task.id;
 const changed=decode(invokeCloudTool(s,a,'update_task',{id:task.id,title:'Server title'})).task;
 const current=s.changes(a,1).envelopes[0];
 const version='1999999999999_0000_abcdabcdabcdabcd';
 const offline={...base,version,payload:JSON.stringify({...JSON.parse(base.payload),planned_date:'2026-12-01',schedule_version:version,version})};
 const blocked=s.push(a,[offline],'cas-offline-request-0001',{[key]:base.version});
 assert.equal(blocked.results[0].status,'stale');assert.equal(blocked.results[0].winner.version,current.version);
 assert.equal(s.entity(a,'task',task.id).title,'Server title');
 const merged={...offline,payload:JSON.stringify({...JSON.parse(current.payload),planned_date:'2026-12-01',schedule_version:version,version})};
 const accepted=s.push(a,[merged],'cas-merged-request-0002',{[key]:current.version});
 assert.equal(accepted.results[0].status,'accepted');
 assert.equal(s.entity(a,'task',task.id).title,'Server title');
 assert.equal(s.entity(a,'task',task.id).planned_date,'2026-12-01');
 const replay=s.push(a,[merged],'cas-replay-request-0003',{[key]:current.version});
 assert.equal(replay.results[0].status,'duplicate');
}));

test('task updates reject date-times without poisoning native change pages',()=>fixture((s,a)=>{
 const task=decode(invokeCloudTool(s,a,'create_task',{title:'Native dates'})).task;
 const cursor=s.changes(a,0).cursor;
 for(const field of ['due_date','planned_date']){
   assert.throws(()=>invokeCloudTool(s,a,'update_task',{id:task.id,[field]:'2026-12-01T10:30:00Z'}));
   assert.throws(()=>invokeCloudTool(s,a,'update_task',{id:task.id,[field]:'2026-02-30'}));
 }
 assert.equal(s.changes(a,cursor).envelopes.length,0);
 invokeCloudTool(s,a,'update_task',{id:task.id,due_date:'2026-12-01',planned_date:'2026-11-30'});
 for(const e of s.changes(a,cursor).envelopes)contractCheck(e);
}));
