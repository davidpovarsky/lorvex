import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes,createHash} from 'node:crypto';
import {createCloudServer} from './server.mjs';
const issuer='https://lorvex.example.com/cloud',resource=issuer+'/mcp';
const email='oauth-contract@example.com',password='Long OAuth contract password';
async function fixture(fn){
 const app=createCloudServer({dbFile:':memory:',publicOrigin:issuer});
 await new Promise(r=>app.server.listen(0,'127.0.0.1',r));
 const base='http://127.0.0.1:'+app.server.address().port;
 const request=async(route,body=null,token=null)=>{
   const res=await fetch(base+route,{method:body===null?'GET':'POST',redirect:'manual',headers:{...(body!==null?{'Content-Type':'application/json'}:{}),...(token?{Authorization:'Bearer '+token}:{})},body:body===null?undefined:JSON.stringify(body)});
   const text=await res.text();let value;try{value=JSON.parse(text);}catch{value=text;}
   return {status:res.status,headers:res.headers,value};
 };
 try{await request('/cloud/v1/auth/register',{email,password});await fn({request,app});}finally{await app.close();}
}
async function authorize(request,{scope='lorvex.read lorvex.write offline_access',target=resource}={}){
 const redirect='https://chatgpt.com/connector/oauth/callback';
 const reg=await request('/cloud/oauth/register',{client_name:'Cloud contract test',redirect_uris:[redirect],token_endpoint_auth_method:'none'});
 assert.equal(reg.status,201);
 const verifier=randomBytes(48).toString('base64url');
 const params={client_id:reg.value.client_id,redirect_uri:redirect,response_type:'code',state:'contract-state',code_challenge:createHash('sha256').update(verifier).digest('base64url'),code_challenge_method:'S256',scope,resource:target};
 const page=await request('/cloud/oauth/authorize?'+new URLSearchParams(params));
 if(page.status!==200)return {page,params,verifier};
 const id=page.value.match(/name="request" value="([^"]+)"/)[1];
 const approved=await request('/cloud/oauth/approve',{request:id,mode:'login',email,password});
 assert.equal(approved.status,302);
 const callback=new URL(approved.headers.get('location'));
 assert.equal(callback.searchParams.get('state'),'contract-state');
 assert.equal(callback.searchParams.get('iss'),issuer);
 return {page,params,verifier,exchange:{grant_type:'authorization_code',code:callback.searchParams.get('code'),client_id:params.client_id,redirect_uri:redirect,code_verifier:verifier,resource:target}};
}
test('OAuth issuer path discovery exposes the correct independent authorization server',async()=>fixture(async({request})=>{
 const auth=await request('/.well-known/oauth-authorization-server/cloud');
 const protectedResource=await request('/.well-known/oauth-protected-resource/cloud/mcp');
 assert.equal(auth.status,200);assert.equal(auth.value.issuer,issuer);
 assert.equal(protectedResource.status,200);assert.equal(protectedResource.value.resource,resource);
 assert.equal(auth.value.revocation_endpoint,issuer+'/oauth/revoke');
 assert.equal(auth.value.authorization_response_iss_parameter_supported,true);
}));
test('OAuth grants only requested scope and emits HTTP403 for unauthorized writes',async()=>fixture(async({request})=>{
 const auth=await authorize(request,{scope:'lorvex.read offline_access'});
 const exchanged=await request('/cloud/oauth/token',auth.exchange);
 assert.equal(exchanged.status,200);assert.equal(exchanged.value.scope,'lorvex.read offline_access');
 const token=exchanged.value.access_token;
 const list=await request('/cloud/mcp',{jsonrpc:'2.0',id:1,method:'tools/list'},token);
 assert.equal(list.status,200);assert.equal(list.value.result.tools.length,22);
 const denied=await request('/cloud/mcp',{jsonrpc:'2.0',id:2,method:'tools/call',params:{name:'create_task',arguments:{title:'Must not exist'}}},token);
 assert.equal(denied.status,403);assert.match(denied.headers.get('www-authenticate'),/insufficient_scope/);
 assert.equal((await request('/cloud/v1/dashboard',null,token)).value.totalMatching,0);
 const wide=await request('/cloud/oauth/token',{grant_type:'refresh_token',client_id:auth.params.client_id,refresh_token:exchanged.value.refresh_token,resource,scope:'lorvex.read lorvex.write'});
 assert.equal(wide.status,400);assert.equal(wide.value.error,'invalid_scope');
 const refresh=await request('/cloud/oauth/token',{grant_type:'refresh_token',client_id:auth.params.client_id,refresh_token:exchanged.value.refresh_token,resource});
 assert.equal(refresh.status,200);assert.equal(refresh.value.scope,exchanged.value.scope);
}));
test('OAuth rejects another resource and unknown scopes without consuming valid grant',async()=>fixture(async({request})=>{
 assert.equal((await authorize(request,{target:'https://other.example/mcp'})).page.status,400);
 assert.equal((await authorize(request,{scope:'admin'})).page.status,400);
 const auth=await authorize(request);
 const wrong=await request('/cloud/oauth/token',{...auth.exchange,resource:'https://other.example/mcp'});
 assert.equal(wrong.status,400);
 const valid=await request('/cloud/oauth/token',auth.exchange);
 assert.equal(valid.status,200);
 const wrongRefresh=await request('/cloud/oauth/token',{grant_type:'refresh_token',client_id:auth.params.client_id,refresh_token:valid.value.refresh_token,resource:'https://other.example/mcp'});
 assert.equal(wrongRefresh.status,400);
}));
test('OAuth revocation removes access and refresh credentials for only its own client',async()=>fixture(async({request})=>{
 const first=await authorize(request),second=await authorize(request);
 const one=(await request('/cloud/oauth/token',first.exchange)).value;
 const two=(await request('/cloud/oauth/token',second.exchange)).value;
 await request('/cloud/oauth/revoke',{token:one.refresh_token,client_id:second.params.client_id});
 assert.equal((await request('/cloud/v1/dashboard',null,one.access_token)).status,200);
 await request('/cloud/oauth/revoke',{token:one.refresh_token,client_id:first.params.client_id});
 assert.equal((await request('/cloud/v1/dashboard',null,one.access_token)).status,401);
 assert.equal((await request('/cloud/v1/dashboard',null,two.access_token)).status,200);
 assert.equal((await request('/cloud/oauth/token',{grant_type:'refresh_token',client_id:first.params.client_id,refresh_token:one.refresh_token,resource})).status,400);
}));
