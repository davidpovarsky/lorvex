import http from 'node:http';
import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { URL, URLSearchParams } from 'node:url';

const MAX_BODY = 128 * 1024;
const CODE_TTL_MS = 10 * 60 * 1000;
const TOKEN_TTL_MS = 60 * 60 * 1000;
const REFRESH_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const WAIT_FOR_IPAD_MS = 48 * 1000;
const ALLOWED_TOOL_ALIASES = new Set([
  'list_tasks','get_task','search_tasks','get_summary','get_today',
  'list_lists','get_list_detail','list_events','get_event','list_habits',
  'create_task','update_task','complete_task','reopen_task','start_task',
  'pause_task','cancel_task','plan_task','create_event','create_list',
  'complete_habit','uncomplete_habit'
]);
const UI_CSS = 'body{font-family:system-ui;max-width:470px;margin:8vh auto;padding:20px;color:#222}input{box-sizing:border-box;width:100%;font-size:20px;padding:12px;margin:12px 0;border:1px solid #aaa;border-radius:10px}button{padding:12px 20px;background:#1371cf;color:white;border:0;border-radius:10px;font-size:18px}p{line-height:1.6}.error{color:#ad1515}';

const sha = (input) => createHash('sha256').update(input).digest('hex');
const random = (bytes = 32) => randomBytes(bytes).toString('base64url');
const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const pairCode = () => [...randomBytes(8)].map(n => alphabet[n % alphabet.length]).join('');
const safeEqual = (a,b) => typeof a === 'string' && typeof b === 'string' &&
  a.length === b.length && timingSafeEqual(Buffer.from(a),Buffer.from(b));
const validId = (s) => typeof s === 'string' && /^[0-9a-zA-Z_-]{8,80}$/.test(s);
const limited = (s,max=200) => typeof s==='string' && s.length>0 && s.length<=max;

