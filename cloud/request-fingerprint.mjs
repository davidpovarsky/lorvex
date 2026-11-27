import {createHash} from 'node:crypto';

const sorted=value=>Array.isArray(value)?value.map(sorted):
  value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(key=>[key,sorted(value[key])])):value;

export function requestFingerprint(tool,args) {
  const {request_id,...parameters}=args;
  return createHash('sha256').update(JSON.stringify(sorted({tool,arguments:parameters}))).digest('hex');
}
