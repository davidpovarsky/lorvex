import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {randomBytes,createHash} from 'node:crypto';
import {createCloudServer} from './server.mjs';

async function fixture(fn){
  const folder=mkdtempSync(path.join(tmpdir(),'lorvex-cloud-test-'));
  const file=path.join(folder,'database.sqlite');
  const app=createCloudServer({dbFile:file,publicOrigin:'https://lorvex.example.com/cloud',allowLocalhostOAuth:true});
  await new Promise(r=>app.server.listen(0,'127.0.0.1',r));
  const origin='http://127.0.0.1:'+app.server.address().port;
  const request=async(route,method='GET',body=null,token=null,contentType='application/json')=>{
    const headers={'Accept':'application/json'};
    if(body!==null)headers['Content-Type']=contentType;
    if(token)headers.Authorization='Bearer '+token;
    const response=await fetch(origin+route,{method,headers,redirect:'manual',
      body:body===null?undefined:(typeof body==='string'?body:JSON.stringify(body))});
    const txt=await response.text();
    let value;try{value=JSON.parse(txt)}catch{value=txt}
    return {status:response.status,value,headers:response.headers};
  };
  try{return await fn({file,app,request});}
  finally{await app.close();rmSync(folder,{recursive:true,force:true});}
}
const user=(email)=>({email,password:'Very long test passphrase 2026'});
const headers={};// Tests never use a live credential or real user data.
const base='/cloud';
const rpc=(id,method,params)=>({jsonrpc:'2.0',id,method,...(params?{params}:{})});
const payload=(id,title,version)=>({
 entity_type:'task',entity_id:id,operation:'upsert',
 version,payload_schema_version:4,
 payload:JSON.stringify({id,title,status:'open',list_id:'inbox',created_at:'2026-11-23T10:00:00Z',updated_at:'2026-11-23T10:00:00Z',version}),
 device_id:'ipad-demo-001'
});
test('user data is durable and isolated, tasks work when the iPad is offline',async()=>{
 await fixture(async({request})=>{
  const a=await request(base+'/v1/auth/register','POST',user('person-a@example.com'));
  const b=await request(base+'/v1/auth/register','POST',user('person-b@example.com'));
  assert.equal(a.status,201);assert.equal(b.status,201);
  const ac=a.value.access_token,bc=b.value.access_token;
  const created=await request(base+'/v1/tools/call','POST',
    {name:'create_task',arguments:{title:'Do groceries',request_id:'test-offline-create-0001'}},ac);
  assert.equal(created.status,200);
  const first=JSON.parse(created.value.content[0].text).task;
  assert.equal(first.title,'Do groceries');
  const replay=await request(base+'/v1/tools/call','POST',
    {name:'create_task',arguments:{title:'Do groceries',request_id:'test-offline-create-0001'}},ac);
  assert.equal(JSON.parse(replay.value.content[0].text).task.id,first.id);
  const own=await request(base+'/v1/dashboard','GET',null,ac);
  assert.equal(own.value.totalMatching,1);
  const other=await request(base+'/v1/dashboard','GET',null,bc);
  assert.equal(other.value.totalMatching,0);
  const leak=await request(base+'/v1/tools/call','POST',{name:'get_task',arguments:{id:first.id}},bc);
  assert.equal(leak.status,404);
  const changed=await request(base+'/v1/sync/changes?cursor=0','GET',null,ac);
  assert.equal(changed.value.envelopes.length,1);
  assert.equal(changed.value.envelopes[0].entity_id,first.id);
  assert.equal((await request(base+'/v1/sync/changes?cursor=0','GET',null,bc)).value.envelopes.length,0);
 });
});
test('merge/version tie, repeated outbox batches and restart are durable',async()=>{
 await fixture(async({file,request,app})=>{
  const a=await request(base+'/v1/auth/register','POST',user('sync@example.com'));
  const token=a.value.access_token;
  const id='a8a9a7e0-0e20-42ed-9310-1ec6918c7111';
  const v1='1795000000000_0001_abcdabcdabcdabcd';
  const v2='1795000000001_0000_abcdabcdabcdabcd';
  const batchId='sync-operation-id-000001';
  let res=await request(base+'/v1/sync/push','POST',{request_id:batchId,envelopes:[payload(id,'Local task',v1)]},token);
  assert.equal(res.status,200);assert.equal(res.value.results[0].status,'accepted');
  res=await request(base+'/v1/sync/push','POST',{request_id:batchId,envelopes:[payload(id,'Local task',v1)]},token);
  assert.equal(res.value.results[0].status,'accepted');
  res=await request(base+'/v1/sync/push','POST',{request_id:'sync-operation-id-000002',envelopes:[payload(id,'Stale text','1794999999999_0000_abcdabcdabcdabcd')]},token);
  assert.equal(res.value.results[0].status,'stale');
  assert.equal(JSON.parse(res.value.results[0].winner.payload).title,'Local task');
  res=await request(base+'/v1/sync/push','POST',{request_id:'sync-operation-id-000003',envelopes:[payload(id,'Updated task',v2)]},token);
  assert.equal(res.value.results[0].status,'accepted');
  const changes=(await request(base+'/v1/sync/changes?cursor=0','GET',null,token)).value;
  assert.equal(changes.envelopes.length,2);
  assert.equal(changes.cursor,2);
  assert.equal(JSON.parse(changes.envelopes[1].payload).title,'Updated task');
  assert.equal((await request(base+'/v1/sync/changes?cursor=2','GET',null,token)).value.envelopes.length,0);
  // The on-disk DB can be re-opened after a complete service restart.
  const {CloudStore}=await import('./store.mjs');
  const second=new CloudStore(file);
  try {
    assert.equal(second.list(a.value.user.id,'task').length,1);
    assert.equal(second.changes(a.value.user.id,0).envelopes.length,2);
  }finally{second.close();}
 });
});
test('standard OAuth PKCE sign-in uses account password, never device pairing',async()=>{
 await fixture(async({request})=>{
  const email='oauth@example.com';
  await request(base+'/v1/auth/register','POST',user(email));
  const redirect='http://127.0.0.1:9999/callback';
  const reg=await request(base+'/oauth/register','POST',{client_name:'ChatGPT',
    redirect_uris:[redirect]});
  assert.equal(reg.status,201);
  const clientId=reg.value.client_id;
  const verifier=randomBytes(48).toString('base64url');
  const challenge=createHash('sha256').update(verifier).digest('base64url');
  const authorizeURL=new URLSearchParams({
    client_id:clientId,redirect_uri:redirect,response_type:'code',state:'opaque-sandbox',
    code_challenge:challenge,code_challenge_method:'S256'});
  const authorize=await request(base+'/oauth/authorize?'+authorizeURL,'GET');
  assert.equal(authorize.status,200);
  assert.match(authorize.value,/Sign in to Lorvex/);
  assert.doesNotMatch(authorize.value,/name=["']pair["']/i);
  const requestId=authorize.value.match(/name="request" value="([^"]+)"/)[1];
  const approve=await request(base+'/oauth/approve','POST',
    new URLSearchParams({request:requestId,mode:'login',...user(email)}).toString(),
    null,'application/x-www-form-urlencoded');
  assert.equal(approve.status,302);
  const callback=new URL(approve.headers.get('location'));
  assert.equal(callback.searchParams.get('state'),'opaque-sandbox');
  const code=callback.searchParams.get('code');
  const exchange=await request(base+'/oauth/token','POST',new URLSearchParams({
    grant_type:'authorization_code',code,client_id:clientId,redirect_uri:redirect,code_verifier:verifier}).toString(),
    null,'application/x-www-form-urlencoded');
  assert.equal(exchange.status,200);
  const access=exchange.value.access_token;
  const catalog=await request(base+'/mcp','POST',rpc(1,'tools/list'),access);
  assert.equal(catalog.status,200);
  assert.equal(catalog.value.result.tools.length,22);
  const create=await request(base+'/mcp','POST',rpc(2,'tools/call',{
    name:'create_task',arguments:{title:'Without iPad approval'}}),access);
  assert.equal(create.status,200);
  assert.equal(create.value.result.isError,false);
  const dashboard=await request(base+'/mcp','POST',rpc(3,'tools/call',{
    name:'get_summary',arguments:{}}),access);
  assert.equal(JSON.parse(dashboard.value.result.content[0].text).totalMatching,1);
  const usedAgain=await request(base+'/oauth/token','POST',new URLSearchParams({
    grant_type:'authorization_code',code,client_id:clientId,redirect_uri:redirect,code_verifier:verifier}).toString(),
    null,'application/x-www-form-urlencoded');
  assert.equal(usedAgain.status,400);
  const refreshed=await request(base+'/oauth/token','POST',new URLSearchParams({
    grant_type:'refresh_token',client_id:clientId,refresh_token:exchange.value.refresh_token}).toString(),
    null,'application/x-www-form-urlencoded');
  assert.equal(refreshed.status,200);
  const replayRefresh=await request(base+'/oauth/token','POST',new URLSearchParams({
    grant_type:'refresh_token',client_id:clientId,refresh_token:exchange.value.refresh_token}).toString(),
    null,'application/x-www-form-urlencoded');
  assert.equal(replayRefresh.status,400);
 });
});
test('authentication and sync validation reject attacks without mutating state',async()=>{
 await fixture(async({request})=>{
  const account=await request(base+'/v1/auth/register','POST',user('security@example.com'));
  const token=account.value.access_token;
  assert.equal((await request(base+'/v1/dashboard')).status,401);
  assert.equal((await request(base+'/v1/auth/login','POST',{email:'security@example.com',password:'bad'})).status,401);
  assert.equal((await request(base+'/v1/sync/push','POST',{request_id:'request-test-00001',envelopes:[payload('safe','x','INVALID')]},token)).status,422);
  assert.equal((await request(base+'/v1/dashboard','GET',null,token)).value.totalMatching,0);
  assert.equal((await request(base+'/oauth/register','POST',{redirect_uris:['https://evil.example/callback']})).status,400);
  const malicious=await request(base+'/mcp','POST',rpc(2,'tools/call',{name:'create_task',arguments:{title:'x'}}));
  assert.equal(malicious.status,401);
 });
});
