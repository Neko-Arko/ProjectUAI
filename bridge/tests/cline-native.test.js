'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {Readable}=require('node:stream');
const {createCline,official,validateBatch,ENDPOINT}=require('../cline');
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function fixture(t,environment={},extra={}) {
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'uai-cline-fixture-'));
  const log=path.join(directory,'events.jsonl');
  const authSettings=path.join(directory,'auth','data','settings');fs.mkdirSync(authSettings,{recursive:true});
  fs.writeFileSync(path.join(authSettings,'providers.json'),JSON.stringify({version:1,providers:{cline:{settings:{provider:'cline',auth:{accessToken:'offline-fixture'}}}}}));
  const backend=createCline({enabled:true,binary:process.execPath,binaryArgs:[path.join(__dirname,'fixtures/cline-cli.js')],
    configDir:path.join(directory,'auth'),env:{...process.env,UAI_CLINE_FIXTURE_LOG:log,UAI_CLINE_FIXTURE_AUTH:'yes',...environment},
    fetch:async()=>({ok:true,body:Readable.from([Buffer.from(JSON.stringify({free:[{id:'free/model',name:'Free fixture'}],recommended:[{id:'paid/model'}]}))])}),...extra});
  const events=()=>fs.existsSync(log)?fs.readFileSync(log,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
  t.after(async()=>{
    await backend.close();
    for(const event of events().filter(event=>event.type==='start'))assert.equal(fs.existsSync(path.dirname(event.directory)),false,'private CLI session removed');
    const resolved=path.resolve(directory);
    assert.equal(path.dirname(resolved),path.resolve(os.tmpdir()));assert.match(path.basename(resolved),/^uai-cline-fixture-/);
    fs.rmSync(resolved,{recursive:true,force:true});
  });
  return {backend,events,directory};
}
const input=text=>JSON.stringify({model:'free/model',messages:[{role:'user',content:text}]});

