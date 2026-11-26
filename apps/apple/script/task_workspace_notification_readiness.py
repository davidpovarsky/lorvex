"""Wait for actual native notification and badge callbacks before UI acceptance."""
from pathlib import Path
import hashlib,json,os,re,subprocess,time,uuid
def capture_timeout_diagnostics(controller,key,simulator,pid,number,folder):
 """Sample only the app and services proved to belong to this owned simulator."""
 import ctypes
 c=controller
 evidence={"result":"unavailable","processes":[],"collectionMethod":"scoped-libproc","startedUTC":__import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat()}
 # The ps command can block inside its privileged process inventory on a busy
 # host, even after its subprocess timeout. Read only the known app identity
 # and that simulator launchd's direct children through the public libproc ABI.
 class BSDInfo(ctypes.Structure):
  _fields_=[(name,ctypes.c_uint32) for name in ("flags","status","xstatus","pid","ppid","uid","gid","ruid","rgid","svuid","svgid","reserved")]+[("comm",ctypes.c_char*16),("name",ctypes.c_char*32)]+[(name,ctypes.c_uint32) for name in ("nfiles","pgid","jobc","tdev","tpgid")]+[("nice",ctypes.c_int32),("startSeconds",ctypes.c_uint64),("startMicroseconds",ctypes.c_uint64)]
 library=ctypes.CDLL("/usr/lib/libproc.dylib",use_errno=True)
 library.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
 library.proc_pidinfo.restype=ctypes.c_int
 library.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
 library.proc_pidpath.restype=ctypes.c_int
 library.proc_listchildpids.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_int]
 library.proc_listchildpids.restype=ctypes.c_int
 def process_record(target):
  info=BSDInfo()
  if library.proc_pidinfo(target,3,0,ctypes.byref(info),ctypes.sizeof(info))!=ctypes.sizeof(info):return None
  path=ctypes.create_string_buffer(4096)
  if library.proc_pidpath(target,path,len(path))<=0:return None
  return {"pid":int(info.pid),"parentPID":int(info.ppid),"command":path.value.decode(errors="replace"),"startSeconds":int(info.startSeconds),"startMicroseconds":int(info.startMicroseconds)}
 try:
  app=process_record(pid)
  if not app or f"/Devices/{simulator}/" not in app["command"] or Path(app["command"]).name!="LorvexMobileApp":
   evidence["reason"]="Launched application process is absent or no longer matches this owned simulator"
   return evidence
  parent=process_record(app["parentPID"])
  if not parent or Path(parent["command"]).name!="launchd_sim":
   evidence["reason"]="The application's simulator launchd parent could not be proved"
   return evidence
  evidence["simulatorLaunchd"]=parent
  candidates=[("application",app)]
  children=(ctypes.c_int*512)()
  count=library.proc_listchildpids(app["parentPID"],children,ctypes.sizeof(children))
  if 0<=count<len(children):
   services={"SpringBoard":[],"usernotificationsd":[]}
   for child in children[:count]:
    entry=process_record(child)
    if not entry:continue
    role=Path(entry["command"]).name
    if entry["parentPID"]==app["parentPID"] and role in services:services[role].append(entry)
   for role,entries in services.items():
    if len(entries)==1:candidates.append((role,entries[0]))
    elif entries:evidence[role+"Discovery"]="ambiguous owned service process; not sampled"
  else:evidence["serviceDiscovery"]="scoped child process inventory unavailable or truncated"
  for role,expected in candidates:
   record={"role":role,**expected,"result":"unavailable"}
   evidence["processes"].append(record)
   try:
    if process_record(expected["pid"])!=expected:
     record["reason"]="Process identity changed before sampling";continue
    output=folder/f"attempt-{number}-{role}-sample.txt"
    code,log=c.run(key+f"-readiness-timeout-{number}-{role}-sample",["sample",str(expected["pid"]),"3","-file",str(output)],timeout=15,check=False)
    record.update(result="captured" if code==0 and output.exists() else "sample-unavailable",exitCode=code,log=str(log))
    if output.exists():record["artifact"]={"path":str(output),"sha256":hashlib.sha256(output.read_bytes()).hexdigest()}
   except Exception as error:
    record.update(result="sample-unavailable",reason=type(error).__name__+": "+str(error))
  evidence["result"]="completed"
 except Exception as error:
  evidence["reason"]=type(error).__name__+": "+str(error)
 finally:
  evidence["finishedUTC"]=__import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat()
 return evidence

