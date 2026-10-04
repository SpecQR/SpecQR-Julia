#!/usr/bin/env python3
"""Source-bound offline actual-native Julia verification, Python stdlib only."""
from __future__ import annotations
import argparse,json,os,pathlib,re,subprocess,sys,time,xml.etree.ElementTree as ET,struct,zlib
from native_support import (ROOT,ValidationError,require,sha,file_sha,now,write_json,strict_json,
 canonical_arch,check_platform,verify_source,verify_fixtures,resolve_command,binding,
 Recorder,require_native_image,verify_archive,inventory,verify_gzip_transcript)
from verify_reference import snapshot

def runtime_info(data,version,system,arch):
 d=strict_json(data);require(isinstance(d,dict),'Runtime response is not an object');require(d.get('julia')==version,'Wrong Julia version')
 expected={'linux':'Linux','windows':'NT','darwin':'Darwin'}[system]
 require(d.get('os')==expected and canonical_arch(d.get('arch',''))==canonical_arch(arch),'Julia OS/architecture mismatch')
 require(d.get('wordSize')==(32 if canonical_arch(arch) in ('i386','arm') else 64),'Julia word size mismatch')
 require(type(d.get('threads')) is int and d['threads']>=2,'Multithreaded runtime required');return d

def test_summary(out,version):
 rows=[x.split(b'=',1)[1] for x in out.splitlines() if x.startswith(b'SPECQR_TESTS_JSON=')]
 require(len(rows)==1,'Missing test completion marker');d=strict_json(rows[0]);require(d.get('status')=='passed' and type(d.get('checks')) is int and d['checks']>=90000,'Incomplete native unit suite');require(d.get('julia')==version and type(d.get('threads')) is int and d['threads']>=2,'Wrong unit-test runtime');require(all(type(d.get(k)) is int and d[k]==0 for k in ('failed','errored','broken')),'Incomplete or unsuccessful unit-test totals');return d

def validate_reference(d,julia,check_bounds='yes'):
 counts={'generate':3028,'estimate':1920,'capacity':640,'structured-append':22,'raw':4320,'rs':255,'gf':1}
 require(d.get('status')=='passed' and d.get('sourceStable') is True,'Reference check failed or source changed')
 require(d.get('responseCount')==10186 and d.get('requests')==10186 and d.get('counts')==counts,'Missing reference cases')
 require(d.get('independentNayukiMatrices')==2400,'Missing independent matrix coverage')
 require(d.get('exitCode')==0 and d.get('stderrBytes')==0 and not d.get('timeout') and d.get('writeErrors')==[],'Reference process not clean')
 expected=[str(julia),'--startup-file=no','--history-file=no','--check-bounds='+check_bounds,'--project='+str(ROOT),str(ROOT/'scripts/bridge.jl')]
 require(d.get('argv')==expected,'Reference used a different Julia command')
 require(d.get('sourceSha256')==snapshot(),'Reference source binding mismatch')
 for k in ('stdinSha256','stdoutSha256','stderrSha256'):require(re.fullmatch('[0-9a-f]{64}',d.get(k,'')) is not None,'Invalid reference stream hash')
 require(d.get('stdinBytes',0)>0 and d.get('stdoutBytes',0)>0,'Empty reference streams')
 transcripts={key:verify_gzip_transcript(d.get('transcripts',{}).get(key),d[key+'Sha256'],d[key+'Bytes']) for key in ('stdin','stdout')}
 require(d.get('stderrArtifact')==binding(d.get('stderrArtifact',{}).get('path','')),'Reference stderr binding mismatch');require(d['stderrArtifact']['sha256']==d['stderrSha256'] and d['stderrArtifact']['bytes']==d['stderrBytes'],'Reference stderr stream differs from receipt')
 return {'transcripts':transcripts,'stderrArtifact':d['stderrArtifact'],'cases':d['responseCount'],'counts':d['counts'],'independentNayukiMatrices':d['independentNayukiMatrices'],'stdoutSha256':d['stdoutSha256']}

def check_png(data):
 require(data[:8]==b'\x89PNG\r\n\x1a\n','PNG signature');at=8;compressed=b'';header=None;end=False
 while at<len(data):
  require(at+12<=len(data),'PNG chunk');n=int.from_bytes(data[at:at+4],'big');kind=data[at+4:at+8];chunk=data[at+8:at+8+n];require(at+n+12<=len(data),'PNG truncation');require(zlib.crc32(kind+chunk)==int.from_bytes(data[at+8+n:at+12+n],'big'),'PNG CRC')
  if kind==b'IHDR':require(header is None and at==8,'PNG header order');header=struct.unpack('>IIBBBBB',chunk)
  elif kind==b'IDAT':compressed+=chunk
  elif kind==b'IEND':require(n==0 and at+12==len(data),'PNG end');end=True
  at+=n+12
 require(header is not None and end,'Incomplete PNG');w,h,depth,color,*rest=header;require(w==h and depth==8 and color==6 and rest==[0,0,0],'PNG format');raw=zlib.decompress(compressed);require(len(raw)==h*(w*4+1),'PNG size');return w

