import { randomUUID } from 'node:crypto';
import { CloudError } from './store.mjs';
import {executeCanonicalTransition} from './canonical.mjs';

const field=(type,more={})=>({type,...more});
const str=max=>field('string',{maxLength:max,minLength:1});
const nullable=max=>field('string',{maxLength:max});
const date=str(10);
const int=(min,max)=>field('integer',{minimum:min,maximum:max});
const commonID={id:str(128)};
const definitions=[
  ['list_tasks','List tasks with optional filters and pagination',false,{status:field('string',{enum:['all','open','actionable','completed','cancelled','someday']}),list_id:str(128),priority:int(1,3),text:nullable(250),limit:int(1,200),offset:int(0,50000)},[]],
  ['get_task','Read a task by its exact ID',false,commonID,['id']],
  ['search_tasks','Search tasks by title, text and notes',false,{query:str(250),status:field('string',{enum:['all','open','completed','cancelled','someday']}),limit:int(1,200)},['query']],
  ['get_summary','Task status and priority dashboard',false,{},[]],
  ['get_today','Today actionable tasks and schedule',false,{},[]],
  ['list_lists','Browse task lists',false,{},[]],
  ['get_list_detail','Read list with its tasks',false,{...commonID,limit:int(1,200)},['id']],
  ['list_events','List calendar events in inclusive day range',false,{from:str(10),to:str(10)},['from','to']],
  ['get_event','Read one event',false,commonID,['id']],
  ['list_habits','Read habits and daily completions',false,{date:str(10)},[]],
  ['create_task','Create a task in Lorvex Cloud',true,{title:str(500),notes:nullable(8000),priority:int(1,3),list_id:str(128),due_date:date,planned_date:date,estimated_minutes:int(1,1440),tags:field('array',{maxItems:50,items:str(80)}),request_id:str(128)},['title']],
  ['update_task','Update specified task fields',true,{...commonID,title:str(500),notes:nullable(8000),priority:int(1,3),due_date:date,planned_date:date,clear_due:field('boolean'),clear_planned:field('boolean'),estimated_minutes:int(1,1440),tags:field('array',{maxItems:50,items:str(80)}),request_id:str(128)},['id']],
  ['complete_task','Complete a task',true,{...commonID,request_id:str(128)},['id']],
  ['reopen_task','Reopen a task',true,{...commonID,request_id:str(128)},['id']],
  ['start_task','Start a task',true,{...commonID,request_id:str(128)},['id']],
  ['pause_task','Pause a task',true,{...commonID,request_id:str(128)},['id']],
  ['cancel_task','Cancel a task',true,{...commonID,request_id:str(128)},['id']],
  ['plan_task','Schedule a task for a date',true,{...commonID,date:str(10),request_id:str(128)},['id','date']],
  ['create_event','Create a Lorvex calendar event',true,{title:str(500),start_date:str(10),end_date:str(10),start_time:str(8),end_time:str(8),all_day:field('boolean'),location:nullable(500),notes:nullable(8000),request_id:str(128)},['title','start_date']],
  ['create_list','Create a Lorvex task list',true,{name:str(150),description:nullable(3000),request_id:str(128)},['name']],
  ['complete_habit','Record a habit completion on a date',true,{...commonID,date:str(10),request_id:str(128)},['id','date']],
  ['uncomplete_habit','Clear a habit completion on a date',true,{...commonID,date:str(10),request_id:str(128)},['id','date']]
];
export const CLOUD_TOOLS=definitions.map(([name,description,writes,properties,required])=>({
  name,description,inputSchema:{type:'object',properties,required,additionalProperties:false},
  annotations:{readOnlyHint:!writes,destructiveHint:writes&&name==='cancel_task',
               openWorldHint:false},writes
}));
export function validateTool(name,args) {
  const spec=CLOUD_TOOLS.find(t=>t.name===name);
  if(!spec||!args||typeof args!=='object'||Array.isArray(args)||
     JSON.stringify(args).length>35000)throw new CloudError(422,'invalid_tool');
  const props=spec.inputSchema.properties;
  for(const k of spec.inputSchema.required){
    if(!(k in args))throw new CloudError(422,'missing_required_'+k);
  }
  for(const [key,value] of Object.entries(args)) {
    if(!(key in props))throw new CloudError(422,'unknown_argument_'+key);
    const shape=props[key];
    if(shape.type==='string') {
      if(typeof value!=='string'||(shape.minLength&&value.length<shape.minLength)||
         value.length>shape.maxLength||(shape.enum&&!shape.enum.includes(value)))
        throw new CloudError(422,'invalid_argument_'+key);
    } else if(shape.type==='integer') {
      if(!Number.isInteger(value)||value<shape.minimum||value>shape.maximum)throw new CloudError(422,'invalid_argument_'+key);
    } else if(shape.type==='boolean'){
      if(typeof value!=='boolean')throw new CloudError(422,'invalid_argument_'+key);
    } else if(shape.type==='array'){
      if(!Array.isArray(value)||value.length>shape.maxItems||
         value.some(x=>typeof x!=='string'||x.length>shape.items.maxLength))
        throw new CloudError(422,'invalid_argument_'+key);
    }
  }
  return spec;
}
const taskFor=t=>({...t,notes:t.body??t.notes??null,priority:t.priority??2,dueDate:t.due_date??null,plannedDate:t.planned_date??null});
const dayPattern=/^\d{4}-\d{2}-\d{2}$/;
function validDay(day) {
  if(typeof day!=='string'||!dayPattern.test(day)||Number.isNaN(Date.parse(day+'T00:00:00Z'))||new Date(day+'T00:00:00Z').toISOString().slice(0,10)!==day)throw new CloudError(422,'invalid_date');
  return day;
}
function accountDay(store,accountId){
  const account=store.get('SELECT timezone FROM accounts WHERE id=?',accountId);
  return new Intl.DateTimeFormat('en-CA',{timeZone:account?.timezone||'Asia/Jerusalem',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date(store.clock()));
}
const now=()=>new Date().toISOString().replace(/\.\d{3}Z$/,'.000Z');
const paginate=(list,args)=>{const offset=args.offset??0,limit=args.limit??100;return {
  tasks:list.slice(offset,offset+limit).map(taskFor),totalMatching:list.length,
  truncated:list.length>offset+limit,nextOffset:list.length>offset+limit?offset+limit:null}};
export function invokeCloudTool(store,accountId,name,args={}) {
  const spec=validateTool(name,args);
  const hydrateTask=t=>{
    const links=store.list(accountId,'task_tag').filter(l=>l.task_id===t.id);
    const ids=new Set(links.map(l=>l.tag_id));
    return {...t,tags:store.list(accountId,'tag').filter(t=>ids.has(t.id)).map(t=>t.display_name)};
  };
  const tasks=()=>store.list(accountId,'task').map(hydrateTask);
  const lists=()=>store.list(accountId,'list');
  const events=()=>store.list(accountId,'calendar_event');
  const habits=()=>store.list(accountId,'habit');
  const requestId=args.request_id??null;
  const writeTask=(id,payload)=>store.tx(()=>{
    if(requestId){const cached=store.get('SELECT response FROM receipts WHERE account_id=? AND request_id=?',accountId,requestId);if(cached)return JSON.parse(cached.response).entity;}
    const result=store.writeEntity(accountId,'task',id,payload,'upsert',requestId,name).entity;
    if(args.tags!==undefined){
      const wanted=new Set();
      for(const label of [...new Set(args.tags.map(t=>t.trim()).filter(Boolean))]){
        let tag=store.list(accountId,'tag').find(t=>t.display_name.toLowerCase()===label.toLowerCase());
        if(!tag){const tagId=randomUUID();tag=store.writeEntity(accountId,'tag',tagId,{id:tagId,display_name:label,color:null,created_at:now(),updated_at:now()},'upsert',null,'tag_task').entity;}
        wanted.add(tag.id);
        const linkId=id+':'+tag.id;
        if(!store.entity(accountId,'task_tag',linkId))store.writeEntity(accountId,'task_tag',linkId,{task_id:id,tag_id:tag.id,created_at:now()},'upsert',null,'tag_task');
      }
      for(const link of store.list(accountId,'task_tag').filter(l=>l.task_id===id&&!wanted.has(l.tag_id)))store.writeEntity(accountId,'task_tag',link.id,{},'delete',null,'untag_task');
    }
    return result;
  });
  let answer;
  if(name==='list_tasks'||name==='search_tasks'){
    let list=tasks();
    if(args.status&&args.status!=='all')list=list.filter(t=>
      args.status==='actionable'? !['completed','cancelled','someday'].includes(t.status) : t.status===args.status);
    if(args.list_id)list=list.filter(t=>t.list_id===args.list_id);
    if(args.priority)list=list.filter(t=>t.priority===args.priority);
    const term=(name==='search_tasks'?args.query:args.text)?.trim().toLowerCase();
    if(term)list=list.filter(t=>[t.title,t.body,t.notes].some(x=>typeof x==='string'&&x.toLowerCase().includes(term)));
    answer=paginate(list,args);
  } else if(name==='get_task'){
    const t=store.entity(accountId,'task',args.id);
    if(!t)throw new CloudError(404,'task_not_found');
    answer={task:taskFor(hydrateTask(t))};
  } else if(name==='get_summary') {
    answer=store.summary(accountId);
  } else if(name==='get_today'){
    const date=accountDay(store,accountId);
    const relevant=tasks().filter(t=>!['completed','cancelled'].includes(t.status)&&(t.planned_date===date||t.due_date===date));
    answer={summary:String(relevant.length)+' tasks scheduled today',briefing:null,logicalDay:date,tasks:relevant.map(taskFor)};
  } else if(name==='list_lists'){
    answer={lists:lists()};
  } else if(name==='get_list_detail'){
    const list=store.entity(accountId,'list',args.id);
    if(!list)throw new CloudError(404,'list_not_found');
    answer={list,...paginate(tasks().filter(t=>t.list_id===args.id),{limit:args.limit??100})};
  } else if(name==='list_events'){
    const from=validDay(args.from),to=validDay(args.to);
    if(from>to)throw new CloudError(422,'invalid_date_range');
    answer={events:events().filter(e=>e.start_date<=to&&(e.end_date??e.start_date)>=from),truncated:false};
  } else if(name==='get_event'){
    const event=store.entity(accountId,'calendar_event',args.id);
    if(!event)throw new CloudError(404,'event_not_found');
    answer={event};
  } else if(name==='list_habits'){
    const day=validDay(args.date??accountDay(store,accountId));
    const records=store.list(accountId,'habit_completion');
    answer={date:day,habits:habits().map(h=>({...h,completed:records.some(c=>c.habit_id===h.id&&(c.completed_date??c.date)===day)}))};
  } else if(name==='create_task'){
    const id=randomUUID(),date=now();
    if(!args.title.trim())throw new CloudError(422,'invalid_argument_title');
    if(args.list_id&&args.list_id!=='inbox'&&!store.entity(accountId,'list',args.list_id))throw new CloudError(404,'list_not_found');
    if(args.due_date)validDay(args.due_date);
    if(args.planned_date)validDay(args.planned_date);
    const entity={
      id,title:args.title.trim(),body:args.notes??null,status:'open',
      list_id:args.list_id??'inbox',priority:args.priority??2,
      due_date:args.due_date??null,planned_date:args.planned_date??null,
      estimated_minutes:args.estimated_minutes??null,tags:args.tags??[],
      defer_count:0,created_at:date,updated_at:date
    };
    answer={task:taskFor(hydrateTask(writeTask(id,entity)))};
  } else if(name==='update_task'||['complete_task','reopen_task','start_task','pause_task','cancel_task','plan_task'].includes(name)){
    const old=store.entity(accountId,'task',args.id);
    if(!old)throw new CloudError(404,'task_not_found');
    if((old.recurrence||(old.recurrence_rollover_state&&old.recurrence_rollover_state!=='none')||old.recurrence_successor_id)&&
       ['complete_task','reopen_task','start_task','pause_task','cancel_task'].includes(name)){
      if(!process.env.LORVEX_CANONICAL_CORE_EXECUTABLE)throw new CloudError(503,'recurring_transition_requires_canonical_core');
      return executeCanonicalTransition(store,accountId,name,args).then(task=>({
        content:[{type:'text',text:JSON.stringify({task:taskFor(hydrateTask(task))})}],isError:false
      }));
    }
    const patch={};
    if(name==='update_task'){
      for(const key of ['title','priority','estimated_minutes'])if(key in args)patch[key]=args[key];
      if('notes' in args)patch.body=args.notes;
      if('tags' in args)patch.tags=args.tags;
      if(args.clear_due)patch.due_date=null;
      else if(args.due_date){validDay(args.due_date);patch.due_date=args.due_date;}
      if(args.clear_planned)patch.planned_date=null;
      else if(args.planned_date){validDay(args.planned_date);patch.planned_date=args.planned_date;}
    }
    if(name==='complete_task')Object.assign(patch,{status:'completed',completed_at:now()});
    if(name==='reopen_task')Object.assign(patch,{status:'open',completed_at:null,cancelled_at:null});
    if(name==='cancel_task')Object.assign(patch,{status:'cancelled',completed_at:null});
    if(name==='start_task')Object.assign(patch,{status:'in_progress'});
    if(name==='pause_task')Object.assign(patch,{status:'open'});
    if(name==='plan_task'){patch.planned_date=validDay(args.date);}
    answer={task:taskFor(hydrateTask(writeTask(args.id,{...old,...patch})))};
  } else if(name==='create_list'){
    const id=randomUUID(),date=now();
    const entity={id,name:args.name.trim(),description:args.description??null,position:lists().length,created_at:date,updated_at:date};
    answer={list:store.writeEntity(accountId,'list',id,entity,'upsert',requestId,name).entity};
  } else if(name==='create_event'){
    const start=validDay(args.start_date),end=validDay(args.end_date??args.start_date);
    for(const t of [args.start_time,args.end_time])if(t!==undefined&&!/^([01]\d|2[0-3]):[0-5]\d$/.test(t))throw new CloudError(422,'invalid_time');
    if(end<start)throw new CloudError(422,'invalid_date_range');
    const id=randomUUID(),date=now();
    const entity={
      id,title:args.title,start_date:start,end_date:end,start_time:args.start_time??null,
      end_time:args.end_time??null,all_day:args.all_day??false,
      location:args.location??null,description:args.notes??null,event_type:'event',
      recurrence:null,created_at:date,updated_at:date
    };
    answer={event:store.writeEntity(accountId,'calendar_event',id,entity,'upsert',requestId,name).entity};
  } else if(name==='complete_habit'||name==='uncomplete_habit'){
    const habit=store.entity(accountId,'habit',args.id);
    if(!habit)throw new CloudError(404,'habit_not_found');
    const day=validDay(args.date),id=args.id+':'+day;
    if(name==='complete_habit'){
      const row={habit_id:args.id,completed_date:day,value:1,note:null,created_at:now(),updated_at:now()};
      store.writeEntity(accountId,'habit_completion',id,row,'upsert',requestId,name);
    } else {
      store.writeEntity(accountId,'habit_completion',id,{habit_id:args.id,completed_date:day},'delete',requestId,name);
    }
    answer={habits:habits()};
  } else throw new CloudError(404,'unknown_tool');
  return {content:[{type:'text',text:JSON.stringify(answer)}],isError:false};
}
