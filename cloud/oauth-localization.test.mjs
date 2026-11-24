import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash,randomBytes} from 'node:crypto';
import {createCloudServer} from './server.mjs';

const issuer='https://lorvex.example/cloud',origin='https://lorvex.example';
async function fixture(t){
 const folder=mkdtempSync(path.join(os.tmpdir(),'lorvex-oauth-language-'));
 const dbFile=path.join(folder,'fixture.sqlite');
 let now=Date.now(),app,address;
 const start=async()=>{app=createCloudServer({dbFile,publicOrigin:issuer,clock:()=>now});
  await new Promise(r=>app.server.listen(0,'127.0.0.1',r));address='http://127.0.0.1:'+app.server.address().port;};
 await start();
 t.after(async()=>{app.server.closeAllConnections();await app.close();rmSync(folder,{recursive:true,force:true});});
 const request=async(route,body=null,headers={},form=false)=>{
  const res=await fetch(address+'/cloud'+route,{method:body===null?'GET':'POST',redirect:'manual',
   headers:{...(body===null?{}:{'content-type':form?'application/x-www-form-urlencoded':'application/json'}),...headers},
   body:body===null?undefined:form?new URLSearchParams(body):JSON.stringify(body)});
  const text=await res.text();let value;try{value=JSON.parse(text);}catch{value=text;}
  return {status:res.status,value,headers:res.headers};};
 const begin=async(ui_locales='',acceptLanguage='')=>{
  const redirect='https://chatgpt.com/connector_platform_oauth_redirect';
  const client=(await request('/oauth/register',{redirect_uris:[redirect]})).value.client_id;
  const verifier=randomBytes(48).toString('base64url');
  const page=await request('/oauth/authorize?'+new URLSearchParams({client_id:client,redirect_uri:redirect,
   response_type:'code',code_challenge_method:'S256',code_challenge:createHash('sha256').update(verifier).digest('base64url'),
   state:'unchanged-state',scope:'lorvex.read offline_access',resource:issuer+'/mcp',ui_locales}),null,{'accept-language':acceptLanguage});
  assert.equal(page.status,200);
  const id=page.value.match(/name="request" value="([^"]+)"/)[1];
  return {page,id,client,verifier,redirect};};
 return {request,begin,get app(){return app;},advance:ms=>{now+=ms;},
  restart:async()=>{app.server.closeAllConnections();await app.close();await start();}};
}
test('OAuth consent negotiates Hebrew/English and displays exact scope with safe browser headers',async t=>{
 const f=await fixture(t);
 for(const [locales,accept,want] of [['he-IL','en','he'],['fr en-GB','he','en'],['','en;q=0.3,he;q=0.9','he'],['','he;q=0,*;q=1','en'],['','','he']]){
  const {page}=await f.begin(locales,accept);
  assert.match(page.value,new RegExp('lang="'+want+'"'));
  assert.match(page.value,new RegExp('dir="'+(want==='he'?'rtl':'ltr')+'"'));
  assert.match(page.value,/12[–-]256/);
  assert.match(page.value,/name="language"/);
  assert.doesNotMatch(page.value,/lorvex\.write/);
  assert.equal(page.headers.get('referrer-policy'),'same-origin');
  assert.match(page.headers.get('content-security-policy'),/form-action 'self'/);
 }
});
test('Language switch preserves the grant and expiry, and remains durable across restart',async t=>{
 const f=await fixture(t),g=await f.begin('he');
 const before=f.app.store.oauthRequest(g.id);
 const switched=await f.request('/oauth/language',{request:g.id,language:'en'},{origin},true);
 assert.equal(switched.status,200);assert.match(switched.value,/lang="en"/);
 const after=f.app.store.oauthRequest(g.id);
 assert.deepEqual({...after,language:before.language},{...before});
 await f.restart();
 assert.equal(f.app.store.oauthRequest(g.id).language,'en');
 assert.equal(f.app.store.get('SELECT count(*) n FROM accounts').n,0);
 assert.equal(f.app.store.get('SELECT count(*) n FROM oauth_codes').n,0);
 const response=await f.request('/oauth/approve',{request:g.id,email:'fixture@example.invalid',password:'synthetic fixture password',mode:'register'},{origin},true);
 assert.equal(response.status,302);
 const callback=new URL(response.headers.get('location'));
 assert.equal(callback.searchParams.get('state'),'unchanged-state');
 assert.equal(callback.searchParams.get('iss'),issuer);
 const token=await f.request('/oauth/token',{grant_type:'authorization_code',client_id:g.client,redirect_uri:g.redirect,code:callback.searchParams.get('code'),code_verifier:g.verifier,resource:issuer+'/mcp'});
 assert.equal(token.status,200);assert.equal(token.value.scope,'lorvex.read offline_access');
});
test('Language and approval reject foreign origins without creating accounts or extending the request',async t=>{
 const f=await fixture(t),g=await f.begin('he');
 const before=f.app.store.oauthRequest(g.id);
 for(const headers of [{origin:'https://other.example'},{origin:'null'},{}]){
  const denied=await f.request('/oauth/language',{request:g.id,language:'en'},headers,true);
  assert.equal(denied.status,403);assert.match(denied.value,/lang="he"/);
 }
 assert.equal((await f.request('/oauth/language',{request:g.id,language:'fr'},{origin},true)).status,400);
 const denied=await f.request('/oauth/approve',{request:g.id,mode:'register',email:'fixture@example.invalid',password:'synthetic fixture password'},{origin:'https://other.example'},true);
 assert.equal(denied.status,403);
 assert.deepEqual(f.app.store.oauthRequest(g.id),before);
 assert.equal(f.app.store.get('SELECT count(*) n FROM accounts').n,0);
});
test('Selected language survives rejection and expiry; submitted markup is never reflected',async t=>{
 const f=await fixture(t),g=await f.begin('en');
 const invalid=await f.request('/oauth/approve',{request:g.id,mode:'register',email:'<script>submitted-private-markup</script>',password:'short'},{origin},true);
 assert.equal(invalid.status,200);assert.match(invalid.value,/lang="en"/);
 assert.doesNotMatch(invalid.value,/<script>|submitted-private-markup/);
 f.advance(600001);
 const expired=await f.request('/oauth/approve',{request:g.id,mode:'login',email:'fixture@example.invalid',password:'synthetic fixture password'},{origin},true);
 assert.equal(expired.status,400);assert.match(expired.value,/lang="en"/);assert.match(expired.value,/expired/i);
 assert.equal(f.app.store.get('SELECT count(*) n FROM accounts').n,0);
});

test('Additive language migration preserves existing accounts, sessions and pending grants',async t=>{
 const f=await fixture(t),g=await f.begin('en');
 const account=f.app.store.createAccount('migration@example.invalid','synthetic migration password');
 const token=f.app.store.issueToken(account.id);
 const before={...f.app.store.oauthRequest(g.id)};delete before.language;
 f.app.store.db.exec('ALTER TABLE oauth_requests DROP COLUMN language');
 await f.restart();
 const after={...f.app.store.oauthRequest(g.id)};
 assert.equal(after.language,'he');delete after.language;
 assert.deepEqual(after,before);
 assert.equal(f.app.store.authenticate(token.access_token).account_id,account.id);
 assert.equal(f.app.store.get('SELECT count(*) n FROM accounts').n,1);
});