def prepare(controller,key,simulator,application):
 c=controller;uuid.UUID(simulator)
 records=c.receipt.get("cases",[])+([c.receipt["hostUI"]] if c.receipt.get("hostUI") else [])
 matching=[record for record in records if record.get("key")==key and record.get("simulatorID")==simulator]
 assert len(matching)==1,"Readiness may target only this run's fresh owned case"
 record=matching[0];folder=c.out/key/"system-service-readiness";folder.mkdir()
 product=Path(application)
 binary=product/"LorvexMobileApp";binary_hash=c.load_build()["binarySHA256"][str(binary)]
 assert c.raw_git("rev-parse","HEAD")==c.args.expected_sha
 assert hashlib.sha256(binary.read_bytes()).hexdigest()==binary_hash
 clock=__import__("datetime")
 evidence={"schemaVersion":2,"collectionMethod":"persisted-log-show","sourceSHA":c.args.expected_sha,"simulatorID":simulator,"sameBuiltApplication":str(product),"applicationBinarySHA256":binary_hash,"helperSHA256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"startedUTC":clock.datetime.now(clock.timezone.utc).isoformat(),"providerFixtureEnabled":False,"cloudSync":"off","realNotificationAPIRequired":True,"attempts":[],"result":"running"}
 record["systemServiceReadiness"]=evidence;c.save()
 c.run(key+"-readiness-install",["xcrun","simctl","install",simulator,str(product)],timeout=180)
 env=c.ui_env.copy()
 for name in ("SIMCTL_CHILD_LORVEX_HANLIN_WORKSPACE_ACCEPTANCE","SIMCTL_CHILD_LORVEX_HANLIN_WORKSPACE_TASK_TITLE","SIMCTL_CHILD_TASK_WORKSPACE_DATE_DIAGNOSTICS"):
  env.pop(name,None)
 env["SIMCTL_CHILD_LORVEX_CLOUD_SYNC"]="off"
 language=key.rsplit("-",1)[-1];language=language if language in ("en","he") else "en"
 predicate='process == "LorvexMobileApp"'
 for number in (1,2):
  if number==2:
   c.run(key+"-readiness-recovery-shutdown",["xcrun","simctl","shutdown",simulator],timeout=60)
   c.run(key+"-readiness-recovery-boot",["xcrun","simctl","boot",simulator],timeout=60)
   c.run(key+"-readiness-recovery-boot-ready",["xcrun","simctl","bootstatus",simulator,"-b"],timeout=180)
  local_start=clock.datetime.now().astimezone()
  started=time.monotonic()
  attempt={"number":number,"collectionMethod":"persisted-log-show","startedUTC":local_start.astimezone(clock.timezone.utc).isoformat(),"logStartLocal":local_start.strftime("%Y-%m-%d %H:%M:%S"),"logTimeZoneOffsetSeconds":int(local_start.utcoffset().total_seconds()),"maximumReadinessSeconds":180,"queries":[],"result":"running"}
  evidence["attempts"].append(attempt);c.save()
  original_env=c.ui_env
  try:
   c.ui_env=env
   _,launch_log=c.run(key+f"-readiness-launch-{number}",["xcrun","simctl","launch",simulator,"com.itorah.lorvex","-setupCompleted","YES","-AppleLanguages","("+language+")","-AppleLocale","he_IL" if language=="he" else "en_US"],timeout=45)
   match=re.search(r"com\.itorah\.lorvex:\s*(\d+)",launch_log.read_text());assert match,"Missing launched app PID"
   pid=int(match.group(1));attempt["applicationPID"]=pid;c.save()
   # Read persisted events in short bounded queries. A continuous debug stream
   # previously coincided with a 170s first notification request on this host.
   # Readiness still requires actual ordered callbacks before the same deadline.
   next_query=10.0
   while time.monotonic()-started<180:
    until_query=next_query-(time.monotonic()-started)
    if until_query>0:
     time.sleep(min(1,until_query));continue
    remaining=180-(time.monotonic()-started)
    if remaining<=0:break
    query_number=len(attempt["queries"])+1
    command=["xcrun","simctl","spawn",simulator,"log","show","--style","compact","--info","--debug","--start",attempt["logStartLocal"],"--predicate",predicate]
    query_started=clock.datetime.now(clock.timezone.utc).isoformat()
    elapsed_before=round(time.monotonic()-started,3)
    code,path=c.run(key+f"-readiness-log-show-{number}-{query_number}",command,timeout=min(20,remaining),check=False)
    elapsed=time.monotonic()-started
    query={"number":query_number,"command":command,"path":str(path),"sha256":hashlib.sha256(path.read_bytes()).hexdigest(),"exitCode":code,"startedUTC":query_started,"finishedUTC":clock.datetime.now(clock.timezone.utc).isoformat(),"elapsedBeforeQuerySeconds":elapsed_before,"observedElapsedSeconds":elapsed}
    attempt["queries"].append(query)
    lines=[line for line in path.read_text(errors="replace").splitlines() if f"LorvexMobileApp[{pid}:" in line and "[com.apple.UserNotifications:" in line and "[com.itorah.lorvex]" in line]
    received=[i for i,line in enumerate(lines) if re.search(r"Got \d+ pending notification \[ hasCompletionHandler: 1 \]",line)]
    badge=[i for i,line in enumerate(lines) if "Set badge count [ hasCompletionHandler: 1 hasError: 0 ]" in line]
    if code==0 and elapsed<=180 and received and badge and any(b>received[0] for b in badge):
     attempt.update(result="passed",callbackQueryNumber=query_number,pendingCallbackLines=[lines[i] for i in received],badgeCallbackLines=[lines[i] for i in badge])
     c.save();break
    c.save()
    next_query=max(next_query+10,time.monotonic()-started+5)
   attempt["readinessElapsedSeconds"]=round(time.monotonic()-started,3)
   if attempt["result"]!="passed":
    attempt["result"]="service-not-ready-before-deadline"
    attempt["timeoutDiagnostics"]=capture_timeout_diagnostics(c,key,simulator,pid,number,folder)
  finally:
   c.ui_env=original_env
   attempt["elapsedSeconds"]=round(time.monotonic()-started,3)
   attempt["finishedUTC"]=clock.datetime.now(clock.timezone.utc).isoformat()
   c.run(key+f"-readiness-terminate-{number}",["xcrun","simctl","terminate",simulator,"com.itorah.lorvex"],timeout=30,check=False)
   c.save()
  if attempt["result"]=="passed":
   evidence["result"]="passed";evidence["usedOwnedDeviceReboot"]=number==2;break
 if evidence["result"]!="passed":
  evidence["result"]="failed";evidence["usedOwnedDeviceReboot"]=len(evidence["attempts"])>1
 evidence["finishedUTC"]=clock.datetime.now(clock.timezone.utc).isoformat()
 (folder/"receipt.json").write_text(json.dumps(evidence,indent=2)+"\n");record["systemServiceReadinessReceipt"]={"path":str(folder/"receipt.json"),"sha256":hashlib.sha256((folder/"receipt.json").read_bytes()).hexdigest()};c.save()
 if evidence["result"]!="passed":raise RuntimeError("Real notification enumeration and badge callback never became ready before the deadline; no UI case executed.")
 assert hashlib.sha256(binary.read_bytes()).hexdigest()==binary_hash
