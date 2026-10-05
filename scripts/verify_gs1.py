#!/usr/bin/env python3
"""Fail-closed original GS1 corpus, independently pinned TypeScript positives.

Only four diagnostic migrations use separately executed published-Julia semantic
witnesses. No expected outcome is copied from the candidate under test.
"""
import argparse,collections,gzip,hashlib,json,os,pathlib,subprocess
from native_support import strict_json,require,verify_source,file_sha
ROOT=pathlib.Path(__file__).resolve().parents[1]
PINS = {'gs1-upstream.json': 'e12c7a2e6ed9ae26cc9865caab9e6e0a7dbeb62438a903a3f5611d6420c865e2', 'current-ts-gs1-1411.json.gz': 'c2e0678be740d935306353ae15c0e5f80a444a641351b070f5126be81057021b', 'native-julia-baseline1411.json.gz': 'af20a043de6677bde1870bd32d8102edad9395a39698cdb5bb0ff63e448c4f01', 'approved-restorations80.json': '08f1e5ae4b2d49163e85ed95507090f4b409924e4ce1d553f092a4efa5ddcd3c', 'julia-diagnostic-migrations4.json': '83cb541a0d6d08adbbe5321d6615aeadc49fa3897ca51a2a4c045d1f361f5dd4', 'julia-residual164.json': '0ea0b06cebc05311ad5ca4f7c712f2ce6e329b5237fc945ba82397aff504f0c9', 'current-ts-gs1-shared49.json': 'a7d568cb2a63ff28695b132c1028c8d7ca898cca0e813316ff6b454fecc447e1', 'native-julia-shared49.json': '10f0d7153b4e0deb48f35a93dda3b6fa4a1a35dc318fae835df3ade39cfdc285'} # Populated once from reviewed immutable input artifacts, never at runtime.
def request_sha(v):return hashlib.sha256(json.dumps(v,sort_keys=True,ensure_ascii=True,separators=(',',':')).encode()).hexdigest()
def contract(v):
 if isinstance(v,list):return [contract(x) for x in v]
 if isinstance(v,dict):
  if 'code'in v and 'message'in v:return {k:contract(v[k])for k in ['code','reason','count']if v.get(k)is not None}
  return {k:contract(x)for k,x in v.items()if x is not None and k!='isVariable'and not(k=='errors'and v.get('ok'))}
 return v
def same(a,b):return json.dumps(contract(a),sort_keys=True,separators=(',',':'))==json.dumps(contract(b),sort_keys=True,separators=(',',':'))
def accepted(v):return not(isinstance(v,dict)and('throws'in v or v.get('ok')is False))
def fixture(name):
 p=ROOT/'verification/fixtures'/name;raw=p.read_bytes();require(hashlib.sha256(raw).hexdigest()==PINS[name],'Fixture digest changed: '+name)
 return strict_json(gzip.decompress(raw)if name.endswith('.gz')else raw)
def contracts():
 historical=fixture('gs1-upstream.json');ts=fixture('current-ts-gs1-1411.json.gz');baseline=fixture('native-julia-baseline1411.json.gz');restores=fixture('approved-restorations80.json');migrations=fixture('julia-diagnostic-migrations4.json');residual=fixture('julia-residual164.json')
 require(len(historical['cases'])==ts['caseCount']==baseline['caseCount']==1411,'Full corpus cardinality changed')
 require(ts['source']['commit']=='16efc6c0a8e397c9df3d051d20fce6c1eebdfad7'and ts['source']['tree']=='ca4c2360a7dc0950c1bfd1f76e44616bcd406023','Wrong TypeScript source')
 require(baseline['source']['commit']=='ffb95d10cd1c585421cb3a52a43a9e657d000a29'and baseline['source']==migrations['source'],'Wrong independent Julia baseline')
 require(file_sha(ROOT/'verification/gs1/julia_oracle.jl')==baseline['source']['oracleSha256'],'Native adapter changed')
 require(file_sha(ROOT/ts['source']['oracleHarness'])==ts['source']['oracleHarnessSha256'],'TS adapter changed')
 requests=[{k:v for k,v in r.items()if k!='expected'}for r in historical['cases']]
 require(len(ts['cases'])==len(baseline['cases'])==1411,'Missing oracle rows')
 expected=[]
 for i,(q,t,n)in enumerate(zip(requests,ts['cases'],baseline['cases'])):
  require(t['caseId']==n['caseId']==i and t['request']==q and t['requestSha256']==n['requestSha256']==request_sha(q),'Request binding changed: '+str(i));expected.append(n['expected'])
 require(restores['caseCount']==len(restores['cases'])==80,'Missing restoration targets')
 ids=set()
 for row in restores['cases']:
  i=row['caseId'];require(i not in ids and row['request']==requests[i]and row['requestSha256']==request_sha(requests[i])and row['expected']==ts['cases'][i]['expected']and accepted(row['expected']),'Restoration binding changed');ids.add(i);expected[i]=row['expected']
 require({x['caseId']for x in migrations['cases']}=={930,1038,1056,1269},'Diagnostic migration scope changed')
 for row in migrations['cases']:
  i=row['caseId'];require(i not in ids and row['priorExpected']==baseline['cases'][i]['expected']and row['requestSha256']==request_sha(requests[i]),'Diagnostic baseline changed')
  require(not accepted(row['expected'])and not accepted(row['priorExpected']),'Diagnostic migration changes acceptance');expected[i]=row['expected']
 differences={i for i,(t,n)in enumerate(zip(ts['cases'],expected))if not same(t['expected'],n)}
 require(differences=={x['caseId']for x in residual['cases']}and len(differences)==164,'Unclassified residual')
 require(all(accepted(expected[i])and same(expected[i],ts['cases'][i]['expected'])for i in [1331,1332,1333]),'Julia NUL payload contract changed')
 return requests,expected,ts,ids