def cli_checks(recorder,base,work):
 work.mkdir(parents=True,exist_ok=True);checks=0;text='NUL\0 CR\r LF\n GS\x1d café 日 😀\n';payload=text.encode();source=work/'入力 日😀.txt';source.write_bytes(payload)
 def run(name,args=(),stdin=b'',expected=0):
  nonlocal checks
  result=recorder.run(name,base+list(args),work,stdin=stdin,expected=expected,empty_stderr=expected==0);checks+=1;return result
 run('cli-help',['--help']);run('cli-version',['--library-version'])
 a=strict_json(run('cli-unicode-file',['--input',str(source),'--format','json']))
 b=strict_json(run('cli-raw-stdin',['--stdin','--format','json'],payload));require(a==b,'File/stdin did not preserve control bytes')
 c=strict_json(run('cli-raw-binary',['--stdin','--binary','--format','json'],bytes(range(256))))
 require(c['diagnostics']['input_bytes']==256,'Binary byte length mismatch')
 d=strict_json(run('cli-hex',['--hex',bytes(range(256)).hex(),'--format','json']));require(c==d,'Binary stdin and hex differ')
 output=work/'出力 日😀.png';run('cli-unicode-output',['--text','日😀','--format','png','--output',str(output)]);check_png(output.read_bytes())
 before=file_sha(output);run('cli-refuse-overwrite',['--text','other','--format','png','--output',str(output)],expected=2);require(file_sha(output)==before,'Refused output was altered')
 run('cli-force-output',['--text','other','--format','png','--output',str(output),'--force']);require(file_sha(output)!=before,'Force did not replace output')
 ET.fromstring(run('cli-svg',['--text','日😀','--format','svg']))
 plan=strict_json(run('cli-plan',['--text','123456','--plan']));require(plan['ok'] is True and plan['requiredBits']>0,'CLI planning failed')
 run('cli-manual',['--segment','eci:26','--segment','byte:日😀','--format','json'])
 manual=strict_json(run('cli-manual-sa',['--segment','byte:'+('A'*100),'--structured-append','--version','1','--full-split-units','--symbol-diagnostics','--format','json']));require(2<=manual['total']<=16,'Manual SA failed');details=manual.get('diagnostics',{});require(details.get('split_units_detail')=='full' and len(details.get('split_units',[]))==100,'Manual SA full split diagnostics missing');require(len(details.get('symbols',[]))==manual['total'],'Manual SA symbol diagnostics missing');require(any(w.get('code')=='STRUCTURED_APPEND_DECODER_SUPPORT_VARIES' for w in details.get('warnings',[])),'Manual SA symbol-diagnostic detail was not requested')
 sa=strict_json(run('cli-sa',['--text','A'*100,'--structured-append','--version','1','--format','json']));require(2<=sa['total']<=16,'SA failed')
 for i,args in enumerate((['--text','a','--text','b'],['--text','a','--stdin'],['--text','x','--ecc','toString'],['--text','x','--version','1.0'],['--text','x','--scale','999999999999999999999999'],['--text','x','--dpi','Inf'],['--text','x','--bogus日'],['--text','x','--binary'],['--text','x','--max-symbols','2'])):
  run('cli-invalid-'+str(i),args,expected=2)
 for i,data in enumerate((b'\xff',b'\xed\xa0\x80',b'\xc0\x80')):run('cli-invalid-utf8-'+str(i),['--stdin'],data,expected=2)
 run('cli-missing-file',['--input',str(work/'missing日.txt')],expected=3)
 return {'checks':checks,'unicodePaths':True,'rawStdinControlBytes':True,'binaryBytes':256,'exclusiveCreate':True}


