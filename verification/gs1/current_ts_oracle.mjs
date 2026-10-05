// Optional audit generator. Runtime and package tests do not require Node.js.
// Usage: node current_ts_oracle.mjs /absolute/path/to/SpecQR checkout gs1-upstream.json
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const source=path.resolve(process.argv[2]);
const g=await import(pathToFileURL(path.join(source,'src/gs1.js')));
const raw=await import(pathToFileURL(path.join(source,'src/gs1/validator.js')));
const mappings={dictionary:'getSupportedGs1Ais',info:'getGs1AiInfo',checkDigit:'calculateGs1CheckDigit',validateCheckDigit:'validateGs1CheckDigit',gtinDigit:'calculateGtinCheckDigit',gtinAppend:'appendGtinCheckDigit',gtinValidate:'validateGtinCheckDigit',ssccDigit:'calculateSsccCheckDigit',ssccAppend:'appendSsccCheckDigit',ssccValidate:'validateSsccCheckDigit',human:'parseGs1HumanReadable',create:'createGs1ElementString',validateElements:'validateGs1Elements',validateRaw:'validateGs1ElementString',linkCreate:'createGs1DigitalLink',linkParse:'parseGs1DigitalLink',linkValidate:'validateGs1DigitalLink',linkNormalize:'normalizeGs1DigitalLink'};
const corpus=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const out=corpus.cases.map(f=>{
  try {
    if(f.op==='raw')return {elements:raw.parseGs1ElementString(f.input),hasSeparators:f.input.includes('\x1d')};
    return g[mappings[f.op]](Object.hasOwn(f,'elements')?f.elements:f.input,f.options);
  } catch(e) {return {throws:{code:e.code,message:e.message}};}
});
process.stdout.write(JSON.stringify(out));