def validate_process(p,count):
 require(p.returncode==0,'GS1 native process failed: '+str(p.returncode));require(not p.stderr,'GS1 native stderr is not empty')
 require(len(p.stdout)<=16*1024*1024,'GS1 response limit exceeded');require(p.stdout.endswith(b'\n'),'Missing JSON-line terminator')
 lines=p.stdout.splitlines();require(len(lines)==count,'GS1 output cardinality mismatch')
 return [strict_json(x)for x in lines]
def execute(julia,requests,out,label):
 argv=[str(pathlib.Path(julia).resolve()),'--startup-file=no','--history-file=no','--project='+str(ROOT),str(ROOT/'verification/gs1/julia_oracle.jl')]
 payload=b''.join((json.dumps(q,ensure_ascii=True)+'\n').encode()for q in requests)
 p=subprocess.run(argv,input=payload,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=180,env=os.environ.copy())
 (out/(label+'.stdout')).write_bytes(p.stdout);(out/(label+'.stderr')).write_bytes(p.stderr)
 receipt={'argv':argv,'requests':len(requests),'responses':len(p.stdout.splitlines()),'exitCode':p.returncode,'stderrBytes':len(p.stderr),'stdoutSha256':hashlib.sha256(p.stdout).hexdigest(),'stderrSha256':hashlib.sha256(p.stderr).hexdigest(),'inputSha256':hashlib.sha256(payload).hexdigest()}
 (out/(label+'.process.json')).write_text(json.dumps(receipt,indent=2)+'\n')
 return validate_process(p,len(requests)),receipt

def main():
 p=argparse.ArgumentParser();p.add_argument('--julia',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args();a.output=a.output.resolve();a.output.parent.mkdir(parents=True,exist_ok=True)
 report={'status':'running'};a.output.write_text(json.dumps(report)+'\n')
 try:
  before=verify_source(ROOT);requests,expected,ts,ids=contracts();actual,receipt=execute(a.julia,requests,a.output.parent,'gs1-1411')
  mismatches=[i for i,(want,got)in enumerate(zip(expected,actual))if not same(want,got)];require(not mismatches,'GS1 mismatch IDs: '+str(mismatches))
  counts=collections.Counter()
  for t,n in zip(ts['cases'],actual):
   t=t['expected'];category='aligned'if same(t,n)else 'diagnostic-only'if not accepted(t)and not accepted(n)else 'accepted-to-rejected'if not accepted(n)else 'rejected-to-accepted'if not accepted(t)else 'normalization/data-result';counts[category]+=1
  require(counts=={'aligned':1247,'diagnostic-only':131,'accepted-to-rejected':31,'rejected-to-accepted':2},'Classification changed')
  shared=fixture('current-ts-gs1-shared49.json');native=fixture('native-julia-shared49.json');require(shared['caseCount']==len(shared['cases'])==49,'Shared cardinality changed');require(len(native['cases'])==49,'Missing independent shared baseline')
  require(native['sourceCommit']=='ffb95d10cd1c585421cb3a52a43a9e657d000a29','Shared baseline source changed')
  for name,sha in shared['sourceFixtures'].items():require(file_sha(ROOT/'verification/fixtures'/name)==sha,'Shared historical fixture changed')
  shared_actual,shared_receipt=execute(a.julia,[r['request']for r in shared['cases']],a.output.parent,'gs1-shared49')
  allowed={'bare-hex-ipv4-4:linkValidate','builder-dot-path:linkCreate','builder-parent-path:linkCreate'}
  for row,old,got in zip(shared['cases'],native['cases'],shared_actual):
   require(row['id']==old['id']and row['request']==old['request']and row['requestSha256']==request_sha(row['request']),'Shared request mismatch')
   want=old['expected']if row['id']in allowed else row['expected'];require(same(want,got),'Shared GS1 mismatch: '+row['id'])
  require(verify_source(ROOT)==before,'Source changed during GS1 verification')
  report.update(status='passed',source=before,processes=[receipt,shared_receipt],caseCount=1411,restoredPositives=len(ids),sharedOperations=49,classification=dict(counts),sourceStable=True)
 except BaseException as error:report.update(status='failed',error=repr(error));raise
 finally:a.output.write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