test('Cline discovery reports the real login gate without leaking CLI errors',async t=>{
  const f=fixture(t,{UAI_CLINE_FIXTURE_AUTH:'no'});
  await assert.rejects(f.backend.start(),/Sign in/);
  assert.equal(f.backend.capability().state,'auth-required');assert.equal(f.backend.capability().available,false);
  assert.doesNotMatch(JSON.stringify(f.backend.capability()),/fixture-secret|private-token/);
  assert.equal(f.events().filter(event=>event.type==='prompt').length,0);
});
test('Cline discovers exact current free models and isolates credentials/configuration',async t=>{
  const f=fixture(t,{CLINE_API_KEY:'ambient-not-for-this-profile'});
  const result=await f.backend.models();
  assert.deepEqual(result.data.map(model=>model.id),['free/model']);
  assert.equal(result.data[0].supports_vision,false);assert.equal(f.backend.capability().state,'ready');
  const started=f.events().find(event=>event.type==='start');
  assert.equal(started.ambientKeyPresent,false);assert.equal(started.provider,'cline');
  assert.equal(started.providerSettings,path.join(f.directory,'auth','data','settings','providers.json'));
});
test('Cline refuses paid models, images and unsafe permission settings before inference',async t=>{
  const f=fixture(t);
  await assert.rejects(f.backend.request({url:ENDPOINT,body:input('paid').replace('free/model','paid/model')}),/not currently verified free/);
  await assert.rejects(f.backend.request({url:ENDPOINT,body:JSON.stringify({model:'free/model',messages:[{role:'user',content:[{type:'image_url',image_url:{url:'data:image/png;base64,AAAA'}}]}]})}),/text only/);
  assert.equal(f.events().length,0);
  const unsafe=fixture(t,{UAI_CLINE_FIXTURE_UNSAFE:'1'});
  await assert.rejects(unsafe.backend.start(),/permission settings/);
  assert.equal(unsafe.events().filter(event=>event.type==='prompt').length,0);
});
test('Cline preserves split Unicode chunks and returns one completed reply',async t=>{
  const f=fixture(t),frames=[];
  const result=await f.backend.request({url:ENDPOINT,body:input('TEXT'),onFrame:frame=>frames.push(frame)});
  assert.equal(JSON.parse(result.body).choices[0].message.content,'Fixture 世界');
  assert.equal(frames.map(frame=>frame.choices[0].delta.content||'').join(''),'Fixture 世界');
});
test('Cline denies native host actions and hands off a complete validated MCP batch',async t=>{
  const f=fixture(t),frames=[];
  const body=JSON.stringify({...JSON.parse(input('HANDOFF')),tools:['lookup','save'].map(name=>({type:'function',function:{name,parameters:{type:'object'}}}))});
  const result=await f.backend.request({url:ENDPOINT,body,onFrame:frame=>frames.push(frame)});
  const response=JSON.parse(result.body).choices[0];
  assert.equal(response.finish_reason,'tool_calls');assert.deepEqual(response.message.tool_calls.map(call=>call.function.name),['lookup','save']);
  assert.equal(JSON.parse(response.message.tool_calls[0].function.arguments).name,'世界');
  assert.deepEqual(frames.flatMap(frame=>frame.choices[0].delta.tool_calls||[]).map(call=>call.index),[0,1]);
  assert.equal(f.events().find(event=>event.type==='host-permission').outcome.optionId,'no');
  assert.equal(f.events().find(event=>event.type==='handoff-permission').outcome.optionId,'yes');
});
test('Cline cannot silently choose a paid replacement model',async t=>{
  const f=fixture(t,{UAI_CLINE_FIXTURE_WRONG_MODEL:'1'});
  await assert.rejects(f.backend.request({url:ENDPOINT,body:input('TEXT')}),/requested free model/);
  assert.equal(f.events().filter(event=>event.type==='prompt').length,0);
});
test('Cline preserves an explicit free promotion missing from the generic ACP catalog',async t=>{
  const f=fixture(t,{}, {fetch:async()=>({ok:true,body:Readable.from([Buffer.from(JSON.stringify({free:[{id:'free/promotion'}]}))])})});
  const models=await f.backend.models();assert.deepEqual(models.data.map(model=>model.id),['free/promotion']);
  const response=await f.backend.request({url:ENDPOINT,body:input('TEXT').replace('free/model','free/promotion')});
  assert.equal(JSON.parse(response.body).model,'free/promotion');
});
test('Cline bounds streamed promotion bytes and cannot reuse another provider login',async t=>{
  let reads=0;
  const f=fixture(t,{}, {fetch:async()=>({ok:true,body:Readable.from((async function*(){for(let i=0;i<20;i++){reads++;yield Buffer.alloc(1024*1024,32);}})())})});
  await assert.rejects(f.backend.request({url:ENDPOINT,body:input('TEXT')}),/catalog exceeded/);
  assert.ok(reads<=10);assert.equal(f.events().length,0);
  const other=fixture(t);
  fs.writeFileSync(path.join(other.directory,'auth','data','settings','providers.json'),JSON.stringify({providers:{'openai-codex':{settings:{provider:'openai-codex',auth:{accessToken:'not-a-cline-login'}}}}}));
  await assert.rejects(other.backend.start(),/Sign in/);assert.equal(other.events().length,0);
});
test('concurrent Cline discovery cannot exceed the four-process admission limit',async t=>{
  const f=fixture(t),controllers=Array.from({length:6},()=>new AbortController());
  const requests=controllers.map(controller=>f.backend.request({url:ENDPOINT,body:input('WAIT_FOR_STOP'),signal:controller.signal}));
  const finished=Promise.allSettled(requests);
  for(let attempt=0;attempt<200&&f.events().filter(event=>event.type==='prompt').length<4;attempt++)await pause(25);
  const started=f.events().filter(event=>event.type==='start').length;
  controllers.forEach(controller=>controller.abort());const outcomes=await finished;
  assert.equal(started,4);assert.equal(outcomes.filter(outcome=>outcome.reason?.status===503).length,2);
});
test('Stop kills the owned Cline request and removes private session files',async t=>{
  const f=fixture(t),controller=new AbortController();
  const request=f.backend.request({url:ENDPOINT,body:input('WAIT_FOR_STOP'),signal:controller.signal});
  const stopped=assert.rejects(request,/stopped/i);
  for(let attempt=0;attempt<200&&!f.events().some(event=>event.type==='prompt');attempt++)await pause(10);
  assert.ok(f.events().some(event=>event.type==='prompt'));controller.abort();await stopped;
  const started=f.events().find(event=>event.type==='start');
  assert.equal(fs.existsSync(path.dirname(started.directory)),false);
  assert.throws(()=>process.kill(started.pid,0));
});
test('disabled and missing Cline states stay distinct after a refused request',async t=>{
  for(const options of [{enabled:false},{binary:null}]) {
    const backend=createCline({enabled:true,...options});t.after(()=>backend.close());const expected=options.enabled===false?'disabled':'missing';
    await assert.rejects(backend.request({url:ENDPOINT,body:input('TEXT')}));assert.equal(backend.capability().state,expected);
  }
});
test('Cline rejects unknown endpoints and undeclared handoff tools',()=>{
  assert.equal(official(ENDPOINT),true);
  for(const value of [ENDPOINT+'?key=x',ENDPOINT+'#fragment',ENDPOINT.replace('https:','http:'),ENDPOINT.replace('/cline/','/other/')])assert.equal(official(value),false);
  assert.throws(()=>validateBatch({calls:[{name:'unknown',arguments:{}}]},new Map()),/undeclared/);
  assert.throws(()=>validateBatch({calls:[]},new Map()),/invalid/);
  assert.throws(()=>validateBatch({calls:[{name:'lookup',arguments:{},command:'forbidden'}]},new Map([['lookup',{}]])),/unexpected/);
  assert.throws(()=>validateBatch({calls:[{name:'lookup',arguments:{}}],command:'forbidden'},new Map([['lookup',{}]])),/invalid/);
});
