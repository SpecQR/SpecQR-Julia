#!/usr/bin/env python3
import pathlib,subprocess,unittest,tempfile,shutil
from unittest.mock import patch
import verify_gs1 as v
from native_support import ValidationError
class FailClosedTests(unittest.TestCase):
 def proc(self,out=b'{}\n',err=b'',code=0):return subprocess.CompletedProcess(['test'],code,out,err)
 def test_clean(self):self.assertEqual(v.validate_process(self.proc(),1),[{}])
 def test_nonzero(self):
  with self.assertRaises(ValidationError):v.validate_process(self.proc(code=1),1)
 def test_stderr(self):
  with self.assertRaises(ValidationError):v.validate_process(self.proc(err=b'unexpected'),1)
 def test_extra(self):
  with self.assertRaises(ValidationError):v.validate_process(self.proc(b'{}\n{}\n'),1)
 def test_missing(self):
  with self.assertRaises(ValidationError):v.validate_process(self.proc(b''),1)
 def test_terminator(self):
  with self.assertRaises(ValidationError):v.validate_process(self.proc(b'{}'),1)
 def test_duplicate(self):
  with self.assertRaises(ValidationError):v.validate_process(self.proc(b'{"ok":true,"ok":false}\n'),1)
 def test_nonfinite(self):
  with self.assertRaises(ValidationError):v.validate_process(self.proc(b'NaN\n'),1)
 def test_invalid_utf8(self):
  with self.assertRaises(ValidationError):v.validate_process(self.proc(b'"\xff"\n'),1)
 def test_boolean_not_integer(self):self.assertFalse(v.same({'ok':True},{'ok':1}))
 def test_payload_not_omitted(self):self.assertFalse(v.same({'elements':[{'ai':'10','value':'x'}]},{'elements':[{'ai':'10','value':'y'}]}))
 def test_count_not_omitted(self):self.assertFalse(v.same({'code':'X','message':'a','count':1},{'code':'X','message':'b','count':2}))
 def test_reason_not_omitted(self):self.assertFalse(v.same({'code':'X','message':'a','reason':'a'},{'code':'X','message':'b','reason':'b'}))
 def test_wording_only_allowed(self):self.assertTrue(v.same({'code':'X','message':'a'},{'code':'X','message':'b'}))
 def test_all_bound_contracts(self):
  q,w,ts,ids=v.contracts();self.assertEqual((len(q),len(w),len(ids)),(1411,1411,80))
 def test_fixture_tamper(self):
  with tempfile.TemporaryDirectory()as d:
   root=pathlib.Path(d);(root/'verification/fixtures').mkdir(parents=True)
   (root/'verification/fixtures/approved-restorations80.json').write_text('{}')
   with patch.object(v,'ROOT',root),self.assertRaises(ValidationError):v.fixture('approved-restorations80.json')
if __name__=='__main__':unittest.main()
