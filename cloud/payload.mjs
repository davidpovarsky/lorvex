import {readFileSync,existsSync} from 'node:fs';

// The sole schema authority is Lorvex's existing versioned payload contract.
// Deployment copies this exact file beside the service, never a hand-written schema.
const candidates=[process.env.LORVEX_CLOUD_CONTRACT_PATH,
  new URL('../schema/sync_payload/004.json',import.meta.url),
  new URL('./sync-payload-004.json',import.meta.url)].filter(Boolean);
const contractPath=candidates.find(p=>existsSync(p));
if(!contractPath)throw new Error('Missing canonical Lorvex sync payload contract 004');
export const payloadContract=JSON.parse(readFileSync(contractPath,'utf8'));
export const entityKinds=new Set(Object.keys(payloadContract.entities).filter(k=>k!=='ai_changelog'));

export const taskGroups={
 content_version:['title','body','raw_input','ai_notes','list_id','priority'],
 schedule_version:['due_date','estimated_minutes','recurrence','spawned_from','spawned_from_version','recurrence_group_id','recurrence_instance_key','canonical_occurrence_date','last_deferred_at','last_defer_reason','planned_date','planned_start_minutes','planned_end_minutes','available_from','defer_count','recurrence_exceptions'],
 lifecycle_version:['status','completed_at','recurrence_rollover_state','recurrence_successor_id'],
 archive_version:['archived_at']
};

export function projectServerPayload(kind,input,id,version,previous=null,operation='upsert'){
  if(operation==='delete')return {version};
  const spec=payloadContract.entities[kind];
  if(!spec)throw new Error('Unknown canonical entity '+kind);
  const value={...input,version};
  if('id' in spec.fields)value.id=id;
  if('updated_at' in spec.fields)value.updated_at=new Date().toISOString();
  for(const key of spec.operations.upsert.required_keys){
    if(value[key]!==undefined)continue;
    const field=spec.fields[key];
    if(field.types.includes('null'))value[key]=null;
    else if(field.format==='hlc')value[key]=version;
    else if(key==='recurrence_rollover_state')value[key]='none';
  }
  if(kind==='task')for(const [clock,keys] of Object.entries(taskGroups)){
    if(!previous || !previous[clock] || keys.some(k=>JSON.stringify(previous[k]??null)!==JSON.stringify(value[k]??null)))value[clock]=version;
  }
  if(kind==='calendar_event'&&!previous){value.content_version=version;value.recurrence_topology_version=version;}
  const output=Object.fromEntries(Object.entries(value).filter(([key])=>key in spec.fields));
  for(const key of spec.operations.upsert.required_keys){
    const field=spec.fields[key],v=output[key];
    const type=v===null?'null':Array.isArray(v)?'array':Number.isInteger(v)?'integer':typeof v;
    if(v===undefined||!field.types.includes(type))throw new Error('Invalid canonical '+kind+'.'+key);
    if(v!==null&&field.enum&&!field.enum.includes(v))throw new Error('Invalid canonical enum '+kind+'.'+key);
    if(typeof v==='number'&&((field.minimum!==undefined&&v<field.minimum)||(field.maximum!==undefined&&v>field.maximum)))throw new Error('Invalid canonical range '+kind+'.'+key);
  }
  return output;
}