export function createBridge({
  statePath = process.env.LORVEX_BRIDGE_STATE || path.resolve('bridge-state.json'),
  publicOrigin = process.env.LORVEX_BRIDGE_ORIGIN || '',
  clock = Date.now,
  allowAnyOAuthRedirect = false
} = {}) {
  const store = { devices: {}, clients: {}, tokens: {}, refreshTokens: {}, authCodes: {} };
  const commands = new Map();
  const outstanding = new Map();
  const failures = new Map();
  let publicBase = publicOrigin.replace(/\/$/,'');
  let nextError = 0;

  if (fs.existsSync(statePath)) {
    const saved = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    for (const key of Object.keys(store)) {
      if (saved[key] && typeof saved[key]==='object') Object.assign(store[key], saved[key]);
    }
  }
  const persist = () => {
    fs.mkdirSync(path.dirname(statePath),{recursive:true});
    const temp=statePath+'.tmp-'+process.pid;
    fs.writeFileSync(temp,JSON.stringify(store),{mode:0o600});
    fs.renameSync(temp,statePath);
  };
  const json = (res,code,obj,headers={}) => {
    res.writeHead(code,{
      'Content-Type':'application/json; charset=utf-8',
      'Cache-Control':'no-store',
      'X-Content-Type-Options':'nosniff',
      ...headers});
    res.end(JSON.stringify(obj));
  };
  const html = (res,code,page) => {
    res.writeHead(code,{'Content-Type':'text/html; charset=utf-8',
      'Cache-Control':'no-store','X-Content-Type-Options':'nosniff',
      'Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'"});
    res.end('<!doctype html><html lang=en><meta name=viewport content="width=device-width,initial-scale=1"><meta charset=utf-8><style>'+UI_CSS+'</style>'+page+'</html>');
  };
  const readBody = async (req) => {
    const all = [];
    let size=0;
    for await (const chunk of req) {
      size+=chunk.length;
      if (size>MAX_BODY) throw Error('payload_too_large');
      all.push(chunk);
    }
    return Buffer.concat(all).toString('utf8');
  };
  const authHeader = (req) => {
    const h=req.headers.authorization||'';
    return h.startsWith('Bearer ') ? h.slice(7) : '';
  };
  const findToken = (req) => {
    const key=sha(authHeader(req));
    const token=store.tokens[key];
    return token && token.expires>clock()?token:null;
  };
  const findDevice = (req, id) => {
    const device=store.devices[id];
    if (!device) return null;
    const secret=authHeader(req);
    return secret && safeEqual(sha(secret),device.secretHash) ? device : null;
  };
  const oauthChallenge = (res) => json(res,401,{
    error:'unauthorized',message:'Connect this private Lorvex MCP server using OAuth'
  },{'WWW-Authenticate':'Bearer resource_metadata="'+publicBase+'/.well-known/oauth-protected-resource"'});
  const errorRpc=(id,message,code=-32000)=>({jsonrpc:'2.0',id,error:{code,message}});
  const responseRpc=(id,result)=>({jsonrpc:'2.0',id,result});
  const renderAuthForm=(res,uid,err='') => html(res,200,[
    '<title>Connect Lorvex to ChatGPT</title><h2>Connect Lorvex</h2>',
    '<p>Open Lorvex on your iPad → AI → ChatGPT MCP. Copy the one-time pairing code shown there. ',
    'Only the iPad can authorize task changes.</p>',
    err?'<p class="error">Invalid or expired code. Try a fresh code.</p>':'',
    '<form method="post" action="/oauth/approve">',
    '<input type="hidden" name="request" value="'+uid+'">',
    '<input name="pair" autocomplete="one-time-code" maxlength="8" required placeholder="8-character code" spellcheck="false">',
    '<button type="submit">Connect this iPad</button></form>',
    '<p>Never share this code with anyone other than the ChatGPT connection you are approving.</p>'
  ].join(''));

  const validateRedirect=(uri) => {
    try {
      const url=new URL(uri);
      if (url.protocol!=='https:' && !(url.protocol==='http:'&&url.hostname==='127.0.0.1')) return false;
      if (allowAnyOAuthRedirect) return true;
      const host=url.hostname;
      return host==='chatgpt.com' || host.endsWith('.chatgpt.com') ||
        host==='chat.openai.com' || host==='openai.com' || host.endsWith('.openai.com') ||
        (host==='127.0.0.1' && url.protocol==='http:');
    }catch{return false;}
  };
  const validateDeviceCatalog=(catalog)=>Array.isArray(catalog) &&
    catalog.length>=1 && catalog.length<=ALLOWED_TOOL_ALIASES.size &&
    catalog.every(t=> t&&ALLOWED_TOOL_ALIASES.has(t.name) &&
      typeof t.description==='string' && t.description.length<=700 &&
      typeof t.writes==='boolean' &&
      t.inputSchema && t.inputSchema.type==='object' &&
      JSON.stringify(t.inputSchema).length<10000) &&
    new Set(catalog.map(t=>t.name)).size===catalog.length;

  const requestQueue = (deviceId,name,args) => new Promise(resolve=>{
    const commandId=random(18);
    const record={id:commandId,deviceId,name,arguments:args,createdAt:clock()};
    const timer=setTimeout(()=>{
      outstanding.delete(commandId);
      commands.delete(commandId);
      resolve({isError:true,content:[{type:'text',text:'iPad did not respond. The task may not have executed. Check Lorvex before retrying a write.'}]});
    },WAIT_FOR_IPAD_MS);
    outstanding.set(commandId,{resolve,timer,deviceId});
    commands.set(commandId,{...record,leaseUntil:0});
  });

  const server=http.createServer(async(req,res)=>{
    try {
      const url=new URL(req.url||'/', 'http://localhost');
      const u=url.pathname;
      const method=req.method;
      // Audit only request method/path/HTTP status: NEVER tokens, user IDs,
      // authorization codes, redirect queries, or task contents.
      if (u.startsWith('/oauth/')) {
        res.once('finish',()=>{
          console.info('OAUTH_HTTP', method, u, res.statusCode);
        });
      }
      if (u==='/health' && method==='GET') {
        return json(res,200,{ok:true,name:'Lorvex Remote MCP Bridge',version:'0.1.0',
          pairedDevices:Object.values(store.devices).filter(x=>x.linked).length});
      }
      if (u==='/.well-known/oauth-protected-resource' && method==='GET') {
        return json(res,200,{resource:publicBase+'/mcp',
          authorization_servers:[publicBase],scopes_supported:['lorvex.read','lorvex.write','offline_access'],
          bearer_methods_supported:['header']});
      }
      if (u==='/.well-known/oauth-authorization-server' && method==='GET') {
        return json(res,200,{issuer:publicBase,
          authorization_endpoint:publicBase+'/oauth/authorize',
          token_endpoint:publicBase+'/oauth/token',
          registration_endpoint:publicBase+'/oauth/register',
          response_types_supported:['code'],
          grant_types_supported:['authorization_code','refresh_token'],
          token_endpoint_auth_methods_supported:['none'],
          code_challenge_methods_supported:['S256'],
          scopes_supported:['lorvex.read','lorvex.write','offline_access']});
      }
      if (u==='/oauth/register' && method==='POST') {
        const data=JSON.parse(await readBody(req));
        if (!Array.isArray(data.redirect_uris) || data.redirect_uris.length===0 ||
          data.redirect_uris.length>5 || !data.redirect_uris.every(validateRedirect)) {
          return json(res,400,{error:'invalid_redirect_uri'});
        }
        if (Object.keys(store.clients).length>30) return json(res,429,{error:'too_many_clients'});
        const id=random(24);
        store.clients[id]={redirects:data.redirect_uris,registeredAt:clock()};
        persist();
        return json(res,201,{client_id:id,
          client_id_issued_at:Math.floor(clock()/1000),client_name:limited(data.client_name,80)?data.client_name:'ChatGPT',
          redirect_uris:data.redirect_uris,token_endpoint_auth_method:'none',
          grant_types:['authorization_code','refresh_token'],response_types:['code']});
      }
      if (u==='/oauth/authorize' && method==='GET') {
        const client=store.clients[url.searchParams.get('client_id')];
        const redirect=url.searchParams.get('redirect_uri');
        const responseType=url.searchParams.get('response_type');
        const challenge=url.searchParams.get('code_challenge');
        const state=url.searchParams.get('state')||'';
        if (!client || !client.redirects.includes(redirect) ||
            responseType!=='code' || !limited(challenge,200) ||
            url.searchParams.get('code_challenge_method')!=='S256')
          return html(res,400,'<h2>Invalid OAuth request</h2>');
        const authRequest=random(16);
        store.authCodes[authRequest]={clientId:url.searchParams.get('client_id'),
          redirect,challenge,state,expires:clock()+CODE_TTL_MS,type:'pending'};
        persist();
        return renderAuthForm(res,authRequest);
      }
      if (u==='/oauth/approve' && method==='POST') {
        const body=new URLSearchParams(await readBody(req));
        const uid=body.get('request');
        const auth=store.authCodes[uid];
        if (!auth||!['pending','approved'].includes(auth.type)||auth.expires<=clock()) {
          return html(res,400,'<h2>Expired sign-in</h2>');
        }
        const pair=(body.get('pair')||'').toUpperCase().replace(/[^A-Z2-9]/g,'');
        const replay=auth.type==='approved';
        // Browsers or users can submit the approval form twice in quick
        // succession. Do not discard a valid, user-approved OAuth link.
        // Reuse requires the SAME original pairing code, SAME device, and a
        // 30-second time window; no new user/device can authorize via the
        // request identifier alone.
        const device=Object.entries(store.devices).find(([id,d])=>
          d.pairCode && safeEqual(d.pairCode,pair) &&
          (replay
            ? id===auth.deviceId && d.pairUsed &&
              auth.approvedAt>clock()-30_000 && (auth.repeats||0)<2
            : d.pairExpires>clock() && !d.pairUsed));
        if (!device) {
          auth.failures=(auth.failures||0)+1;
          if (auth.failures>=5) delete store.authCodes[uid];
          persist();
          return auth.failures>=5? html(res,429,'<h2>Too many attempts</h2>') : renderAuthForm(res,uid,'bad_code');
        }
        if (!replay) {
          device[1].pairUsed=true;
          device[1].linked=true;
          auth.deviceId=device[0];
          auth.approvedAt=clock();
          auth.type='approved';
          auth.repeats=0;
        } else {
          auth.repeats+=1;
        }
        const code=random(30);
        store.authCodes[sha(code)]={...auth,type:'code'};
        persist();
        const callback=new URL(auth.redirect);
        callback.searchParams.set('code',code);
        if(auth.state)callback.searchParams.set('state',auth.state);
        res.writeHead(302,{'Location':callback.toString(),'Cache-Control':'no-store'});return res.end();
      }
      if (u==='/oauth/token' && method==='POST') {
        const form=new URLSearchParams(await readBody(req));
        const grant=form.get('grant_type');
        let deviceId;
        let clientId=form.get('client_id');
        if (grant==='authorization_code') {
          const key=sha(form.get('code')||'');
          const code=store.authCodes[key];
          const verifier=form.get('code_verifier')||'';
          const expected=createHash('sha256').update(verifier).digest('base64url');
          if (!code||code.type!=='code'||code.expires<=clock()||
              code.clientId!==clientId||code.redirect!==form.get('redirect_uri')||
              !safeEqual(code.challenge,expected) || verifier.length<43) return json(res,400,{error:'invalid_grant'});
          deviceId=code.deviceId;
          delete store.authCodes[key];
        } else if (grant==='refresh_token') {
          const key=sha(form.get('refresh_token')||'');
          const record=store.refreshTokens[key];
          if (!record||record.expires<=clock()||record.clientId!==clientId) return json(res,400,{error:'invalid_grant'});
          deviceId=record.deviceId;
          delete store.refreshTokens[key];
        } else return json(res,400,{error:'unsupported_grant_type'});
        const access=random(32),refresh=random(32);
        store.tokens[sha(access)]={deviceId,clientId,expires:clock()+TOKEN_TTL_MS};
        store.refreshTokens[sha(refresh)]={deviceId,clientId,expires:clock()+REFRESH_TTL_MS};
        persist();
        return json(res,200,{access_token:access,token_type:'Bearer',
          expires_in:Math.floor(TOKEN_TTL_MS/1000),
          refresh_token:refresh,scope:'lorvex.read lorvex.write offline_access'});
      }
      if (u==='/v1/device/register' && method==='POST') {
        const body=JSON.parse(await readBody(req));
        const id=body.deviceId,secret=authHeader(req);
        if (!validId(id)||!limited(secret,256)||!validateDeviceCatalog(body.catalog)) return json(res,400,{error:'invalid_device'});
        const current=store.devices[id];
        if (current && !safeEqual(current.secretHash,sha(secret))) return json(res,403,{error:'device_exists'});
        if (!current && Object.keys(store.devices).length>=6) return json(res,429,{error:'device_limit'});
        const code=pairCode();
        store.devices[id]={secretHash:sha(secret),catalog:body.catalog,
          pairCode:code,pairExpires:clock()+CODE_TTL_MS,
          pairUsed:false,linked:current?.linked||false,lastSeen:clock()};
        persist();
        return json(res,200,{deviceId:id,pairingCode:code,
          expiresInSeconds:CODE_TTL_MS/1000,linked:store.devices[id].linked});
      }
      if (u==='/v1/device/poll' && method==='GET') {
        const id=url.searchParams.get('device_id')||'';
        const device=findDevice(req,id);
        if(!device) return json(res,401,{error:'invalid_device_credential'});
        device.lastSeen=clock();
        const todo=[...commands.values()].filter(c=>c.deviceId===id && c.leaseUntil<clock()).slice(0,4);
        for(const c of todo)c.leaseUntil=clock()+24*1000;
        return json(res,200,{linked:device.linked,commands:todo.map(c=>({
          id:c.id,name:c.name,argumentsJSON:JSON.stringify(c.arguments)
        }))});
      }
      if (u==='/v1/device/result' && method==='POST') {
        const body=JSON.parse(await readBody(req));
        const device=findDevice(req,body.deviceId);
        if(!device) return json(res,401,{error:'invalid_device_credential'});
        const pending=outstanding.get(body.id);
        if(!pending||pending.deviceId!==body.deviceId) return json(res,404,{error:'request_expired'});
        if (typeof body.text!=='string'||body.text.length>100000) return json(res,400,{error:'result_invalid'});
        clearTimeout(pending.timer);outstanding.delete(body.id);commands.delete(body.id);
        pending.resolve({isError:body.error===true,content:[{type:'text',text:body.text}]});
        return json(res,200,{accepted:true});
      }
      if (u==='/v1/device/disconnect' && method==='POST') {
        const body=JSON.parse(await readBody(req));
        const device=findDevice(req,body.deviceId);
        if(!device) return json(res,401,{error:'invalid_device_credential'});
        for(const [key,value] of Object.entries(store.tokens)) if(value.deviceId===body.deviceId)delete store.tokens[key];
        for(const [key,value] of Object.entries(store.refreshTokens)) if(value.deviceId===body.deviceId)delete store.refreshTokens[key];
        device.linked=false;device.pairUsed=true;persist();
        return json(res,200,{disconnected:true});
      }
      if (u==='/mcp') {
        if (method==='GET') return json(res,405,{error:'SSE_not_supported; use streamable HTTP POST'}, {Allow:'POST'});
        if (method!=='POST') return json(res,405,{error:'method_not_allowed'}, {Allow:'POST'});
        const body=JSON.parse(await readBody(req));
        if (!body || body.jsonrpc!=='2.0') return json(res,400,errorRpc(null,'Invalid JSON-RPC'));
        if (body.method==='notifications/initialized' || body.method?.startsWith('notifications/')) {
          res.writeHead(202);return res.end();
        }
        const id=body.id;
        if (body.method==='initialize') return json(res,200,responseRpc(id,{
          protocolVersion:'2025-06-18',capabilities:{tools:{listChanged:false}},
          serverInfo:{name:'Lorvex Remote MCP Bridge',version:'0.1.0'}}));
        if (body.method==='ping') return json(res,200,responseRpc(id,{}));
        const token=findToken(req);
        if(!token)return oauthChallenge(res);
        const device=store.devices[token.deviceId];
        if (!device || !device.linked) return json(res,403,errorRpc(id,'Device not paired'));
        if (body.method==='tools/list') {
          const tools=device.catalog.map(t=>({
            name:t.name,description:t.description,inputSchema:t.inputSchema,
            annotations:{readOnlyHint:!t.writes,destructiveHint:t.writes,
              openWorldHint:false},
            _meta:{'io.modelcontextprotocol/tool-security':{
              securitySchemes:[{type:'oauth2',scopes:['lorvex.read','lorvex.write']}]
            }}
          }));
          return json(res,200,responseRpc(id,{tools}));
        }
        if (body.method==='tools/call') {
          const name=body.params?.name, args=body.params?.arguments||{};
          if (typeof name!=='string'||!args||typeof args!=='object'||
            Array.isArray(args)||JSON.stringify(args).length>40000 ||
            !device.catalog.some(t=>t.name===name))
            return json(res,200,responseRpc(id,{isError:true,
              content:[{type:'text',text:'Invalid or unavailable tool'}]}));
          if(!device.lastSeen||clock()-device.lastSeen>55000) {
            return json(res,200,responseRpc(id,{isError:true,
              content:[{type:'text',text:'Lorvex iPad is offline. Open Lorvex and keep it in the foreground, then retry.'}]}));
          }
          const result=await requestQueue(token.deviceId,name,args);
          return json(res,200,responseRpc(id,result));
        }
        return json(res,200,errorRpc(id,'Unknown method',-32601));
      }
      return json(res,404,{error:'not_found'});
    } catch(error) {
      console.error('Bridge error:',String(error.message).slice(0,120));
      if(!res.headersSent)json(res,400,{error:'invalid_request'});
      else res.end();
    }
  });
  server.on('listening',()=>{
    if(!publicBase) publicBase='http://127.0.0.1:'+server.address().port;
  });
  return {server,store,commands,outstanding,getPublicBase:()=>publicBase,close:()=>new Promise(resolve=>server.close(resolve))};
}

if (process.argv[1] && path.resolve(process.argv[1])===path.resolve(new URL(import.meta.url).pathname)) {
  const port=Number(process.env.LORVEX_BRIDGE_PORT||8767);
  const hostname=process.env.LORVEX_BRIDGE_HOST||'127.0.0.1';
  const bridge=createBridge();
  bridge.server.listen(port,hostname,()=>{
    console.log('Lorvex MCP relay listening on '+hostname+':'+port+' (local-only HTTP; use HTTPS tunnel)');
  });
}
