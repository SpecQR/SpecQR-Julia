#!/usr/bin/env python3
"""Execute real Julia against source-bound language-neutral reference cases."""
from __future__ import annotations
import argparse,gzip,hashlib,json,os,pathlib,subprocess,threading,time
ROOT=pathlib.Path(__file__).resolve().parents[1]
PINNED={"public":(5610,"f1649de0f2e62c87fa7b369cdd1f99bd7c092b6a1a2fa52e2e0caf5aea136f82"),"internal":(4576,"140eec7223af96822572f87cf67a80b612619bde250db552c1cad83b603ae67e")}
def require(v,message):
 if not v:raise RuntimeError(message)
def sha(data):return hashlib.sha256(data).hexdigest()
def snapshot():return {p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in sorted(ROOT.rglob('*')) if p.is_file() and (p.suffix in ('.jl','.toml','.py') or p.name=='SOURCE-SHA256.json') and not any(x in p.parts for x in ('__pycache__','validation-output','build'))}
from native_support import strict_json, binding
def enrich(r):
 if 'matrix' in r:
  require(isinstance(r['matrix'],list) and all(isinstance(s,str) and set(s)<=set('01') for s in r['matrix']),'Invalid matrix rows')
  require(len(r['matrix'])>0 and all(len(s)==len(r['matrix']) for s in r['matrix']),'Invalid matrix dimensions')
  r['matrixHash']=sha(''.join(r['matrix']).encode('ascii'))
 if 'symbols' in r:
  for q in r['symbols']:enrich(q)
  r['matrixHashes']=[q['matrixHash'] for q in r['symbols']]
 return r
def compare(expected,actual,path='response'):
 require(type(actual) is type(expected) or (type(expected) in (int,float) and type(actual) in (int,float)),f'{path}: type mismatch')
 if isinstance(expected,dict):
  for k,v in expected.items():require(k in actual,f'{path}: missing {k}');compare(v,actual[k],path+'.'+k)
 elif isinstance(expected,list):
  require(len(expected)==len(actual),f'{path}: length mismatch')
  for i,(e,a) in enumerate(zip(expected,actual)):compare(e,a,f'{path}[{i}]')
 else:require(expected==actual,f'{path}: {str(expected)[:200]} != {str(actual)[:200]}')
def command(julia,check_bounds='yes'):return [str(pathlib.Path(julia).resolve()),'--startup-file=no','--history-file=no','--check-bounds='+check_bounds,'--project='+str(ROOT),str(ROOT/'scripts/bridge.jl')]
def execute(julia,records,output,env=None,timeout=1800,check_bounds='yes'):
 cmd=command(julia,check_bounds); output=pathlib.Path(output);output.parent.mkdir(parents=True,exist_ok=True)
 stdout_hash=hashlib.sha256();stdin_hash=hashlib.sha256();outbytes=inbytes=0;write_errors=[];timed_out=[]
 start=time.monotonic();receipt={'argv':cmd,'sourceSha256':snapshot(),'status':'running','requests':len(records)}
 errpath=output.with_suffix('.stderr'); inpath=output.with_suffix('.stdin.jsonl.gz'); outpath=output.with_suffix('.stdout.jsonl.gz'); failure=None
 with errpath.open('wb') as err, gzip.open(inpath,'wb') as input_log, gzip.open(outpath,'wb') as output_log:
  proc=subprocess.Popen(cmd,cwd=ROOT,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err)
  def feed():
   nonlocal inbytes
   try:
    for r in records:
     line=(json.dumps(r['request'],ensure_ascii=True,separators=(',',':'))+'\n').encode();stdin_hash.update(line);inbytes+=len(line);input_log.write(line);proc.stdin.write(line)
    proc.stdin.close()
   except BaseException as e:write_errors.append(repr(e))
  def terminate():timed_out.append(True);proc.kill()
  timer=threading.Timer(timeout,terminate);timer.start();writer=threading.Thread(target=feed);writer.start();count=0;counts={};independent=0
  try:
   for line in proc.stdout:
    stdout_hash.update(line);outbytes+=len(line);output_log.write(line)
    if count>=len(records):failure='Extra output line';proc.kill();break
    record=records[count];actual=None
    try:
     actual=enrich(strict_json(line));compare(record['expected'],actual)
    except BaseException as e:
     failure=str(e);output.with_suffix('.failure.json').write_text(json.dumps({'index':count,'request':record['request'],'expected':record['expected'],'actual':locals().get('actual'),'error':failure},indent=2));proc.kill();break
    key=record['request'].get('command','generate');counts[key]=counts.get(key,0)+1;independent+=int(record.get('independent',False));count+=1
    if count%512==0:print(f'{count}/{len(records)}',flush=True)
   status=proc.wait(timeout=30);writer.join(timeout=30)
  finally:
   timer.cancel()
   if proc.poll() is None:proc.kill();proc.wait()
  receipt.update(exitCode=proc.returncode,elapsedSeconds=round(time.monotonic()-start,3),stdinSha256=stdin_hash.hexdigest(),stdoutSha256=stdout_hash.hexdigest(),stdinBytes=inbytes,stdoutBytes=outbytes,responseCount=count,counts=counts,independentNayukiMatrices=independent,timeout=bool(timed_out),writeErrors=write_errors)
 receipt['transcripts']={'stdin':binding(inpath),'stdout':binding(outpath)};receipt['stderrArtifact']=binding(errpath)
 receipt['stderrSha256']=sha(errpath.read_bytes());receipt['stderrBytes']=errpath.stat().st_size;receipt['sourceStable']=snapshot()==receipt['sourceSha256']
 try:
  require(failure is None,failure);require(not timed_out,'Timed out');require(not write_errors,'Input writer failed');require(receipt['exitCode']==0,'Julia failed');require(count==len(records),'Missing responses');require(receipt['stderrBytes']==0,'Unexpected stderr');require(receipt['sourceStable'],'Source changed during reference check');receipt['status']='passed'
 except BaseException as e:receipt['status']='failed';receipt['error']=str(e)
 output.write_text(json.dumps(receipt,indent=2)+'\n');require(receipt['status']=='passed',receipt.get('error','Reference failed'));return receipt

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--julia',required=True);ap.add_argument('--suite',choices=['public','internal','both'],default='both');ap.add_argument('--output',type=pathlib.Path,required=True);ap.add_argument('--timeout',type=float,default=1800);ap.add_argument('--check-bounds',choices=['yes','auto'],default='yes');args=ap.parse_args();require(0<args.timeout<float('inf'),'Timeout must be positive and finite')
 records=[];fixture_info={}
 for suite in ['public','internal'] if args.suite=='both' else [args.suite]:
  p=ROOT/'verification/fixtures'/f'{suite}-reference.jsonl.gz';count,digest=PINNED[suite];raw=p.read_bytes();require(sha(raw)==digest,'Fixture hash mismatch');rows=[strict_json(s) for s in gzip.decompress(raw).splitlines()];require(len(rows)==count,'Fixture count mismatch');records.extend(rows);fixture_info[suite]={'sha256':digest,'records':count}
 report=execute(args.julia,records,args.output,timeout=args.timeout,check_bounds=args.check_bounds);report['fixtures']=fixture_info;args.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'status':report['status'],'cases':len(records),'elapsedSeconds':report['elapsedSeconds']}))
if __name__=='__main__':main()
