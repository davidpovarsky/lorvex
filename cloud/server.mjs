import http from 'node:http';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { CloudStore,CloudError } from './store.mjs';
import { CLOUD_TOOLS,invokeCloudTool } from './tools.mjs';

const PREFIX='/cloud';
const DEFAULT_ORIGIN='http://127.0.0.1:8769/cloud';
const ACCOUNT_CSS='body{font:16px system-ui;margin:10vh auto;max-width:480px;padding:20px;color:#20242a}h1{font-size:26px}input{display:block;box-sizing:border-box;width:100%;padding:13px;font-size:17px;margin:10px 0;border:1px solid #aaa;border-radius:9px}button{padding:14px;background:#2563eb;color:white;border:0;border-radius:9px;font-size:16px;cursor:pointer}button+button{margin-left:8px;background:#4b5563}.hint{font-size:13px;color:#666}';
const htmlEscape=x=>String(x).replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
const json=(res,status,payload,headers={})=>{res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff',...headers});res.end(JSON.stringify(payload));};
const html=(res,status,body)=>{res.writeHead(status,{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'"});res.end('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><style>'+ACCOUNT_CSS+'</style>'+body+'</html>');};
const oauthReply=(id,result)=>({jsonrpc:'2.0',id,result});
const oauthError=(id,message,code=-32601)=>({jsonrpc:'2.0',id,error:{code,message}});
const bearer=req=>{const authorization=req.headers.authorization||'';return authorization.startsWith('Bearer ')?authorization.slice(7):'';};
const requestBody=async req=>{
 let size=0,buffers=[];
 for await(const chunk of req){size+=chunk.length;if(size>18*1024*1024)throw new CloudError(413,'payload_too_large');buffers.push(chunk);}
 return Buffer.concat(buffers).toString('utf8');
};
const parseBody=async req=>{
 const text=await requestBody(req);
 try {
   if(req.headers['content-type']?.startsWith('application/x-www-form-urlencoded')){
     return Object.fromEntries(new URLSearchParams(text));
   }
   return text?JSON.parse(text):{};
 }catch{throw new CloudError(400,'invalid_json');}
};
function validRedirect(uri,allowLocalhost=false){
 try{
   const u=new URL(uri);
   if(u.protocol==='http:'&&allowLocalhost&&u.hostname==='127.0.0.1')return true;
   if(u.protocol!=='https:')return false;
   return u.hostname==='chatgpt.com'||u.hostname==='chat.openai.com'||
     u.hostname.endsWith('.chatgpt.com')||u.hostname.endsWith('.openai.com')||
     u.hostname==='openai.com';
 }catch{return false;}
}
const publicSession=session=>({id:session.account_id});
export function createCloudServer({
  dbFile=process.env.LORVEX_CLOUD_DB||path.resolve('lorvex-cloud.sqlite'),
  publicOrigin=process.env.LORVEX_CLOUD_ORIGIN||DEFAULT_ORIGIN,
  allowLocalhostOAuth=false,clock=Date.now
}={}) {
  const origin=publicOrigin.replace(/\/$/,'');
  if(!origin.endsWith(PREFIX))throw new Error('LORVEX_CLOUD_ORIGIN must end in /cloud');
  const store=new CloudStore(dbFile,{clock});
  const attempts=new Map();
  const throttle=(name)=>{
    const entry=attempts.get(name)||{count:0,until:0};
    if(entry.until>clock())throw new CloudError(429,'too_many_login_attempts');
    entry.count++;
    if(entry.count>8){entry.count=0;entry.until=clock()+10*60*1000;}
    attempts.set(name,entry);
  };
  const register=(res,email,password)=>{
    throttle('register:'+String(email).slice(0,180).toLowerCase());
    const account=store.createAccount(email,password);
    return json(res,201,{user:store.publicAccount(account),...store.issueToken(account.id)});
  };
  const login=(res,email,password)=>{
    throttle('login:'+String(email).slice(0,180).toLowerCase());
    const account=store.login(email,password);
    return json(res,200,{user:store.publicAccount(account),...store.issueToken(account.id)});
  };
  const loginForm=(res,requestId,error='')=>html(res,200,[
    '<title>Lorvex Account</title><h1>Sign in to Lorvex</h1>',
    '<p>Connect your tasks, lists, calendar and habits to ChatGPT.</p>',
    '<p class="hint">No iPad pairing code is required. Your Lorvex account is stored on your private server.</p>',
    error?'<p role="alert" style="color:#b91c1c">Sign-in failed. Check your email and password.</p>':'',
    '<form action="/cloud/oauth/approve" method="post">',
    '<input type="hidden" name="request" value="'+htmlEscape(requestId)+'">',
    '<label>Email<input type="email" name="email" autocomplete="username" maxlength="250" required></label>',
    '<label>Password<input type="password" name="password" autocomplete="current-password" minlength="12" required></label>',
    '<button name="mode" value="login" type="submit">Sign in &amp; connect</button>',
    '<button name="mode" value="register" type="submit">Create account</button>',
    '</form><p class="hint">This grants your ChatGPT connection read and write access to your Lorvex account. You can revoke it by signing out.</p>'
  ].join(''));

  const server=http.createServer(async(req,res)=>{
    const url=new URL(req.url||'/', 'http://localhost');
    const pathname=url.pathname;
    const method=req.method||'GET';
    if(pathname.startsWith(PREFIX+'/oauth/'))res.once('finish',()=>{
      console.info('OAUTH_AUDIT',method,pathname,res.statusCode);
    });
    try{
      if(method==='GET'&&pathname===PREFIX+'/health'){
        return json(res,200,{ok:true,service:'Lorvex Cloud',version:1,storage:'durable',sourceOfTruth:'server'});
      }
      if(method==='GET'&&pathname===PREFIX+'/.well-known/oauth-protected-resource'){
        return json(res,200,{resource:origin+'/mcp',authorization_servers:[origin],
          scopes_supported:['lorvex.read','lorvex.write','offline_access'],bearer_methods_supported:['header']});
      }
      if(method==='GET'&&pathname===PREFIX+'/.well-known/oauth-authorization-server'){
        return json(res,200,{issuer:origin,authorization_endpoint:origin+'/oauth/authorize',
          token_endpoint:origin+'/oauth/token',registration_endpoint:origin+'/oauth/register',
          grant_types_supported:['authorization_code','refresh_token'],
          response_types_supported:['code'],token_endpoint_auth_methods_supported:['none'],
          code_challenge_methods_supported:['S256'],
          scopes_supported:['lorvex.read','lorvex.write','offline_access']});
      }
      if(pathname===PREFIX+'/oauth/register'&&method==='POST'){
        const params=await parseBody(req);
        if(!Array.isArray(params.redirect_uris)||!params.redirect_uris.every(u=>validRedirect(u,allowLocalhostOAuth)))throw new CloudError(400,'invalid_redirect_uri');
        return json(res,201,store.registerClient(params.redirect_uris,params.client_name));
      }
      if(pathname===PREFIX+'/oauth/authorize'&&method==='GET'){
        if(url.searchParams.get('response_type')!=='code'||
            url.searchParams.get('code_challenge_method')!=='S256')throw new CloudError(400,'unsupported_authorization_request');
        const clientId=url.searchParams.get('client_id');
        const redirect=url.searchParams.get('redirect_uri');
        if(!validRedirect(redirect,allowLocalhostOAuth))throw new CloudError(400,'redirect_not_allowed');
        const requestId=store.beginOAuth(clientId,redirect,url.searchParams.get('code_challenge'),url.searchParams.get('state')||'');
        return loginForm(res,requestId);
      }
      if(pathname===PREFIX+'/oauth/approve'&&method==='POST'){
        const form=await parseBody(req);
        const request=store.oauthRequest(form.request);
        if(!request)return html(res,400,'<h1>Sign-in expired</h1><p>Return to ChatGPT and reconnect Lorvex.</p>');
        let account;
        try {
          if(form.mode==='register'){
            throttle('register:'+String(form.email).slice(0,180).toLowerCase());
            account=store.createAccount(form.email,form.password);
          } else {
            throttle('login:'+String(form.email).slice(0,180).toLowerCase());
            account=store.login(form.email,form.password);
          }
        } catch(e) {
          if(e instanceof CloudError&&[401,409,422].includes(e.status))return loginForm(res,form.request,'invalid');
          throw e;
        }
        const grant=store.approveOAuth(form.request,account.id);
        const callback=new URL(grant.redirect);
        callback.searchParams.set('code',grant.code);
        if(grant.state)callback.searchParams.set('state',grant.state);
        res.writeHead(302,{'Location':callback.toString(),'Cache-Control':'no-store'});
        return res.end();
      }
      if(pathname===PREFIX+'/oauth/token'&&method==='POST'){
        const params=await parseBody(req);
        if(params.grant_type==='authorization_code')
          return json(res,200,store.exchange(params.code,params.client_id,params.redirect_uri,params.code_verifier));
        if(params.grant_type==='refresh_token')
          return json(res,200,store.refresh(params.refresh_token,params.client_id));
        throw new CloudError(400,'unsupported_grant_type');
      }
      if(pathname===PREFIX+'/v1/auth/register'&&method==='POST'){
        const p=await parseBody(req);
        return register(res,p.email,p.password);
      }
      if(pathname===PREFIX+'/v1/auth/login'&&method==='POST'){
        const p=await parseBody(req);
        return login(res,p.email,p.password);
      }
      if(pathname===PREFIX+'/v1/auth/refresh'&&method==='POST'){
        const p=await parseBody(req);
        return json(res,200,store.refresh(p.refresh_token,null));
      }
      if(pathname===PREFIX+'/v1/auth/logout'&&method==='POST'){
        store.revoke(bearer(req));return json(res,200,{revoked:true});
      }
      if(pathname===PREFIX+'/mcp'){
        if(method==='GET')return json(res,405,{error:'streamable_http_post_required'},{Allow:'POST'});
        if(method!=='POST')throw new CloudError(405,'method_not_allowed');
        const p=await parseBody(req);
        if(!p||p.jsonrpc!=='2.0')throw new CloudError(400,'invalid_jsonrpc');
        if(p.method==='initialize')return json(res,200,oauthReply(p.id,{
          protocolVersion:'2025-06-18',capabilities:{tools:{listChanged:false}},
          serverInfo:{name:'Lorvex Cloud MCP',version:'1.0.0'}}));
        if(p.method==='ping')return json(res,200,oauthReply(p.id,{}));
        if(p.method?.startsWith('notifications/')){res.writeHead(202);return res.end();}
        let session;
        try{session=store.authenticate(bearer(req),'lorvex.read');}
        catch(e){
          return json(res,401,{error:'unauthorized'},{
            'WWW-Authenticate':'Bearer resource_metadata="'+origin+'/.well-known/oauth-protected-resource"'});
        }
        if(p.method==='tools/list'){
          return json(res,200,oauthReply(p.id,{tools:CLOUD_TOOLS.map(({writes,...t})=>t)}));
        }
        if(p.method==='tools/call'){
          try{
            const spec=CLOUD_TOOLS.find(t=>t.name===p.params?.name);
            if(spec?.writes)store.authenticate(bearer(req),'lorvex.write');
            const result=invokeCloudTool(store,session.account_id,p.params?.name,p.params?.arguments??{});
            return json(res,200,oauthReply(p.id,result));
          }catch(error){
            return json(res,200,oauthReply(p.id,{isError:true,content:[{type:'text',text:
              error instanceof CloudError?error.code:'tool_failed'}]}));
          }
        }
        return json(res,200,oauthError(p.id,'Method not found'));
      }
      const session=store.authenticate(bearer(req));
      const accountId=session.account_id;
      if(method==='GET'&&pathname===PREFIX+'/v1/account/me'){
        const account=store.get('SELECT * FROM accounts WHERE id=?',accountId);
        return json(res,200,{user:store.publicAccount(account),sync:'ready'});
      }
      if(method==='GET'&&pathname===PREFIX+'/v1/sync/changes'){
        const cursor=Number(url.searchParams.get('cursor')??0);
        const limit=Number(url.searchParams.get('limit')??100);
        return json(res,200,store.changes(accountId,cursor,limit));
      }
      if(method==='POST'&&pathname===PREFIX+'/v1/sync/push'){
        store.authenticate(bearer(req),'lorvex.write');
        const body=await parseBody(req);
        return json(res,200,store.push(accountId,body.envelopes,body.request_id));
      }
      if(method==='GET'&&pathname===PREFIX+'/v1/dashboard'){
        return json(res,200,store.summary(accountId));
      }
      if(method==='POST'&&pathname===PREFIX+'/v1/tools/call'){
        store.authenticate(bearer(req),'lorvex.write');
        const p=await parseBody(req);
        return json(res,200,invokeCloudTool(store,accountId,p.name,p.arguments));
      }
      return json(res,404,{error:'not_found'});
    }catch(error){
      const status=error instanceof CloudError?error.status:500;
      if(status===500)console.error('SERVER_ERROR',String(error?.message||'error').slice(0,150));
      if(!res.headersSent)return json(res,status,{error:error instanceof CloudError?error.code:'internal_error'});
      res.end();
    }
  });
  return {server,store,close:()=>new Promise(resolve=>server.close(()=>{store.close();resolve();}))};
}

const entry=process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url);
if(entry){
  const port=Number(process.env.LORVEX_CLOUD_PORT||8769);
  const host=process.env.LORVEX_CLOUD_HOST||'127.0.0.1';
  const service=createCloudServer();
  service.server.listen(port,host,()=>{
    console.log('Lorvex Cloud listening on '+host+':'+port+' (use TLS reverse proxy)');
  });
}
