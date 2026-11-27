import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createHash,randomBytes} from 'node:crypto';
import {createCloudServer} from './server.mjs';

// Runs the real HTTP/OAuth/sync boundary and the packaged canonical Swift
// executable against an isolated SQLite database, with no native app involved.
const receiptPath=process.argv[2];
if(!receiptPath)throw Error('A new receipt path is required');
process.env.LORVEX_CANONICAL_CORE_EXECUTABLE??=path.resolve('cloud/native/dist/lorvex-cloud-native');
await fs.access(process.env.LORVEX_CANONICAL_CORE_EXECUTABLE);
const temporary=await fs.mkdtemp(path.join(os.tmpdir(),'lorvex-cloud-acceptance-'));
const issuer='https://lorvex-acceptance.invalid/cloud';
const accounts=[],grants=[];
const proof={passed:false,mode:'isolated-http-real-canonical-helper',checks:{},cleanup:[],started:new Date().toISOString()};
let app,base;
const start=async()=>{
  app=createCloudServer({dbFile:path.join(temporary,'cloud.sqlite'),publicOrigin:issuer});
  await new Promise(resolve=>app.server.listen(0,'127.0.0.1',resolve));
  base='http://127.0.0.1:'+app.server.address().port+'/cloud';
};
const request=async(route,body,token,{form=false,method}={})=>{
  const response=await fetch(base+route,{method:method??(body===undefined?'GET':'POST'),redirect:'manual',
    headers:{'content-type':form?'application/x-www-form-urlencoded':'application/json',
      ...(token?{authorization:'Bearer '+token}:{})},
    body:body===undefined?undefined:form?new URLSearchParams(body):JSON.stringify(body)});
  const raw=await response.text();let value;
  try{value=JSON.parse(raw);}catch{value=raw;}
  return {status:response.status,headers:response.headers,value};
};
const call=async(token,name,args={})=>{
  proof.last_tool=name;
  const response=await request('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},token);
  assert.equal(response.status,200,'MCP transport status');return response.value.result;
};
const value=result=>{assert.equal(result.isError,false,'MCP rejected: '+result.content?.[0]?.text);return JSON.parse(result.content[0].text);};
const challenge=value=>createHash('sha256').update(value).digest('base64url');
const grant=async(account,scope='lorvex.read lorvex.write offline_access')=>{
  const redirect='https://chatgpt.com/connector_platform_oauth_redirect';
  const registered=await request('/oauth/register',{redirect_uris:[redirect],client_name:'Lorvex synthetic cloud acceptance'});
  assert.equal(registered.status,201,'DCR registration');
  const client=registered.value.client_id,verifier=randomBytes(36).toString('base64url');
  const state=randomBytes(20).toString('base64url');
  const authorization=await request('/oauth/authorize?'+new URLSearchParams({client_id:client,redirect_uri:redirect,
    response_type:'code',code_challenge:challenge(verifier),code_challenge_method:'S256',scope,state,resource:issuer+'/mcp',ui_locales:'he'}));
  assert.equal(authorization.status,200,'OAuth consent page');
  assert.match(authorization.value,/dir="rtl"/,'Hebrew OAuth');
  const id=authorization.value.match(/name="request" value="([^"]+)"/)[1];
  const login=await request('/oauth/approve',{request:id,mode:'login',email:account.email,password:account.password},null,{form:true});
  assert.equal(login.status,302,'Normal account sign-in');
  const callback=new URL(login.headers.get('location'));
  assert.equal(callback.searchParams.get('state'),state,'OAuth state');
  assert.equal(callback.searchParams.get('iss'),issuer,'Issuer binding');
  const fields={grant_type:'authorization_code',client_id:client,redirect_uri:redirect,
    code:callback.searchParams.get('code'),code_verifier:verifier,resource:issuer+'/mcp'};
  assert.equal((await request('/oauth/token',{...fields,code_verifier:'x'.repeat(48)},null,{form:true})).status,400,'PKCE mismatch rejected');
  const token=await request('/oauth/token',fields,null,{form:true});
  assert.equal(token.status,200,'PKCE token grant');
  assert.equal((await request('/oauth/token',fields,null,{form:true})).status,400,'Authorization code single-use');
  const result={...token.value,client_id:client};grants.push(result);return result;
};
try{
  await start();
  for(let i=0;i<2;i++){
    const email='lorvex-cloud-acceptance-'+randomBytes(10).toString('hex')+'@example.invalid';
    const password=randomBytes(28).toString('base64url')+'Az2!';
    const created=await request('/v1/auth/register',{email,password});
    assert.equal(created.status,201,'Synthetic signup');
    accounts.push({email,password,id:created.value.user.id,access_token:created.value.access_token});
  }
  const a=await grant(accounts[0]),b=await grant(accounts[1]);
  const token=a.access_token;
  const listed=await request('/mcp',{jsonrpc:'2.0',id:2,method:'tools/list'},token);
  assert.equal(listed.value.result.tools.length,26,'Cloud catalog');
  for(const tool of listed.value.result.tools){
    assert.equal(typeof tool.annotations.readOnlyHint,'boolean');
    assert.ok(tool.securitySchemes[0].scopes.includes('lorvex.read'));
  }
  proof.checks.oauth_dcr_pkce_scopes_catalog=true;
  const title='בדיקת ענן ללא מכשיר '+randomBytes(4).toString('hex');
  const args={title,due_date:'2026-12-03',tags:['עברית','Café'],request_id:'acceptance-create'};
  const results=await Promise.all([call(token,'create_task',args),call(token,'create_task',args)]);
  assert.deepEqual(results[0],results[1],'Concurrent create replay');
  const task=value(results[0]).task;
  assert.equal(value(await call(token,'list_tasks')).totalMatching,1,'No duplicate task');
  assert.match(JSON.stringify(await call(token,'create_task',{...args,title:'Changed'})),/idempotency_conflict/);
  const other=value(await call(b.access_token,'create_task',{title:'Other account',request_id:'acceptance-create'})).task;
  assert.notEqual(other.id,task.id,'Account-scoped receipt');
  assert.equal((await call(b.access_token,'get_task',{id:task.id})).isError,true,'Foreign task hidden');
  assert.equal(value(await call(b.access_token,'list_tasks')).totalMatching,1,'Account isolated list');
  proof.checks.concurrent_create_replay_account_isolation=true;
  value(await call(token,'update_task',{id:task.id,title:title+' מעודכן',due_date:'2026-12-04',planned_date:'2026-12-02',request_id:'acceptance-update'}));
  const updated=value(await call(token,'get_task',{id:task.id})).task;
  assert.equal(updated.due_date,'2026-12-04','Due date persisted');
  assert.equal(updated.planned_date,'2026-12-02','Planned date persisted');
  assert.equal(value(await call(token,'search_tasks',{query:title})).totalMatching,1,'Search readback');
  const prerequisite=value(await call(token,'create_task',{title:'תלות לבדיקה',request_id:'acceptance-prerequisite'})).task;
  const edgeArgs={id:task.id,depends_on_id:prerequisite.id,request_id:'acceptance-link'};
  const added=await Promise.all([call(token,'add_dependency',edgeArgs),call(token,'add_dependency',edgeArgs)]);
  assert.deepEqual(added[0],added[1],'Concurrent canonical replay');
  assert.deepEqual(value(added[0]).task.depends_on,[prerequisite.id]);
  assert.equal(value(await call(token,'list_dependencies',{id:task.id})).dependencies.length,1);
  assert.equal((await call(token,'add_dependency',{id:prerequisite.id,depends_on_id:task.id,request_id:'acceptance-cycle'})).isError,true,'Cycle rejected');
  assert.equal((await call(b.access_token,'add_dependency',{id:other.id,depends_on_id:task.id,request_id:'acceptance-foreign'})).isError,true,'Foreign prerequisite rejected');
  assert.match(JSON.stringify(await call(token,'add_dependency',{...edgeArgs,depends_on_id:task.id})),/idempotency_conflict/);
  value(await call(token,'remove_dependency',{id:task.id,depends_on_id:prerequisite.id,request_id:'acceptance-unlink'}));
  assert.deepEqual(value(await call(token,'get_task',{id:task.id})).task.depends_on,[]);
  value(await call(token,'complete_task',{id:task.id,request_id:'acceptance-complete'}));
  assert.equal(value(await call(token,'get_task',{id:task.id})).task.status,'completed');
  value(await call(token,'reopen_task',{id:task.id,request_id:'acceptance-reopen'}));
  assert.equal(value(await call(token,'get_task',{id:task.id})).task.status,'open');
  proof.checks.real_canonical_dependencies_dates_search_lifecycle=true;
  const changes=await request('/v1/sync/changes?cursor=0&limit=200',undefined,accounts[0].access_token);
  assert.equal(changes.status,200,'Historical sync pull');
  assert.ok(changes.value.envelopes.some(e=>e.entity_type==='task_dependency'&&e.operation==='delete'),'Canonical dependency tombstone reaches sync pull');
  const batch={envelopes:[changes.value.envelopes.find(e=>e.entity_type==='task'&&e.entity_id===task.id)],request_id:'acceptance-sync-replay'};
  const pushed=await request('/v1/sync/push',batch,accounts[0].access_token);
  assert.equal(pushed.status,200,'Sync upload');
  assert.deepEqual((await request('/v1/sync/push',batch,accounts[0].access_token)).value,pushed.value);
  assert.equal((await request('/v1/sync/push',{...batch,envelopes:[{...batch.envelopes[0],device_id:'different-synthetic-device'}]},accounts[0].access_token)).status,409,'Sync request fingerprint conflict');
  proof.checks.sync_tombstones_and_request_batch_binding=true;
  const readOnly=await grant(accounts[0],'lorvex.read offline_access');
  const denied=await call(readOnly.access_token,'create_task',{title:'Denied',request_id:'acceptance-create'});
  assert.match(denied._meta['mcp/www_authenticate'][0],/insufficient_scope/,'Scope enforced before replay');
  const refreshed=await request('/oauth/token',{grant_type:'refresh_token',client_id:a.client_id,refresh_token:a.refresh_token,resource:issuer+'/mcp'},null,{form:true});
  assert.equal(refreshed.status,200,'Token refresh');
  assert.equal((await request('/oauth/token',{grant_type:'refresh_token',client_id:a.client_id,refresh_token:a.refresh_token,resource:issuer+'/mcp'},null,{form:true})).status,400,'Refresh rotated once');
  Object.assign(a,refreshed.value);
  value(await call(a.access_token,'get_task',{id:task.id}));
  proof.checks.refresh_rotation_and_write_scopes=true;
  const deletion={id:task.id,request_id:'acceptance-delete'};
  const removed=value(await call(a.access_token,'delete_task',deletion));
  assert.ok(removed.task.archived_at,'Recoverable Trash marker');
  assert.ok(value(await call(a.access_token,'get_task',{id:task.id})).task.archived_at,'Archived task remains stored');
  assert.equal(value(await call(a.access_token,'list_tasks')).totalMatching,1,'Trash excluded from task list');
  app.server.closeAllConnections();await app.close();await start();
  assert.deepEqual(value(await call(a.access_token,'delete_task',deletion)),removed,'Delete receipt survived restart');
  assert.deepEqual(value(await call(a.access_token,'create_task',args)).task,task,'Create receipt survived restart');
  assert.equal(value(await call(a.access_token,'list_tasks')).totalMatching,1,'No recreate after restart');
  proof.checks.recoverable_delete_durable_replay_restart=true;
  assert.equal((await request('/oauth/revoke',{token:a.refresh_token,client_id:a.client_id},null,{form:true})).status,200);
  assert.match((await call(a.access_token,'get_task',{id:prerequisite.id}))._meta['mcp/www_authenticate'][0],/invalid_token/);
  proof.checks.revocation=true;
  proof.passed=true;
}catch(error){proof.failure={name:error.name,code:error.code??null,message:error.message};}
finally{
  for(const g of grants){
    try{await request('/oauth/revoke',{token:g.refresh_token,client_id:g.client_id},null,{form:true});}
    catch{}
  }
  if(app){app.server.closeAllConnections();await app.close();}
  await fs.rm(temporary,{recursive:true,force:true});
  proof.cleanup=[{isolated_database_removed:true,owned_accounts:accounts.length}];
  proof.finished=new Date().toISOString();proof.source_sha256={};
  for(const name of ['server.mjs','store.mjs','tools.mjs','canonical.mjs','request-fingerprint.mjs','task-result.mjs','live-acceptance.mjs'])
    proof.source_sha256[name]=createHash('sha256').update(await fs.readFile(new URL('./'+name,import.meta.url))).digest('hex');
  proof.canonical_binary_sha256=createHash('sha256').update(await fs.readFile(process.env.LORVEX_CANONICAL_CORE_EXECUTABLE)).digest('hex');
  await fs.writeFile(receiptPath,JSON.stringify(proof,null,2)+'\n',{flag:'wx',mode:0o600});
}
console.log(JSON.stringify({passed:proof.passed,checks:proof.checks,cleanup:proof.cleanup,failure:proof.failure}));
process.exitCode=proof.passed?0:1;
