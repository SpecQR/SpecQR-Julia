#!/usr/bin/env python3
import json,pathlib,sys
from verification_support import PKG,execute,finish_clients,check_fnc1_outcome,snapshot,digest,julia_command
ROOT=PKG.parent
import argparse
p=argparse.ArgumentParser();p.add_argument("--julia",required=True);p.add_argument("--output",type=pathlib.Path,required=True);p.add_argument("--python-deps",type=pathlib.Path,required=True);a=p.parse_args()
if not __debug__:raise SystemExit("Verification requires Python assertions; do not use -O or PYTHONOPTIMIZE.")
sys.path.insert(0,str(a.python_deps.resolve()))
import zxingcpp
from decoder_support import verify_png

def main():
 corpus=PKG/'verification/fixtures/expected-contract-vectors.json'
 shared=PKG/'verification/fixtures/cross-port-regressions.json'
 vectors=json.loads(corpus.read_text());issues=json.loads(shared.read_text())['issues']
 binary=pathlib.Path(a.julia).resolve()
 a.output.parent.mkdir(parents=True,exist_ok=True)
 a.output.write_text(json.dumps({'status':'running'})+'\n')
 report={'status':'running','sourceSha256':snapshot(),'binarySha256':digest(binary),'corpusSha256':digest(corpus),'sharedSha256':digest(shared),'counts':{},'intentionalDifferences':['High-level FNC1 percent uses byte fallback; forced alphanumeric rejects.','Creation safely places dot-only qualifiers into query, including explicit pathAis.','Print DPI is always validated conservatively at maximum symbol geometry.','Direct ECC enum inputs cannot represent JavaScript object property names.']}
 counts={'percentVectors':0,'successfulPercentVectors':0,'decodedPngs':0,'forcedAlphaRejections':0,'capacityRejections':0,'manualSemantics':0,'digitalLinkOperations':0,'printDpiCases':0,'bridgeEccCases':0}
 try:
  requests=[{'text':v['input'],'options':v['options'],'pngScale':3} for v in vectors['vectors']]
  for v,q in zip(vectors['vectors'],execute(julia_command(binary),requests)):
   counts['percentVectors']+=1
   expected_outcome=check_fnc1_outcome(v,q)
   if expected_outcome=='INVALID_MODE':counts['forcedAlphaRejections']+=1;continue
   if expected_outcome=='DATA_TOO_LONG':counts['capacityRejections']+=1;continue
   counts['successfulPercentVectors']+=1
   _,pixels,dim=verify_png(q['png'],q['matrix'],3)
   found=zxingcpp.read_barcode(memoryview(pixels).cast('B',shape=(dim,dim)),text_mode=zxingcpp.TextMode.Plain)
   indicator=v['options'].get('fnc1Second','').encode()
   expected=indicator+bytes.fromhex(v['expectedPayloadUtf8Hex'])
   assert found is not None and found.valid and found.bytes==expected,(v['id'],None if found is None else found.bytes.hex(),expected.hex());counts['decodedPngs']+=1
  assert (counts['successfulPercentVectors'],counts['forcedAlphaRejections'],counts['capacityRejections'])==(44,34,24),counts
  for v in vectors['manualVectors']:
   request={'segments':v['controls']+v['data'],'pngScale':3}
   q=execute(julia_command(binary),[request])[0];assert 'error' not in q,q
   _,pixels,dim=verify_png(q['png'],q['matrix'],3)
   found=zxingcpp.read_barcode(memoryview(pixels).cast('B',shape=(dim,dim)),text_mode=zxingcpp.TextMode.Plain)
   prefix=next((c['applicationIndicator'] for c in v['controls'] if c['mode']=='fnc1-second'),'').encode()
   assert found is not None and found.valid and found.bytes==prefix+bytes.fromhex(v['expectedPayloadUtf8Hex']);counts['manualSemantics']+=1;counts['decodedPngs']+=1
  assert counts['manualSemantics']==4 and counts['decodedPngs']==48,counts
  for c in issues['digitalLinkDotLoss']['cases']:
   if 'elements' in c:
    q=execute(julia_command(binary),[{'command':'digital-link-build','elements':c['elements'],'linkOptions':c['options']}])[0];assert 'error' not in q,q
    if 'expectedUri' in c:assert q['value']==c['expectedUri'],q
    else:
     assert '/10/.' not in q['value'] and '?10=' in q['value'],q
     parsed=execute(julia_command(binary),[{'command':'digital-link-parse','url':q['value']}])[0];assert parsed['elements']==c['elements'],parsed
    counts['digitalLinkOperations']+=1
   else:
    for op in ['parse','validate','normalize']:
     q=execute(julia_command(binary),[{'command':'digital-link-'+op,'url':c['uri']}])[0]
     if c.get('expectedNormalizedUri'):
      if op=='normalize':assert q['value']==c['expectedNormalizedUri'],q
      elif op=='validate':assert q['ok'] and q['result']['elements']==c['expectedElements'],q
      else:assert q['elements']==c['expectedElements'],q
     elif op=='validate':assert q['ok'] is False,q
     else:assert q.get('code')=='INVALID_GS1',q
     counts['digitalLinkOperations']+=1
  for dpi,version in [(5e-324,1),(1e-305,1),(1e-304,1),(1e-304,40),(300,1)]:
   for command in [None,'estimate','structured-append']:
    q=execute(julia_command(binary),[{'command':command,'text':'A'*80 if command=='structured-append' else 'A','options':{'printDpi':dpi,'version':version}}])[0]
    assert ('error' not in q) if dpi==300 else q.get('code')=='INVALID_INPUT',(dpi,command,q)
    counts['printDpiCases']+=1
  for name in issues['inheritedEccKeys']['inputs']:
   for command in [None,'estimate','structured-append','capacity']:
    q=execute(julia_command(binary),[{'command':command,'text':'A','options':{'errorCorrectionLevel':name,'version':1}}])[0]
    assert q.get('code')=='INVALID_ECC_LEVEL',q;counts['bridgeEccCases']+=1
  authority=PKG/'verification/fixtures/strict-authority-vectors.json'
  strict=json.loads(authority.read_text());report['strictAuthorityFixtureSha256']=digest(authority)
  counts['strictAuthorityOperations']=0
  for v in strict['vectors']:
   for op in ['parse','validate','normalize']:
    q=execute(julia_command(binary),[{'command':'digital-link-'+op,'url':v['input']}])[0]
    if op=='validate':assert q.get('ok') is False,(v['id'],op,q)
    else:assert q.get('code')=='INVALID_GS1',(v['id'],op,q)
    counts['strictAuthorityOperations']+=1
  finish_clients(report)
  report['sourceStable']=snapshot()==report['sourceSha256']
  assert report['sourceStable'],'Source changed during verification'
  report['status']='passed'
 except BaseException as error:report.update(status='failed',error=repr(error));raise
 finally:
  finish_clients(report,raise_errors=False)
  if 'sourceStable' not in report:
   try:report['sourceStable']=snapshot()==report['sourceSha256']
   except BaseException as error:report.update(sourceStable=False,sourceSnapshotError=repr(error))
  report.update(counts=counts);a.output.write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