def consumer_checks(recorder,julia,consumer):
 consumer.mkdir(parents=True,exist_ok=False)
 depot=consumer/'depot';registry=depot/'registries'/'SpecQROfflineEmpty'/'Registry.toml';registry.parent.mkdir(parents=True)
 registry.write_text('name = "SpecQROfflineEmpty"\nuuid = "91b9f12c-7311-49a0-a727-f6f99c442502"\ndescription = "Empty local registry for offline stdlib-only verification"\n\n[packages]\n',encoding='utf-8')
 env=recorder.env.copy();env['JULIA_DEPOT_PATH']=str(depot)
 smoke='q=generate("clean 日😀";error_correction_level="Q")\n@assert size(q.matrix,1)==17+4q.version\n@assert startswith(to_svg(q),"<svg")\n@assert to_png(q)[1:8]==UInt8[137,80,78,71,13,10,26,10]\n'
 script=consumer/'consumer.jl';script.write_text('using Pkg\nPkg.offline(true)\nPkg.develop(path=ARGS[1])\nusing SpecQR, Base64\n'+smoke+'@assert Set(keys(Pkg.project().dependencies))==Set(["SpecQR"])\n@assert Set(p.name for p in values(Pkg.dependencies()))==Set(["SpecQR","Base64"])\n@assert length(Pkg.dependencies())==2\nprintln("SPECQR_CONSUMER_PASS")\n',encoding='utf-8')
 data=recorder.run('clean-pkg-consumer',[str(julia),'--startup-file=no','--history-file=no','--project='+str(consumer),script,ROOT],consumer,empty_stderr=False,env=env)
 require(data.strip()==b'SPECQR_CONSUMER_PASS','Clean package consumer failed')
 no_pkg=consumer/'no-pkg';no_pkg.mkdir();no_pkg_script=no_pkg/'consumer.jl'
 no_pkg_script.write_text('initial_modules=Set(keys(Base.loaded_modules))\ninclude(joinpath(ARGS[1],"src","SpecQR.jl"))\nusing .SpecQR\n'+smoke+'@assert all(id.name=="Base64" for id in setdiff(Set(keys(Base.loaded_modules)),initial_modules))\nprintln("SPECQR_NO_PKG_CONSUMER_PASS")\n',encoding='utf-8')
 no_pkg_env=env.copy();no_pkg_env['JULIA_DEPOT_PATH']=str(no_pkg/'empty-depot');no_pkg_env['JULIA_LOAD_PATH']='@stdlib'
 data=recorder.run('no-pkg-offline-consumer',[str(julia),'--startup-file=no','--history-file=no',no_pkg_script,ROOT],no_pkg,env=no_pkg_env)
 require(data.strip()==b'SPECQR_NO_PKG_CONSUMER_PASS','No-Pkg offline runtime consumer failed')
 return {'passed':True,'manifest':binding(consumer/'Manifest.toml'),'project':binding(consumer/'Project.toml'),'registryBootstrap':{'kind':'explicit empty local registry; no packages or remote sources','artifact':binding(registry)},'noPkgRuntimeConsumer':{'passed':True,'script':binding(no_pkg_script),'loadPath':'@stdlib; includes exact source file without Pkg calls','initialDepot':'absent; separate from Pkg and test depots'},'runtimeDependencyNames':['SpecQR','Base64']}

def main(argv=None):
 p=argparse.ArgumentParser();p.add_argument('--julia',required=True);p.add_argument('--expect-version',required=True);p.add_argument('--expect-platform',choices=['linux','windows','darwin'],required=True);p.add_argument('--expect-arch',required=True);p.add_argument('--source-archive',type=pathlib.Path,required=True);p.add_argument('--archive-sha256',required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--timeout',type=float,default=1800);p.add_argument('--check-bounds',choices=['yes','auto'],default='yes');a=p.parse_args(argv)
 out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);report={'status':'running','startedUtc':now(),'supportClaim':'Only the actual native lane in this report','profiles':a.check_bounds};target=out/'report.json'
 try:
  require(a.timeout>0 and a.timeout<float('inf'),'Timeout must be positive and finite')
  platform=check_platform(a.expect_platform,a.expect_arch);julia=pathlib.Path(resolve_command(a.julia));report['platform']=platform;report['juliaExecutable']=binding(julia);report['nativeImage']=require_native_image(julia,a.expect_platform,a.expect_arch)
  source=verify_source(ROOT);report['source']=source;fixtures=verify_fixtures(ROOT);report['fixtures']=fixtures;report['archive']=verify_archive(a.source_archive.resolve(),a.archive_sha256,source)
  env=os.environ.copy();env.update(JULIA_DEPOT_PATH=str(out/'depot'),JULIA_LOAD_PATH='@:@stdlib',JULIA_PKG_OFFLINE='true',JULIA_PKG_SERVER='',JULIA_PKG_PRECOMPILE_AUTO='0',JULIA_NUM_THREADS='4');env.pop('JULIA_PROJECT',None)
  recorder=Recorder(out/'receipts',source['manifestSha256'],env,a.timeout);report['receipts']=recorder.receipts;base=[str(julia),'--startup-file=no','--history-file=no','--check-bounds='+a.check_bounds,'--project='+str(ROOT)]
  report['runtime']=runtime_info(recorder.run('runtime',base+[ROOT/'scripts/bridge.jl','--runtime'],ROOT),a.expect_version,a.expect_platform,a.expect_arch)
  report['unitTests']=test_summary(recorder.run('unit-tests',base+[ROOT/'test/runtests.jl'],ROOT),a.expect_version)
  reference=out/'reference.json';recorder.run('reference',[sys.executable,ROOT/'scripts/verify_reference.py','--julia',julia,'--output',reference,'--timeout',str(a.timeout),'--check-bounds',a.check_bounds],ROOT);report['reference']=validate_reference(strict_json(reference.read_bytes()),julia,a.check_bounds)
  report['cli']=cli_checks(recorder,base+[ROOT/'bin/specqr.jl'],out/'cli files 日😀')
  report['consumer']=consumer_checks(recorder,julia,out/'clean-consumer')
  after=verify_source(ROOT);require(after==source,'Source changed during native verification');report['sourceStable']=True;report['receipts']=recorder.receipts;report['status']='passed'
 except BaseException as e:
  report['status']='failed';report['error']=repr(e);raise
 finally:
  report['finishedUtc']=now();write_json(target,report)
if __name__=='__main__':main()
