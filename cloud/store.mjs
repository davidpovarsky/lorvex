import { DatabaseSync } from 'node:sqlite';
import { randomUUID, randomBytes, createHash, scryptSync, timingSafeEqual } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const SCHEMA_VERSION=4;
const ENTITY_KINDS=new Set(('task list habit habit_completion habit_skip calendar_event calendar_series_cutover memory daily_review daily_briefing task_tag task_dependency task_calendar_event_link task_reminder task_checklist_item task_delegation tag preference working_hours calendar_source calendar_event_reminder habit_reminder habit_schedule habit_milestone habit_goal habit_streak').split(' '));
export const randomToken=()=>randomBytes(32).toString('base64url');
const hash=x=>createHash('sha256').update(String(x)).digest('hex');
const obj=x=>x!==null&&typeof x==='object'&&!Array.isArray(x);
const iso=()=>new Date().toISOString();
const validVersion=/^\d{13}_\d{4}_[0-9a-f]{16}$/;
const normalEmail=s=>typeof s==='string'?s.toLowerCase().trim():'';
export class CloudError extends Error {
  constructor(status,code){super(code);this.status=status;this.code=code;}
}
export function validateEnvelope(e) {
  if(!obj(e)||!ENTITY_KINDS.has(e.entity_type)||typeof e.entity_id!=='string'||
     !e.entity_id||e.entity_id.length>256||/[\x00-\x1f]/.test(e.entity_id)||
     !['upsert','delete'].includes(e.operation)||!validVersion.test(e.version)||
     !Number.isInteger(e.payload_schema_version)||e.payload_schema_version<1||
     e.payload_schema_version>104||typeof e.device_id!=='string'||
     e.device_id.length<3||e.device_id.length>128||typeof e.payload!=='string'||
     Buffer.byteLength(e.payload)>256*1024)throw new CloudError(422,'invalid_envelope');
  let payload;try{payload=JSON.parse(e.payload)}catch{throw new CloudError(422,'invalid_payload');}
  if(!obj(payload)||(payload.id&&payload.id!==e.entity_id))throw new CloudError(422,'invalid_payload');
  return e;
}
export class CloudStore {
  constructor(filename,{clock=Date.now}={}){
    this.clock=clock;
    if(filename!==':memory:')fs.mkdirSync(path.dirname(filename),{recursive:true,mode:0o700});
    this.db=new DatabaseSync(filename,{timeout:5000});
    this.db.exec('PRAGMA journal_mode=WAL;PRAGMA foreign_keys=ON;PRAGMA busy_timeout=5000;');
    this.db.exec([
      'CREATE TABLE IF NOT EXISTS accounts(id TEXT PRIMARY KEY,email TEXT UNIQUE NOT NULL,salt TEXT NOT NULL,verifier TEXT NOT NULL,created INTEGER NOT NULL,timezone TEXT NOT NULL DEFAULT "Asia/Jerusalem");',
      'CREATE TABLE IF NOT EXISTS oauth_clients(id TEXT PRIMARY KEY,redirects TEXT NOT NULL,name TEXT NOT NULL,created INTEGER NOT NULL);',
      'CREATE TABLE IF NOT EXISTS oauth_requests(id TEXT PRIMARY KEY,client_id TEXT NOT NULL,redirect TEXT NOT NULL,challenge TEXT NOT NULL,state TEXT NOT NULL,expires INTEGER NOT NULL);',
      'CREATE TABLE IF NOT EXISTS oauth_codes(hash TEXT PRIMARY KEY,account_id TEXT NOT NULL,client_id TEXT NOT NULL,redirect TEXT NOT NULL,challenge TEXT NOT NULL,expires INTEGER NOT NULL);',
      'CREATE TABLE IF NOT EXISTS tokens(access_hash TEXT PRIMARY KEY,refresh_hash TEXT UNIQUE NOT NULL,account_id TEXT NOT NULL,client_id TEXT,scopes TEXT NOT NULL,access_exp INTEGER NOT NULL,refresh_exp INTEGER NOT NULL,created INTEGER NOT NULL);',
      'CREATE TABLE IF NOT EXISTS entities(account_id TEXT NOT NULL,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,version TEXT NOT NULL,operation TEXT NOT NULL,payload TEXT NOT NULL,payload_schema_version INTEGER NOT NULL,device_id TEXT NOT NULL,changed INTEGER NOT NULL,PRIMARY KEY(account_id,entity_type,entity_id));',
      'CREATE TABLE IF NOT EXISTS changes(seq INTEGER PRIMARY KEY AUTOINCREMENT,account_id TEXT NOT NULL,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,version TEXT NOT NULL,operation TEXT NOT NULL,payload TEXT NOT NULL,payload_schema_version INTEGER NOT NULL,device_id TEXT NOT NULL,created INTEGER NOT NULL);',
      'CREATE INDEX IF NOT EXISTS idx_cloud_changes ON changes(account_id,seq);',
      'CREATE TABLE IF NOT EXISTS receipts(account_id TEXT NOT NULL,request_id TEXT NOT NULL,response TEXT NOT NULL,created INTEGER NOT NULL,PRIMARY KEY(account_id,request_id));',
      'CREATE TABLE IF NOT EXISTS audit(seq INTEGER PRIMARY KEY AUTOINCREMENT,account_id TEXT NOT NULL,action TEXT NOT NULL,entity_id TEXT,created INTEGER NOT NULL);'
    ].join('\n'));
    this.previousPhysical=0;this.counter=0;
  }
  close(){this.db.close();}
  get(sql,...args){return this.db.prepare(sql).get(...args);}
  all(sql,...args){return this.db.prepare(sql).all(...args);}
  run(sql,...args){return this.db.prepare(sql).run(...args);}
  tx(fn){this.db.exec('BEGIN IMMEDIATE');try{const result=fn();this.db.exec('COMMIT');return result;}catch(err){this.db.exec('ROLLBACK');throw err;}}
  account(email){return this.get('SELECT * FROM accounts WHERE email=?',normalEmail(email));}
  publicAccount(record){return {id:record.id,email:record.email,timezone:record.timezone};}
  createAccount(email,password){
    const normalized=normalEmail(email);
    if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized)||normalized.length>250||
       typeof password!=='string'||password.length<12||password.length>256)throw new CloudError(422,'invalid_signup');
    if(this.account(normalized))throw new CloudError(409,'account_exists');
    const id=randomUUID(),salt=randomBytes(24).toString('base64url');
    const verifier=scryptSync(password,salt,64,{N:16384,r:8,p:1}).toString('base64url');
    this.run('INSERT INTO accounts(id,email,salt,verifier,created) VALUES(?,?,?,?,?)',id,normalized,salt,verifier,this.clock());
    return this.get('SELECT * FROM accounts WHERE id=?',id);
  }
  login(email,password){
    const a=this.account(email);
    const calculated=scryptSync(typeof password==='string'?password:'',a?.salt||'Lorvex-nonexistent-user-salt',64,{N:16384,r:8,p:1});
    const expected=Buffer.from(a?.verifier||Buffer.alloc(64).toString('base64url'),'base64url');
    if(!a||!timingSafeEqual(calculated,expected))throw new CloudError(401,'invalid_credentials');
    return a;
  }
  client(id){return this.get('SELECT * FROM oauth_clients WHERE id=?',id);}
  registerClient(redirects,name){
    if(!Array.isArray(redirects)||redirects.length===0||redirects.length>5||
       redirects.some(x=>typeof x!=='string'||x.length>1000))throw new CloudError(400,'invalid_redirect_uri');
    const id=randomToken();
    this.run('INSERT INTO oauth_clients(id,redirects,name,created) VALUES(?,?,?,?)',id,JSON.stringify(redirects),String(name||'ChatGPT').slice(0,120),this.clock());
    return {client_id:id,client_id_issued_at:Math.floor(this.clock()/1000),redirect_uris:redirects,token_endpoint_auth_method:'none',grant_types:['authorization_code','refresh_token'],response_types:['code']};
  }
  beginOAuth(clientId,redirect,challenge,state){
    const client=this.client(clientId);
    if(!client||!JSON.parse(client.redirects).includes(redirect)||typeof challenge!=='string'||
       challenge.length<43||challenge.length>120||typeof state!=='string'||state.length>500)throw new CloudError(400,'invalid_oauth_request');
    const id=randomToken();
    this.run('INSERT INTO oauth_requests(id,client_id,redirect,challenge,state,expires) VALUES(?,?,?,?,?,?)',id,clientId,redirect,challenge,state,this.clock()+600000);
    return id;
  }
  oauthRequest(id){return this.get('SELECT * FROM oauth_requests WHERE id=? AND expires>?',id,this.clock());}
  approveOAuth(requestId,accountId){
    const req=this.oauthRequest(requestId);
    if(!req)throw new CloudError(400,'expired_oauth_request');
    const code=randomToken();
    this.tx(()=>{
      this.run('DELETE FROM oauth_requests WHERE id=?',requestId);
      this.run('INSERT INTO oauth_codes(hash,account_id,client_id,redirect,challenge,expires) VALUES(?,?,?,?,?,?)',hash(code),accountId,req.client_id,req.redirect,req.challenge,this.clock()+600000);
    });
    return {code,redirect:req.redirect,state:req.state};
  }
  issueToken(accountId,clientId=null,scopes='lorvex.read lorvex.write offline_access'){
    const access=randomToken(),refresh=randomToken(),at=this.clock();
    this.run('INSERT INTO tokens(access_hash,refresh_hash,account_id,client_id,scopes,access_exp,refresh_exp,created) VALUES(?,?,?,?,?,?,?,?)',hash(access),hash(refresh),accountId,clientId,scopes,at+3600000,at+2592000000,at);
    return {access_token:access,refresh_token:refresh,token_type:'Bearer',expires_in:3600,scope:scopes};
  }
  exchange(code,clientId,redirect,verifier){
    if(typeof verifier!=='string'||verifier.length<43||verifier.length>128)throw new CloudError(400,'invalid_grant');
    const record=this.get('SELECT * FROM oauth_codes WHERE hash=?',hash(code||''));
    const challenge=createHash('sha256').update(verifier).digest('base64url');
    if(!record||record.expires<=this.clock()||record.client_id!==clientId||record.redirect!==redirect||record.challenge!==challenge)throw new CloudError(400,'invalid_grant');
    return this.tx(()=>{this.run('DELETE FROM oauth_codes WHERE hash=?',hash(code));return this.issueToken(record.account_id,clientId);});
  }
  refresh(token,clientId=null){
    const record=this.get('SELECT * FROM tokens WHERE refresh_hash=?',hash(token||''));
    if(!record||record.refresh_exp<=this.clock()||record.client_id!==(clientId||null))throw new CloudError(400,'invalid_grant');
    return this.tx(()=>{this.run('DELETE FROM tokens WHERE refresh_hash=?',hash(token));return this.issueToken(record.account_id,clientId,record.scopes);});
  }
  authenticate(token,scope='lorvex.read'){
    if(typeof token!=='string'||token.length<25)throw new CloudError(401,'unauthorized');
    const record=this.get('SELECT * FROM tokens WHERE access_hash=? AND access_exp>?',hash(token),this.clock());
    if(!record||!record.scopes.split(' ').includes(scope))throw new CloudError(401,'unauthorized');
    return record;
  }
  revoke(token){this.run('DELETE FROM tokens WHERE access_hash=?',hash(token||''));}
  wire(row){return {entity_type:row.entity_type,entity_id:row.entity_id,operation:row.operation,version:row.version,payload_schema_version:row.payload_schema_version,payload:row.payload,device_id:row.device_id};}
  receive(accountId,e){
    validateEnvelope(e);
    const old=this.get('SELECT * FROM entities WHERE account_id=? AND entity_type=? AND entity_id=?',accountId,e.entity_type,e.entity_id);
    if(old && (old.version>e.version||(old.version===e.version&&old.payload>=e.payload))){
      if(old.version===e.version&&old.payload===e.payload&&old.operation===e.operation)return {status:'duplicate'};
      return {status:'stale',winner:this.wire(old)};
    }
    this.run('INSERT INTO entities(account_id,entity_type,entity_id,version,operation,payload,payload_schema_version,device_id,changed) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(account_id,entity_type,entity_id) DO UPDATE SET version=excluded.version,operation=excluded.operation,payload=excluded.payload,payload_schema_version=excluded.payload_schema_version,device_id=excluded.device_id,changed=excluded.changed',accountId,e.entity_type,e.entity_id,e.version,e.operation,e.payload,e.payload_schema_version,e.device_id,this.clock());
    const result=this.run('INSERT INTO changes(account_id,entity_type,entity_id,version,operation,payload,payload_schema_version,device_id,created) VALUES(?,?,?,?,?,?,?,?,?)',accountId,e.entity_type,e.entity_id,e.version,e.operation,e.payload,e.payload_schema_version,e.device_id,this.clock());
    return {status:'accepted',seq:Number(result.lastInsertRowid)};
  }
  push(accountId,items,requestId){
    if(!Array.isArray(items)||items.length<1||items.length>60||typeof requestId!=='string'||!/^[a-zA-Z0-9_-]{12,128}$/.test(requestId))throw new CloudError(400,'invalid_batch');
    const prior=this.get('SELECT response FROM receipts WHERE account_id=? AND request_id=?',accountId,requestId);
    if(prior)return JSON.parse(prior.response);
    items.forEach(validateEnvelope);
    return this.tx(()=>{
      const results=items.map(e=>this.receive(accountId,e)),response={results};
      this.run('INSERT INTO receipts(account_id,request_id,response,created) VALUES(?,?,?,?)',accountId,requestId,JSON.stringify(response),this.clock());
      return response;
    });
  }
  changes(accountId,cursor=0,limit=100){
    if(!Number.isSafeInteger(cursor)||cursor<0||!Number.isInteger(limit)||limit<1||limit>200)throw new CloudError(400,'invalid_cursor');
    const records=this.all('SELECT * FROM changes WHERE account_id=? AND seq>? ORDER BY seq LIMIT ?',accountId,cursor,limit+1);
    const page=records.slice(0,limit);
    return {envelopes:page.map(e=>this.wire(e)),cursor:page.length?Number(page.at(-1).seq):cursor,has_more:records.length>limit};
  }
  entity(accountId,kind,id){
    const record=this.get('SELECT * FROM entities WHERE account_id=? AND entity_type=? AND entity_id=?',accountId,kind,id);
    return record && record.operation!=='delete'?{...JSON.parse(record.payload),id:record.entity_id,version:record.version}:null;
  }
  list(accountId,kind){
    return this.all('SELECT * FROM entities WHERE account_id=? AND entity_type=? AND operation=? ORDER BY changed DESC',accountId,kind,'upsert').map(row=>({...JSON.parse(row.payload),id:row.entity_id,version:row.version}));
  }
  nextHlc(accountId){
    const previous=this.get('SELECT version FROM entities WHERE account_id=? ORDER BY version DESC LIMIT 1',accountId)?.version;
    let ms=Math.max(this.clock(),previous?Number(previous.slice(0,13)):0);
    if(ms===this.previousPhysical)this.counter++;else{this.counter=0;this.previousPhysical=ms;}
    if(previous && previous.slice(0,13)===String(ms))this.counter=Math.max(this.counter,Number(previous.slice(14,18))+1);
    if(this.counter>=10000){ms++;this.counter=0;this.previousPhysical=ms;}
    return String(ms).padStart(13,'0')+'_'+String(this.counter).padStart(4,'0')+'_fffffffffffffffe';
  }
  writeEntity(accountId,kind,id,payload,operation='upsert',requestId=null,action='cloud_write'){
    if(!ENTITY_KINDS.has(kind)||!obj(payload))throw new CloudError(422,'invalid_entity');
    if(requestId){const cached=this.get('SELECT response FROM receipts WHERE account_id=? AND request_id=?',accountId,requestId);if(cached)return JSON.parse(cached.response);}
    const version=this.nextHlc(accountId);
    const entity={...payload,id,version,updated_at:iso()};
    const wire={entity_type:kind,entity_id:id,operation,version,payload_schema_version:SCHEMA_VERSION,payload:JSON.stringify(entity),device_id:'lorvex-cloud-server'};
    return this.tx(()=>{
      const status=this.receive(accountId,wire);
      const answer={id,entity,version,...status};
      this.run('INSERT INTO audit(account_id,action,entity_id,created) VALUES(?,?,?,?)',accountId,action,id,this.clock());
      if(requestId)this.run('INSERT INTO receipts(account_id,request_id,response,created) VALUES(?,?,?,?)',accountId,requestId,JSON.stringify(answer),this.clock());
      return answer;
    });
  }
  summary(accountId){
    const tasks=this.list(accountId,'task');
    const byStatus={},byPriority={'1':0,'2':0,'3':0};
    for(const t of tasks){
      byStatus[t.status||'open']=(byStatus[t.status||'open']||0)+1;
      const k=String(t.priority);
      if(k in byPriority)byPriority[k]++;
    }
    return {totalMatching:tasks.length,sampleSize:tasks.length,partial:false,open:tasks.filter(t=>!['completed','cancelled'].includes(t.status)).length,completed:tasks.filter(t=>t.status==='completed').length,byStatus,byPriority};
  }
}
