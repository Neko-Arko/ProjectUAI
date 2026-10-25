'use strict';
const fs = require('node:fs');
const readline = require('node:readline');
const log = value => fs.appendFileSync(process.env.UAI_CLINE_FIXTURE_LOG, JSON.stringify(value) + '\n');
const send = value => process.stdout.write(JSON.stringify(value) + '\n');
const result = (id,value) => send({jsonrpc:'2.0',id,result:value});
const sessionId='fixture-session';let model='free/model',promptId,nextId=100;
const pending=new Map();
const settings=JSON.parse(fs.readFileSync(process.env.CLINE_MCP_SETTINGS_PATH,'utf8'));
const mcp=settings.mcpServers.project_uai;
log({type:'start',pid:process.pid,directory:process.env.CLINE_DIR,providerSettings:process.env.CLINE_PROVIDER_SETTINGS_PATH,
  provider:process.env.CLINE_PROVIDER,ambientKeyPresent:!!process.env.CLINE_API_KEY});
const options=()=>[{id:'provider',currentValue:'cline'},{id:'auto_approve',currentValue:process.env.UAI_CLINE_FIXTURE_UNSAFE==='1'},
  {id:'model',currentValue:model}];
const permission=(title,rawInput,id=nextId++)=>new Promise(resolve=>{
  pending.set(id,resolve);send({jsonrpc:'2.0',id,method:'session/request_permission',params:{sessionId,
    toolCall:{toolCallId:'tool-'+id,title,kind:'other',rawInput},options:[{kind:'allow_once',optionId:'yes'},{kind:'reject_once',optionId:'no'}]}});
});
async function callMcp(method,params) {
  const response=await fetch(mcp.url,{method:'POST',headers:{...mcp.headers,'content-type':'application/json'},
    body:JSON.stringify({jsonrpc:'2.0',id:nextId++,method,params})});
  return (await response.json()).result;
}
async function prompt(id,params) {
  promptId=id;const text=params.prompt[0].text;log({type:'prompt'});
  if(text.includes('WAIT_FOR_STOP'))return;
  if(text.includes('HANDOFF')) {
    // Server-to-client request IDs may overlap the caller's pending prompt ID.
    const denied=await permission('run_commands: blocked',{commands:['forbidden']},id);
    log({type:'host-permission',outcome:denied.outcome});
    const listed=await callMcp('tools/list',{});log({type:'tools',names:listed.tools.map(tool=>tool.name)});
    const batch={calls:[{name:'lookup',arguments:{name:'世界'}},{name:'save',arguments:{value:2}}]};
    const allowed=await permission('project_uai__handoff',batch);log({type:'handoff-permission',outcome:allowed.outcome});
    if(allowed.outcome.optionId==='yes')await callMcp('tools/call',{name:'handoff',arguments:batch});
    else result(id,{stopReason:'end_turn'});
    return;
  }
  const line=Buffer.from(JSON.stringify({jsonrpc:'2.0',method:'session/update',params:{sessionId,
    update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'Fixture 世界'}}}})+'\n');
  const split=line.indexOf(Buffer.from('世'))+1;
  process.stdout.write(line.subarray(0,split));
  setTimeout(()=>{process.stdout.write(line.subarray(split));result(id,{stopReason:'end_turn'});},5);
}
readline.createInterface({input:process.stdin}).on('line',line=>{
  const item=JSON.parse(line);
  if(!item.method&&pending.has(item.id)){const resolve=pending.get(item.id);pending.delete(item.id);resolve(item.result);return;}
  switch(item.method) {
    case 'initialize':result(item.id,{protocolVersion:1,agentInfo:{name:'cline',version:'3.0.73'},authMethods:[{id:'cline',name:'Sign in with Cline'}]});break;
    case 'session/new':
      if(process.env.UAI_CLINE_FIXTURE_AUTH!=='yes')send({jsonrpc:'2.0',id:item.id,error:{code:-32000,message:'private-token=fixture-secret'}});
      else result(item.id,{sessionId,models:{availableModels:[{modelId:'free/model'},{modelId:'paid/model'}]},configOptions:options()});
      break;
    case 'session/set_config_option':model=process.env.UAI_CLINE_FIXTURE_WRONG_MODEL==='1'?'paid/model':item.params.value;result(item.id,{configOptions:options()});break;
    case 'session/prompt':prompt(item.id,item.params).catch(()=>result(item.id,{stopReason:'error'}));break;
    case 'session/cancel':log({type:'cancel'});if(promptId)result(promptId,{stopReason:'cancelled'});break;
  }
});
