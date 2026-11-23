import {spawn} from 'node:child_process';
import {CloudError,validateEnvelope} from './store.mjs';

const MAX_BYTES=32*1024*1024;
const MAX_ENTITIES=50000;

// This boundary calls the existing Swift workflow and sync engine. It contains
// no recurrence rules and creates no second persistent database.
export function runCanonicalProcess(input,{
  executable=process.env.LORVEX_CANONICAL_CORE_EXECUTABLE,
  timeoutMs=15000,maxBytes=MAX_BYTES
}={}){
  if(!executable)throw new CloudError(503,'recurring_transition_requires_canonical_core');
  const encoded=JSON.stringify(input);
  if(Buffer.byteLength(encoded)>maxBytes)throw new CloudError(413,'canonical_snapshot_too_large');
  return new Promise((resolve,reject)=>{
    let settled=false,stdout=[],size=0,stderrSize=0,timer;
    const child=spawn(executable,[],{stdio:['pipe','pipe','pipe'],env:{
      PATH:process.env.PATH,LANG:'C.UTF-8',TZ:input.timezone,
      ...(process.env.LD_LIBRARY_PATH?{LD_LIBRARY_PATH:process.env.LD_LIBRARY_PATH}:{})
    }});
    const finish=(error,value)=>{
      if(settled)return;
      settled=true;clearTimeout(timer);
      if(error){child.kill('SIGKILL');reject(error);}else resolve(value);
    };
    timer=setTimeout(()=>finish(new CloudError(503,'canonical_transition_timeout')),timeoutMs);
    child.on('error',()=>finish(new CloudError(503,'canonical_core_unavailable')));
    child.stdin.on('error',()=>{});
    child.stdout.on('data',chunk=>{
      if(settled)return;
      size+=chunk.length;
      if(size>maxBytes)return finish(new CloudError(502,'canonical_output_too_large'));
      stdout.push(chunk);
    });
    child.stderr.on('data',chunk=>{
      stderrSize+=chunk.length;
      if(stderrSize>65536)finish(new CloudError(502,'canonical_error_output_too_large'));
    });
    child.on('close',code=>{
      if(settled)return;
      if(code!==0)return finish(new CloudError(422,'canonical_transition_rejected'));
      try{finish(null,JSON.parse(Buffer.concat(stdout).toString('utf8')));}
      catch{finish(new CloudError(502,'invalid_canonical_response'));}
    });
    child.stdin.end(encoded);
  });
}

function receipt(store,accountId,requestId,action,id){
  if(!requestId)return null;
  const row=store.get('SELECT response FROM receipts WHERE account_id=? AND request_id=?',accountId,requestId);
  if(!row)return null;
  const prior=JSON.parse(row.response);
  if(prior.canonical_tool!==action||prior.entity_id!==id||!prior.entity)
    throw new CloudError(409,'idempotency_conflict');
  return prior.entity;
}
const checkpoint=(store,accountId)=>Number(store.get('SELECT coalesce(max(seq),0) AS seq FROM changes WHERE account_id=?',accountId).seq);
const retry=Symbol('retry_canonical_snapshot');

export async function executeCanonicalTransition(store,accountId,action,args,{execute=runCanonicalProcess}={}){
  const requestId=args.request_id??null;
  for(let attempt=0;attempt<3;attempt++){
    const prior=receipt(store,accountId,requestId,action,args.id);
    if(prior)return prior;
    const snapshot=store.tx(()=>{
      const account=store.get('SELECT timezone FROM accounts WHERE id=?',accountId);
      if(!account)throw new CloudError(404,'account_not_found');
      if(!store.entity(accountId,'task',args.id))throw new CloudError(404,'task_not_found');
      const rows=store.all('SELECT * FROM entities WHERE account_id=? ORDER BY entity_type,entity_id LIMIT ?',accountId,MAX_ENTITIES+1);
      if(rows.length>MAX_ENTITIES)throw new CloudError(413,'canonical_snapshot_too_large');
      return {seq:checkpoint(store,accountId),input:{
        envelopes:rows.map(row=>store.wire(row)),action,arguments:{id:args.id},
        device_id:'lorvex-cloud-server',now:new Date(store.clock()).toISOString(),timezone:account.timezone
      }};
    });
    const result=await execute(snapshot.input);
    if(!result||!Array.isArray(result.envelopes)||typeof result.changed!=='boolean'||
       result.envelopes.length>MAX_ENTITIES||!result.result?.task||result.result.task.id!==args.id)
      throw new CloudError(502,'invalid_canonical_response');
    const seen=new Set();
    for(const envelope of result.envelopes){
      validateEnvelope(envelope);
      const key=envelope.entity_type+':'+envelope.entity_id;
      if(seen.has(key)||envelope.payload_schema_version!==4||
         JSON.parse(envelope.payload).version!==envelope.version)
        throw new CloudError(502,'invalid_canonical_envelope');
      seen.add(key);
    }
    try{
      return store.tx(()=>{
        const cached=receipt(store,accountId,requestId,action,args.id);
        if(cached)return cached;
        if(checkpoint(store,accountId)!==snapshot.seq)throw retry;
        for(const envelope of result.envelopes){
          const outcome=store.receive(accountId,envelope);
          if(outcome.status==='stale')throw new CloudError(409,'canonical_result_stale');
        }
        const entity=store.entity(accountId,'task',args.id);
        if(!entity)throw new CloudError(502,'canonical_task_missing');
        store.run('INSERT INTO audit(account_id,action,entity_id,created) VALUES(?,?,?,?)',accountId,action,args.id,store.clock());
        if(requestId)store.run('INSERT INTO receipts(account_id,request_id,response,created) VALUES(?,?,?,?)',accountId,requestId,
          JSON.stringify({canonical_tool:action,entity_id:args.id,entity}),store.clock());
        return entity;
      });
    }catch(error){if(error!==retry)throw error;}
  }
  throw new CloudError(409,'canonical_snapshot_changed_retry');
}
