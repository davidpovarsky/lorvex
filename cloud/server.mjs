import http from 'node:http';
import {createHash} from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { CloudStore,CloudError,oauthScopes,normalEmail } from './store.mjs';
import { CLOUD_TOOLS,invokeCloudTool } from './tools.mjs';
import {oauthLabels,oauthLanguage,oauthDocument,oauthLoginBody,htmlEscape} from './oauth-page.mjs';

const PREFIX='/cloud';
const protocolVersion=offered=>['2025-03-26','2025-06-18','2025-11-25'].includes(offered)?offered:'2025-11-25';
const toolScopes=tool=>tool?.writes?['lorvex.read','lorvex.write']:['lorvex.read'];
const toolSecurity=tool=>[{type:'oauth2',scopes:toolScopes(tool)}];
const DEFAULT_ORIGIN='http://127.0.0.1:8769/cloud';
const json=(res,status,payload,headers={})=>{res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff',...headers});res.end(JSON.stringify(payload));};
const html=(res,status,body,language='he',title='Lorvex')=>{
 res.writeHead(status,{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff',
  'Referrer-Policy':'same-origin','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'"});
 res.end(oauthDocument(language==='en'?'en':'he',title,body));
};
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
   if(u.protocol!=='https:'||u.hash||u.username||u.password)return false;
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
  const resource=origin+'/mcp';
  const store=new CloudStore(dbFile,{clock,resource});
  const target=value=>{
    if(value===undefined||value===null)return resource; // Existing registered clients remain valid.
    try{if(new URL(value).toString()===new URL(resource).toString())return resource;}catch{}
    throw new CloudError(400,'invalid_target');
  };
  const challenge=(scope,error='invalid_token')=>({'WWW-Authenticate':'Bearer resource_metadata="'+origin+'/.well-known/oauth-protected-resource", scope="'+scope+'", error="'+error+'", error_description="'+(error==='insufficient_scope'?'Additional account permission is required.':'Connect your Lorvex account again.')+'"'});
  const toolAuthError=(scopes,error)=>({isError:true,content:[{type:'text',
    text:error==='insufficient_scope'?'Connect Lorvex with the required permissions.':'Connect your Lorvex account to use this tool.'}],
    _meta:{'mcp/www_authenticate':[challenge(scopes.join(' '),error)['WWW-Authenticate']]}});
  const attempts=new Map();
  const throttle=(kind,email)=>{
    // Match the complete canonical identity without retaining oversized input keys.
    const name=kind+':'+createHash('sha256').update(normalEmail(email)).digest('hex');
    const entry=attempts.get(name)||{count:0,until:0};
    if(entry.until>clock())throw new CloudError(429,'too_many_login_attempts');
    entry.count++;
    if(entry.count>8){entry.count=0;entry.until=clock()+10*60*1000;}
    attempts.set(name,entry);
  };
  const register=(res,email,password)=>{
    throttle('register',email);
    const account=store.createAccount(email,password);
    return json(res,201,{user:store.publicAccount(account),...store.issueToken(account.id)});
  };
  const login=(res,email,password)=>{
    throttle('login',email);
    const account=store.login(email,password);
    return json(res,200,{user:store.publicAccount(account),...store.issueToken(account.id)});
  };
  const oauthFailure=(res,status,language,error)=>{
    const labels=oauthLabels[language==='en'?'en':'he'];
    return html(res,status,'<h1>'+labels.errorTitle+'</h1><p role="alert">'+htmlEscape(labels[error])+'</p>',language,labels.errorTitle);
  };
  const loginForm=(res,requestId,error='',fallbackLanguage='he')=>{
    const request=store.oauthRequest(requestId);
    if(!request)return oauthFailure(res,400,fallbackLanguage,'expired');
    const language=request.language==='en'?'en':'he';
    return html(res,200,oauthLoginBody(request,error),language,oauthLabels[language].title);
  };

  const server=http.createServer(async(req,res)=>{
    const url=new URL(req.url||'/', 'http://localhost');
    const pathname=url.pathname;
    const method=req.method||'GET';
    const browserRoute=['/oauth/authorize','/oauth/approve','/oauth/language'].some(route=>pathname===PREFIX+route);
    let pageLanguage=oauthLanguage(url.searchParams.get('ui_locales'),req.headers['accept-language']);
    if(pathname.startsWith(PREFIX+'/oauth/'))res.once('finish',()=>{
      console.info('OAUTH_AUDIT',method,pathname,res.statusCode);
    });
    try{
      if(method==='GET'&&pathname===PREFIX+'/health'){
        return json(res,200,{ok:true,service:'Lorvex Cloud',version:1,storage:'durable',sourceOfTruth:'server'});
      }
      if(method==='GET'&&[PREFIX+'/.well-known/oauth-protected-resource','/.well-known/oauth-protected-resource/cloud/mcp'].includes(pathname)){
        return json(res,200,{resource:origin+'/mcp',authorization_servers:[origin],
          scopes_supported:['lorvex.read','lorvex.write','offline_access'],bearer_methods_supported:['header']});
      }
      if(method==='GET'&&[PREFIX+'/.well-known/oauth-authorization-server','/.well-known/oauth-authorization-server/cloud'].includes(pathname)){
        return json(res,200,{issuer:origin,authorization_endpoint:origin+'/oauth/authorize',
          token_endpoint:origin+'/oauth/token',registration_endpoint:origin+'/oauth/register',
          revocation_endpoint:origin+'/oauth/revoke',authorization_response_iss_parameter_supported:true,
          grant_types_supported:['authorization_code','refresh_token'],
          response_types_supported:['code'],token_endpoint_auth_methods_supported:['none'],
          code_challenge_methods_supported:['S256'],
          scopes_supported:['lorvex.read','lorvex.write','offline_access']});
      }
      if(pathname===PREFIX+'/oauth/register'&&method==='POST'){
        const params=await parseBody(req);
        if(params.token_endpoint_auth_method&&params.token_endpoint_auth_method!=='none')throw new CloudError(400,'invalid_client_metadata');
        if(!Array.isArray(params.redirect_uris)||!params.redirect_uris.every(u=>validRedirect(u,allowLocalhostOAuth)))throw new CloudError(400,'invalid_redirect_uri');
        return json(res,201,store.registerClient(params.redirect_uris,params.client_name));
      }
      if(pathname===PREFIX+'/oauth/authorize'&&method==='GET'){
        if(url.searchParams.get('response_type')!=='code'||
            url.searchParams.get('code_challenge_method')!=='S256')throw new CloudError(400,'unsupported_authorization_request');
        const clientId=url.searchParams.get('client_id');
        const redirect=url.searchParams.get('redirect_uri');
        if(!validRedirect(redirect,allowLocalhostOAuth))throw new CloudError(400,'redirect_not_allowed');
        if(url.searchParams.getAll('resource').length>1)throw new CloudError(400,'invalid_target');
        const requestId=store.beginOAuth(clientId,redirect,url.searchParams.get('code_challenge'),url.searchParams.get('state')||'',oauthScopes(url.searchParams.get('scope')??undefined),target(url.searchParams.get('resource')),pageLanguage);
        return loginForm(res,requestId);
      }
      if([PREFIX+'/oauth/approve',PREFIX+'/oauth/language'].includes(pathname)&&method==='POST'){
        const form=await parseBody(req),languageOnly=pathname===PREFIX+'/oauth/language';
        const id=typeof form.request==='string'?form.request:'';
        const display=store.get('SELECT language FROM oauth_requests WHERE id=?',id);
        if(display)pageLanguage=display.language==='en'?'en':'he';
        if((languageOnly||req.headers.origin)&&req.headers.origin!==new URL(origin).origin)
          return oauthFailure(res,403,pageLanguage,'invalidOrigin');
        const request=store.oauthRequest(id);
        if(!request)return oauthFailure(res,400,pageLanguage,'expired');
        if(languageOnly){
          store.setOAuthLanguage(id,form.language);
          return loginForm(res,id,'',pageLanguage);
        }
        if(!['login','register'].includes(form.mode))return oauthFailure(res,400,pageLanguage,'invalidRequest');
        let account;
        try {
          if(form.mode==='register'){
            throttle('register',form.email);
            account=store.createAccount(form.email,form.password);
          } else {
            throttle('login',form.email);
            account=store.login(form.email,form.password);
          }
        } catch(e) {
          if(e instanceof CloudError&&[401,409,422].includes(e.status))return loginForm(res,id,'invalid',pageLanguage);
          throw e;
        }
        const grant=store.approveOAuth(id,account.id);
        const callback=new URL(grant.redirect);
        callback.searchParams.set('code',grant.code);
        callback.searchParams.set('iss',origin);
        if(grant.state)callback.searchParams.set('state',grant.state);
        res.writeHead(302,{'Location':callback.toString(),'Cache-Control':'no-store'});
        return res.end();
      }
      if(pathname===PREFIX+'/oauth/token'&&method==='POST'){
        const params=await parseBody(req);
        if(params.grant_type==='authorization_code')
          return json(res,200,store.exchange(params.code,params.client_id,params.redirect_uri,params.code_verifier,target(params.resource)));
        if(params.grant_type==='refresh_token')
          return json(res,200,store.refresh(params.refresh_token,params.client_id,target(params.resource),params.scope??null));
        throw new CloudError(400,'unsupported_grant_type');
      }
      if(pathname===PREFIX+'/oauth/revoke'&&method==='POST'){
        const p=await parseBody(req);store.revokeOAuth(p.token,p.client_id);return json(res,200,{});
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
          protocolVersion:protocolVersion(p.params?.protocolVersion),capabilities:{tools:{listChanged:false}},
          serverInfo:{name:'Lorvex Cloud MCP',version:'1.0.0'}}));
        if(p.method==='ping')return json(res,200,oauthReply(p.id,{}));
        if(p.method?.startsWith('notifications/')){res.writeHead(202);return res.end();}
        const requestedTool=p.method==='tools/call'?CLOUD_TOOLS.find(t=>t.name===p.params?.name):null;
        const requiredScopes=toolScopes(requestedTool);
        let session;
        try{
          session=store.authenticate(bearer(req),'lorvex.read');
          if(requestedTool?.writes)store.authenticate(bearer(req),'lorvex.write');
        }catch(e){
          const error=e.status===403?'insufficient_scope':'invalid_token';
          if(requestedTool)return json(res,200,oauthReply(p.id,toolAuthError(requiredScopes,error)));
          return json(res,e.status===403?403:401,{error:e.code},challenge(requiredScopes.join(' '),error));
        }
        if(p.method==='tools/list'){
          return json(res,200,oauthReply(p.id,{tools:CLOUD_TOOLS.map(({writes,...t})=>({...t,securitySchemes:toolSecurity({writes}),
            _meta:{...t._meta,securitySchemes:toolSecurity({writes})}}))}));
        }
        if(p.method==='tools/call'){
          try{
            const result=await invokeCloudTool(store,session.account_id,p.params?.name,p.params?.arguments??{});
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
        return json(res,200,store.push(accountId,body.envelopes,body.request_id,body.expected_versions));
      }
      if(method==='GET'&&pathname===PREFIX+'/v1/dashboard'){
        return json(res,200,store.summary(accountId));
      }
      if(method==='POST'&&pathname===PREFIX+'/v1/tools/call'){
        const p=await parseBody(req);
        if(CLOUD_TOOLS.find(t=>t.name===p.name)?.writes)store.authenticate(bearer(req),'lorvex.write');
        return json(res,200,await invokeCloudTool(store,accountId,p.name,p.arguments));
      }
      return json(res,404,{error:'not_found'});
    }catch(error){
      const status=error instanceof CloudError?error.status:500;
      if(status===500)console.error('SERVER_ERROR',String(error?.message||'error').slice(0,150));
      if(!res.headersSent){
        if(browserRoute)return oauthFailure(res,status,pageLanguage,status===429?'rateLimit':'invalidRequest');
        return json(res,status,{error:error instanceof CloudError?error.code:'internal_error'});
      }
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
