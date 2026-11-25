"""Wait for actual native notification and badge callbacks before UI acceptance."""
from pathlib import Path
import hashlib,json,os,re,subprocess,time,uuid
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
 evidence={"schemaVersion":1,"sourceSHA":c.args.expected_sha,"simulatorID":simulator,"sameBuiltApplication":str(product),"applicationBinarySHA256":binary_hash,"helperSHA256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"startedUTC":__import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),"providerFixtureEnabled":False,"cloudSync":"off","realNotificationAPIRequired":True,"attempts":[],"result":"running"}
 record["systemServiceReadiness"]=evidence;c.save()
 c.run(key+"-readiness-install",["xcrun","simctl","install",simulator,str(product)],timeout=180)
 env=c.ui_env.copy()
 for name in ("SIMCTL_CHILD_LORVEX_HANLIN_WORKSPACE_ACCEPTANCE","SIMCTL_CHILD_LORVEX_HANLIN_WORKSPACE_TASK_TITLE","SIMCTL_CHILD_TASK_WORKSPACE_DATE_DIAGNOSTICS"):
  env.pop(name,None)
 env["SIMCTL_CHILD_LORVEX_CLOUD_SYNC"]="off"
 language=key.rsplit("-",1)[-1];language=language if language in ("en","he") else "en"
 predicate='process == "LorvexMobileApp" AND subsystem == "com.apple.UserNotifications"'
 for number in (1,2):
  if number==2:
   c.run(key+"-readiness-recovery-shutdown",["xcrun","simctl","shutdown",simulator],timeout=60)
   c.run(key+"-readiness-recovery-boot",["xcrun","simctl","boot",simulator],timeout=60)
   c.run(key+"-readiness-recovery-boot-ready",["xcrun","simctl","bootstatus",simulator,"-b"],timeout=180)
  path=folder/f"attempt-{number}-notification-stream.log";handle=path.open("wb")
  command=["xcrun","simctl","spawn",simulator,"log","stream","--style","compact","--level","debug","--predicate",predicate]
  observer=subprocess.Popen(command,env=c.ui_env,stdout=handle,stderr=subprocess.STDOUT,start_new_session=True)
  started=time.monotonic()
  attempt={"number":number,"stream":str(path),"streamCommand":command,"maximumReadinessSeconds":180,"result":"running"}
  evidence["attempts"].append(attempt);c.save()
  original_env=c.ui_env
  try:
   c.ui_env=env
   _,launch_log=c.run(key+f"-readiness-launch-{number}",["xcrun","simctl","launch",simulator,"com.itorah.lorvex","-setupCompleted","YES","-AppleLanguages","("+language+")","-AppleLocale","he_IL" if language=="he" else "en_US"],timeout=45)
   match=re.search(r"com\.itorah\.lorvex:\s*(\d+)",launch_log.read_text());assert match,"Missing launched app PID"
   pid=int(match.group(1));attempt["applicationPID"]=pid;c.save()
   while time.monotonic()-started<180:
    current=path.read_text(errors="replace")
    lines=[line for line in current.splitlines() if f"LorvexMobileApp[{pid}:" in line]
    received=[i for i,line in enumerate(lines) if re.search(r"Got \d+ pending notification \[ hasCompletionHandler: 1 \]",line)]
    badge=[i for i,line in enumerate(lines) if "Set badge count [ hasCompletionHandler: 1 hasError: 0 ]" in line]
    if received and badge and any(b>received[0] for b in badge):
     attempt.update(result="passed",pendingCallbackLines=[lines[i] for i in received],badgeCallbackLines=[lines[i] for i in badge])
     break
    if observer.poll() is not None:raise RuntimeError("Readiness OS log observer ended before completion")
    time.sleep(1)
   if attempt["result"]!="passed":attempt["result"]="service-not-ready-before-deadline"
  finally:
   c.ui_env=original_env
   if observer.poll() is None:
    observer.terminate()
    try:observer.wait(timeout=3)
    except subprocess.TimeoutExpired:observer.kill();observer.wait()
   handle.close();attempt.update(elapsedSeconds=round(time.monotonic()-started,3),streamSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),observerExitCode=observer.returncode)
   c.run(key+f"-readiness-terminate-{number}",["xcrun","simctl","terminate",simulator,"com.itorah.lorvex"],timeout=30,check=False)
   c.save()
  if attempt["result"]=="passed":
   evidence["result"]="passed";evidence["usedOwnedDeviceReboot"]=number==2;break
 evidence["finishedUTC"]=__import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat()
 (folder/"receipt.json").write_text(json.dumps(evidence,indent=2)+"\n");record["systemServiceReadinessReceipt"]={"path":str(folder/"receipt.json"),"sha256":hashlib.sha256((folder/"receipt.json").read_bytes()).hexdigest()};c.save()
 if evidence["result"]!="passed":raise RuntimeError("Real notification enumeration and badge callback never became ready; no UI case executed.")
 assert hashlib.sha256(binary.read_bytes()).hexdigest()==binary_hash
