"""Development-only persistent native-Julia process client."""
import atexit,hashlib,json,os,pathlib,subprocess,threading,time
from verify_reference import ROOT as PKG,snapshot,enrich,require
_CLIENTS={}
def digest(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def julia_command(executable):return [str(pathlib.Path(executable).resolve()),'--startup-file=no','--history-file=no','--project='+str(PKG),str(PKG/'scripts/bridge.jl')]
def execute(command,requests,env=None):
 key=tuple(command)
 if key not in _CLIENTS:
  proc=subprocess.Popen(command,cwd=PKG,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  errs=[]
  def readerr():
   for line in proc.stderr:errs.append(line)
  reader=threading.Thread(target=readerr,daemon=True);reader.start()
  _CLIENTS[key]=(proc,errs,reader)
 proc,errs,reader=_CLIENTS[key];results=[]
 timer=threading.Timer(900,proc.kill);timer.start()
 try:
  for r in requests:
   proc.stdin.write((json.dumps(r,ensure_ascii=True)+'\n').encode());proc.stdin.flush()
   line=proc.stdout.readline();require(bool(line),'Julia process stopped: '+b''.join(errs).decode(errors='replace'))
   results.append(enrich(json.loads(line)))
  require(not errs,'Unexpected Julia stderr: '+b''.join(errs).decode(errors='replace'))
 finally:timer.cancel()
 return results
@atexit.register
def close_clients():
 for proc,errs,reader in _CLIENTS.values():
  if proc.poll() is None:
   try:proc.stdin.close();proc.wait(timeout=20)
   except BaseException:proc.kill();proc.wait()
  reader.join(timeout=5)
