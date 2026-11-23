import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash, randomBytes } from 'node:crypto';
import { createBridge } from './server.mjs';

test('OAuth pairing, MCP auth and real device tool round trip without storing task data', async () => {
  const folder=mkdtempSync(path.join(tmpdir(),'lorvex-bridge-'));
  const bridge=createBridge({statePath:path.join(folder,'state.json')});
  await new Promise(resolve=>bridge.server.listen(0,'127.0.0.1',resolve));
  const base=bridge.getPublicBase();
  const client=async(uri,opts={})=>{
    const r=await fetch(base+uri,opts);
    const text=await r.text();
    let j;try{j=JSON.parse(text)}catch{j=text}
    return {status:r.status,json:j,headers:r.headers};
  };
  const jsonPost=(obj,auth)=>({
    method:'POST',headers:{
      'Content-Type':'application/json',
      ...(auth?{Authorization:'Bearer '+auth}:{})},
    body:JSON.stringify(obj)
  });
  try {
    const hello=await client('/mcp',jsonPost({jsonrpc:'2.0',id:1,method:'initialize'}));
    assert.equal(hello.status,200);
    assert.equal(hello.json.result.serverInfo.name,'Lorvex Remote MCP Bridge');

    const unauth=await client('/mcp',jsonPost({jsonrpc:'2.0',id:2,method:'tools/list'}));
    assert.equal(unauth.status,401);
    assert.match(unauth.headers.get('www-authenticate'),/resource_metadata/);

    const secret=randomBytes(32).toString('base64url');
    const deviceId='device-test-12345';
    const catalog=[{
      name:'get_today',description:'Read local today',
      writes:false,inputSchema:{type:'object',additionalProperties:false,properties:{}}
    },{
      name:'create_task',description:'Create a task requiring host consent',
      writes:true,inputSchema:{type:'object',additionalProperties:false,
        properties:{title:{type:'string',minLength:1,maxLength:500}},required:['title']}
    }];
    const enrolled=await client('/v1/device/register',jsonPost({deviceId,catalog},secret));
    assert.equal(enrolled.status,200);
    assert.equal(enrolled.json.pairingCode.length,8);
    const repeatWrong=await client('/v1/device/register',jsonPost({deviceId,catalog},'wrong'));
    assert.equal(repeatWrong.status,403);
    const verifier=randomBytes(40).toString('base64url');
    const challenge=createHash('sha256').update(verifier).digest('base64url');
    const registered=await client('/oauth/register',jsonPost({
      client_name:'ChatGPT',redirect_uris:['https://chatgpt.com/connector_platform_oauth_redirect']
    }));
    assert.equal(registered.status,201);
    const clientId=registered.json.client_id;
    const callback=registered.json.redirect_uris[0];
    const args=new URLSearchParams({
      client_id:clientId,response_type:'code',redirect_uri:callback,
      code_challenge:challenge,code_challenge_method:'S256',state:'opaque-state'
    });
    const auth=await client('/oauth/authorize?'+args.toString());
    assert.equal(auth.status,200);
    const policy=auth.headers.get('content-security-policy');
    assert.match(policy,/default-src 'none'/);
    assert.match(policy,/frame-ancestors 'none'/);
    assert.doesNotMatch(policy,/form-action/i,
      'The consent form must permit Chromium to follow OAuth callback redirects');
    const request=auth.json.match(/name="request" value="([^"]+)"/)[1];
    const approve=await fetch(base+'/oauth/approve',{
      method:'POST',redirect:'manual',headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:new URLSearchParams({request,pair:enrolled.json.pairingCode})
    });
    assert.equal(approve.status,302);
    const location=new URL(approve.headers.get('location'));
    assert.equal(location.searchParams.get('state'),'opaque-state');
    const code=location.searchParams.get('code');
    const allowedSameFormRetry=await client('/oauth/approve',{
      method:'POST',redirect:'manual',
      headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:new URLSearchParams({request,pair:enrolled.json.pairingCode})});
    assert.equal(allowedSameFormRetry.status,302);
    const replayCode=new URL(allowedSameFormRetry.headers.get('location'))
      .searchParams.get('code');
    assert.ok(replayCode && replayCode!==code);
    const invalidPair=await client('/oauth/approve',{
      method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:new URLSearchParams({request,pair:'ABCDEFGH'})});
    assert.equal(invalidPair.status,200);
    assert.match(invalidPair.json,/Invalid or expired code/);
    const form=new URLSearchParams({
      grant_type:'authorization_code',code:replayCode,client_id:clientId,
      redirect_uri:callback,code_verifier:verifier
    });
    const token=await client('/oauth/token',{
      method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:form.toString()
    });
    assert.equal(token.status,200);
    assert.equal(token.json.token_type,'Bearer');
    const bearer=token.json.access_token;
    const discovered=await client('/mcp',jsonPost({jsonrpc:'2.0',id:3,method:'tools/list'},bearer));
    assert.equal(discovered.status,200);
    assert.equal(discovered.json.result.tools.length,2);
    assert.deepEqual(discovered.json.result.tools.map(t=>t.name),['get_today','create_task']);

    const inFlight=client('/mcp',jsonPost({
      jsonrpc:'2.0',id:4,method:'tools/call',
      params:{name:'get_today',arguments:{}}
    },bearer));
    const polled=await client('/v1/device/poll?device_id='+deviceId,{
      headers:{Authorization:'Bearer '+secret}
    });
    // A tick lets the async MCP request enter the command queue.
    let cmd=polled.json.commands[0];
    if(!cmd){
      await new Promise(r=>setTimeout(r,40));
      const retry=await client('/v1/device/poll?device_id='+deviceId,{headers:{Authorization:'Bearer '+secret}});
      cmd=retry.json.commands[0];
    }
    assert.equal(cmd.name,'get_today');
    const finish=await client('/v1/device/result',jsonPost({
      deviceId,id:cmd.id,text:'{"tasks":[{"title":"Plan week"}]}',error:false
    },secret));
    assert.equal(finish.status,200);
    const done=await inFlight;
    assert.equal(done.status,200);
    assert.equal(done.json.result.content[0].text,'{"tasks":[{"title":"Plan week"}]}');
    assert.equal(bridge.commands.size,0);
    assert.equal(bridge.outstanding.size,0);

    // Wrong bearer cannot push task changes into the same device.
    const invalid=await client('/v1/device/result',jsonPost({
      deviceId,id:'not-real',text:'{"ok":true}',error:false},'wrong'));
    assert.equal(invalid.status,401);
    const unsupported=await client('/mcp',jsonPost({
      jsonrpc:'2.0',id:5,method:'tools/call',params:{name:'delete_everything',arguments:{}}
    },bearer));
    assert.equal(unsupported.json.result.isError,true);
    assert.equal(Object.values(bridge.store.devices).length,1);
  } finally {
    await bridge.close();
    rmSync(folder,{recursive:true,force:true});
  }
});
