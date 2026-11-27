import test from 'node:test';
import assert from 'node:assert/strict';
import {createCloudServer} from './server.mjs';

const issuer='https://cloud.example/cloud';
async function fixture(t) {
  const app=createCloudServer({dbFile:':memory:',publicOrigin:issuer});
  await new Promise(r=>app.server.listen(0,'127.0.0.1',r));
  t.after(()=>app.close());
  const origin='http://127.0.0.1:'+app.server.address().port;
  const rpc=async(method,params={},token=null)=>{
    const r=await fetch(origin+'/cloud/mcp',{method:'POST',headers:{'content-type':'application/json',
      ...(token?{authorization:'Bearer '+token}:{})},body:JSON.stringify({jsonrpc:'2.0',id:1,method,params})});
    return {status:r.status,headers:r.headers,value:await r.json()};
  };
  return {app,rpc};
}
test('MCP descriptors expose OAuth requirements for all 26 cloud tools',async t=>{
  const {app,rpc}=await fixture(t);
  const account=app.store.createAccount('fixture@example.invalid','Fixture account password');
  const grant=app.store.issueToken(account.id);
  const listed=await rpc('tools/list',{},grant.access_token);
  assert.equal(listed.status,200);assert.equal(listed.value.result.tools.length,26);
  for(const tool of listed.value.result.tools) {
    const scopes=tool.annotations.readOnlyHint?['lorvex.read']:['lorvex.read','lorvex.write'];
    assert.deepEqual(tool.securitySchemes,[{type:'oauth2',scopes}]);
    assert.deepEqual(tool._meta.securitySchemes,tool.securitySchemes);
  }
});
test('MCP auth errors carry linking metadata and never execute unauthenticated writes',async t=>{
  const {app,rpc}=await fixture(t);
  assert.equal((await rpc('tools/list')).status,401);
  const result=await rpc('tools/call',{name:'create_task',arguments:{title:'Must not exist'}});
  assert.equal(result.status,200);assert.equal(result.value.result.isError,true);
  const challenge=result.value.result._meta['mcp/www_authenticate'][0];
  assert.match(challenge,/error="invalid_token"/);
  assert.match(challenge,/scope="lorvex.read lorvex.write"/);
  assert.equal(app.store.get('SELECT count(*) n FROM accounts').n,0);
});
test('MCP responds with a supported offered version and a stable fallback',async t=>{
  const {rpc}=await fixture(t);
  for(const protocolVersion of ['2025-03-26','2025-06-18','2025-11-25']) {
    assert.equal((await rpc('initialize',{protocolVersion})).value.result.protocolVersion,protocolVersion);
  }
  assert.equal((await rpc('initialize',{protocolVersion:'1900-01-01'})).value.result.protocolVersion,'2025-11-25');
});
