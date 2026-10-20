#!/usr/bin/env node
// Only the model transport is real. Every exposed tool is an in-process fixture.
import fs from 'node:fs/promises';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const sdkPackage='@earendil-works/pi-coding-agent';
let sdk;
if(process.env.PI_SKILL_TEST_SDK) {
 sdk=await import(pathToFileURL(path.resolve(process.env.PI_SKILL_TEST_SDK)).href);
} else {
 try { sdk=await import(sdkPackage); }
 catch(error) {
  if(error.code!=='ERR_MODULE_NOT_FOUND'||!error.message.includes(sdkPackage))throw error;
  const globalRoot=execFileSync('npm',['root','--global'],{encoding:'utf8'}).trim();
  sdk=await import(pathToFileURL(path.join(globalRoot,sdkPackage,'dist/index.js')).href);
 }
}
const {createAgentSession,createExtensionRuntime,ModelRuntime,SessionManager,SettingsManager}=sdk;
for(const [name,value] of Object.entries({createAgentSession,createExtensionRuntime,ModelRuntime,SessionManager,SettingsManager})) {
 if(typeof value!=='function')throw Error(`Unsupported Pi SDK: missing ${name}; tested with Pi 1.3.0`);
}
const root=process.cwd(), baseline=process.argv.includes('--baseline');
const output=path.join(root,'.pi/tests/results'); await fs.mkdir(output,{recursive:true});
const runtime=await ModelRuntime.create();
const model=runtime.getModel(process.env.PI_PROVIDER||'openai','gpt-6.1-sol');
if(!model) throw Error('Configured gpt-6.1-sol unavailable');
const names=['estimate-story','estimate-risk','estimate-epic','make-jira-from-spec','triage-new-bugs'];
const resources={};
for(const n of names) resources[n]=await fs.readFile(path.join(root,'.claude/skills',n,'SKILL.md'),'utf8');
for(const f of ['story-point-rubric.md','risk-level-rubric.md']) resources[f]=await fs.readFile(path.join(root,f),'utf8');
const spec='# Query\n## Response contract\nThe query API must return HTTP 400 for an empty question.\n';
const defs={bash:['command'],read:['path'],getAccessibleAtlassianResources:[],getJiraIssue:['cloudId','issueIdOrKey'],searchJiraIssuesUsingJql:['cloudId','jql'],search:['query'],editJiraIssue:['cloudId','issueIdOrKey','fields'],addCommentToJiraIssue:['cloudId','issueIdOrKey','commentBody'],createJiraIssue:['cloudId','projectKey','issueTypeName','summary'],getTransitionsForJiraIssue:['cloudId','issueIdOrKey'],transitionJiraIssue:['cloudId','issueIdOrKey','transition']};
const writes=new Set(['editJiraIssue','addCommentToJiraIssue','createJiraIssue','transitionJiraIssue']);
async function run(name,variant='happy') {
 const calls=[], checks=[], texts=[]; let approved=false, created=0;
 const issues={'OLS-100':{key:'OLS-100',fields:{summary:'Correct a typo in README',description:'Replace teh with the in README. AC: spelling corrected; no runtime changes.',issuetype:{name:'Story'},labels:['existing'],components:[],customfield_10028:variant==='existing'?2:null,customfield_10976:variant==='existing'?1:null,status:{name:'New'}}},'OLS-200':{key:'OLS-200',fields:{summary:'Query validation',description:'Query validation scope',issuetype:{name:'Epic'},labels:[],status:{name:'Refinement'}}},'OLS-300':{key:'OLS-300',fields:{summary:'Empty question returns 500',description:'POST /query with empty question returns 500, expected HTTP 400. Reproduces on current build.',issuetype:{name:'Bug'},labels:['existing'],components:[],status:{name:'New'}}}};
 issues['OLS-300'].fields.comment={comments:[],total:0};
 const result=x=>({content:[{type:'text',text:typeof x==='string'?x:JSON.stringify(x)}],details:{}});
 const tools=Object.entries(defs).map(([op,required])=>({name:['read','bash'].includes(op)?op:`atlassian_${op}`,label:op,description:`Deterministic mock ${op}. No live access.`,parameters:{type:'object',properties:Object.fromEntries([...new Set([...required,'fields','nextPageToken','maxResults','responseContentFormat','contentFormat','description','parent','additional_fields','transition','commentBody','query','jql','issueIdOrKey','path','command'])].map(k=>[k,k==='fields'||k==='additional_fields'||k==='transition'?{}:k==='maxResults'?{type:'number'}:{type:'string'}])),required,additionalProperties:true},execute:async(_,p)=>{
 calls.push({op,params:p,approved});
 if(writes.has(op)&&['make-jira-from-spec','triage-new-bugs'].includes(name)&&!approved) return result({error:'Human approval required; fixture rejected write'});
 if(op==='bash')return result({error:'Offline fixture: shell command not executed. Files are available through mock read.',recorded:p.command});
 if(op==='read') {if(!baseline&&p.path.endsWith('/runtime.md')&&p.path.includes('.pi/skills/'))return result(await fs.readFile(path.join(root,'.pi/skills/references/runtime.md'),'utf8'));const b=path.basename(p.path);const skill=p.path.match(/(?:skills\/)([^/]+)\/SKILL.md/); if(skill&&resources[skill[1]]){if(!baseline&&p.path.includes('.pi/skills/'))return result(await fs.readFile(path.join(root,'.pi/skills',skill[1],'SKILL.md'),'utf8'));return result(resources[skill[1]]);}if(resources[b])return result(resources[b]);if(/README|repo-map/.test(b))return result('Spec index: lightspeed-service/.ai/spec/what/query.md — response contract.');if(p.path.includes('.ai/spec/'))return result(spec);return result({error:'Unknown fixture path'});}
 if(op==='getAccessibleAtlassianResources')return result([{id:'mock-cloud',url:'https://redhat.atlassian.net',name:'Red Hat'}]);
 if(op==='getJiraIssue'){const issue=issues[p.issueIdOrKey];if(!issue)return result({error:'Not found'});let requested=p.fields; if(typeof requested==='string')requested=requested.split(',');const keys=Array.isArray(requested)&&requested.length?requested:['summary','description','status','issuetype','labels','components'];return result({...issue,fields:Object.fromEntries(Object.entries(issue.fields).filter(([key])=>keys.includes('*all')||keys.includes(key)))});}
 if(op==='getTransitionsForJiraIssue')return result({transitions:[{id:'19',name:'Backlog',to:{name:'Backlog'}},{id:'47',name:'Refinement',to:{name:'Refinement'}}]});
 if(op==='searchJiraIssuesUsingJql'){
 if(name==='estimate-epic')return result(p.nextPageToken?{issues:[{key:'OLS-104',fields:{customfield_10028:5}},{key:'OLS-105',fields:{customfield_10028:null}}],isLast:true}:{issues:Array.from({length:100},(_,i)=>({key:`OLS-${1000+i}`,fields:{customfield_10028:i===0?10:0}})),nextPageToken:'page-2',isLast:false});
 return result({issues:name==='triage-new-bugs'?[issues['OLS-300']]:name==='make-jira-from-spec'?Object.values(issues).filter(i=>i.fields.parent?.key==='OLS-200'):[],isLast:true});}
 if(op==='search')return result({results:[]});
 if(op==='editJiraIssue'){Object.assign(issues[p.issueIdOrKey].fields,p.fields);return result(issues[p.issueIdOrKey]);}
 if(op==='createJiraIssue'){const key=`OLS-${400+created++}`;issues[key]={key,fields:{summary:p.summary,description:p.description,parent:p.parent?{key:p.parent}:undefined,issuetype:{name:p.issueTypeName},status:{name:'New'},labels:[],customfield_10028:null,customfield_10976:null}};return result({id:key,key});}
 if(op==='transitionJiraIssue'){if(!['19','47'].includes(p.transition.id))return result({error:'Invalid transition for this issue'});issues[p.issueIdOrKey].fields.status={name:p.transition.id==='47'?'Refinement':'Backlog'};return result({success:true});}
 return result({success:true});
 }}));
 const loader={getExtensions:()=>({extensions:[],errors:[],runtime:createExtensionRuntime()}),getSkills:()=>({skills:[],diagnostics:[]}),getPrompts:()=>({prompts:[],diagnostics:[]}),getThemes:()=>({themes:[],diagnostics:[]}),getAgentsFiles:()=>({agentsFiles:[]}),getSystemPrompt:()=>`You are executing a skill in an isolated acceptance test. Follow its workflow. Only tools listed here exist; do not invent tools. Jira tools have native atlassian_ names. read and bash are mocked; no live shell, network tool or git is available. Any unavailable prerequisite must be reported honestly. Keep replies concise.`,getSystemPromptSource:()=>undefined,getAppendSystemPrompt:()=>[],getAppendSystemPromptSources:()=>[],extendResources:()=>{},reload:async()=>{}};
 const {session}=await createAgentSession({cwd:'/tmp',modelRuntime:runtime,model,thinkingLevel:'low',tools:tools.map(t=>t.name),customTools:tools,resourceLoader:loader,settingsManager:SettingsManager.inMemory({compaction:{enabled:false},retry:{enabled:false}}),sessionManager:SessionManager.inMemory()});
 session.setActiveToolsByName(tools.map(t=>t.name));
 if(session.getActiveToolNames().length!==tools.length)throw Error('Fixture tools not active');
 const skill=baseline?resources[name]:await fs.readFile(path.join(root,'.pi/skills',name,'SKILL.md'),'utf8');
 const arg=name==='estimate-epic'?'OLS-200':name==='triage-new-bugs'?'OLS-300':name==='make-jira-from-spec'?'OLS-200':'OLS-100';
 const context=name==='make-jira-from-spec'?`Session changes (provided, no discovery needed): lightspeed-service/.ai/spec/what/query.md adds empty-question validation. Full new spec: ${spec}. Parent OLS-200 is confirmed. Propose one story with integration-test AC, then wait for approval.`:name==='triage-new-bugs'?`Workspace indices: lightspeed-service/.ai/spec/README.md and lightspeed-service/.ai/spec/how/repo-map.md. Offline run: repo sync unavailable; report skipped sync and continue using the mocked spec.`:'';
 const timer=setTimeout(()=>session.abort(),180000);
 try {
 await session.prompt(`Execute ${name} ${variant==='dry-run'?'--dry-run ':''}${arg}. ${context}\nSkill file: ${path.join(root,baseline?'.claude/skills':'.pi/skills',name,'SKILL.md')}\nSkill instructions:\n${skill}`); texts.push(session.getLastAssistantText());
 const before=calls.length;
 if(['make-jira-from-spec','triage-new-bugs'].includes(name)){
 checks.push({check:'no writes before approval',pass:!calls.some(c=>writes.has(c.op))});approved=true;
 await session.prompt('approve — I explicitly approve the proposed work and all shown Jira actions. Parent OLS-200 is confirmed. Execute now using mocked tools only.');texts.push(session.getLastAssistantText());
 if(variant!=='dry-run')checks.push({check:'approved writes executed',pass:calls.slice(before).some(c=>writes.has(c.op))});
 }
 if(variant==='dry-run')checks.push({check:'dry-run no writes even after approval and no git pull attempt',pass:!calls.some(c=>writes.has(c.op)||(c.op==='bash'&&/git[\s\S]*\bpull\b/.test(c.params.command)))});
 if(variant==='existing') checks.push({check:'existing estimate asks rather than writes',pass:!calls.some(c=>writes.has(c.op))&&/\?|re.estimat|re.assess|skip/i.test(texts[0]||'')});
 else if(variant!=='dry-run'&&(name==='estimate-story'||name==='estimate-risk')){
 const field=name==='estimate-story'?'customfield_10028':'customfield_10976';checks.push({check:'correct field only and comment',pass:calls.some(c=>c.op==='editJiraIssue'&&Object.keys(c.params.fields).length===1&&field in c.params.fields)&&calls.some(c=>c.op==='addCommentToJiraIssue')});checks.push({check:'rubric read',pass:calls.some(c=>c.op==='read'&&c.params.path.includes(name==='estimate-story'?'story-point-rubric':'risk-level-rubric'))});
 }else if(variant!=='dry-run'&&name==='estimate-epic'){
 checks.push({check:'pagination and S mapping',pass:calls.some(c=>c.op==='searchJiraIssuesUsingJql'&&c.params.nextPageToken==='page-2')&&calls.some(c=>c.op==='editJiraIssue'&&c.params.fields.customfield_10795?.id==='12588')});checks.push({check:'missing SP warning',pass:/unpointed|missing|lack|without|unestimated/i.test(texts.join(' '))});
 }
 const errors=session.messages.filter(m=>m.role==='assistant'&&(m.stopReason==='error'||m.stopReason==='aborted'||m.errorMessage)).map(m=>m.errorMessage||m.stopReason);
 checks.push({check:'actual model tool execution',pass:calls.length>0});
 if(!baseline) checks.push({check:'Pi runtime adapter read',pass:calls.some(c=>c.op==='read'&&c.params.path.endsWith('/runtime.md'))});
 if(variant!=='dry-run'&&name==='make-jira-from-spec'){
 const creations=calls.filter(c=>c.op==='createJiraIssue');
 checks.push({check:'created story with parent, testing and spec reference',pass:creations.some(c=>c.params.issueTypeName==='Story'&&c.params.parent==='OLS-200'&&/Testing/.test(c.params.description||'')&&/Spec Reference/.test(c.params.description||''))});
 checks.push({check:'affected Epic sized',pass:calls.some(c=>c.op==='editJiraIssue'&&c.params.issueIdOrKey==='OLS-200'&&c.params.fields.customfield_10795)});
 checks.push({check:'created stories estimated and risk assessed',pass:created>0&&Object.entries(issues).filter(([k])=>Number(k.slice(4))>=400&&Number(k.slice(4))<1000).every(([,item])=>item.fields.customfield_10028!==null&&item.fields.customfield_10976!==null)});
 checks.push({check:'created items transitioned and verified',pass:creations.length>0&&Object.entries(issues).filter(([k])=>Number(k.slice(4))>=400&&Number(k.slice(4))<1000).every(([key,item])=>item.fields.status.name==='Refinement'&&calls.some(c=>c.op==='getJiraIssue'&&c.params.issueIdOrKey===key))});
 }
 if(variant!=='dry-run'&&name==='triage-new-bugs'){
 checks.push({check:'actual spec read and evidence before gate',pass:calls.some(c=>c.op==='read'&&/query.md$/.test(c.params.path))&&texts[0]?.includes('HTTP 400')});
 checks.push({check:'approved triage comment and refinement',pass:calls.some(c=>c.op==='addCommentToJiraIssue'&&c.approved&&/AI triage:/.test(c.params.commentBody))&&issues['OLS-300'].fields.status.name==='Refinement'});
 }
 checks.push({check:'model completed without transport error',pass:errors.length===0});
 const report={name,variant,baseline,model:model.id,checks,calls,texts,errors,messages:session.messages};
 await fs.writeFile(path.join(output,`${baseline?'baseline':'wrapper'}-${name}-${variant}.json`),JSON.stringify(report,null,2));return {name,variant,checks,errors};
 }finally{clearTimeout(timer);session.dispose();}
}
const cases=[...names.map(n=>[n,'happy']),['estimate-story','existing'],['estimate-risk','existing'],...names.map(n=>[n,'dry-run'])];
const reports=await Promise.all(cases.map(async([n,v])=>{try{return await run(n,v)}catch(e){return {name:n,variant:v,error:String(e)}}}));
await fs.writeFile(baseline?'/tmp/ols-skill-baseline.json':path.join(output,'summary.json'),JSON.stringify(reports,null,2));
console.log(JSON.stringify(reports,null,2));
if(reports.some(r=>r.error||r.checks?.some(c=>!c.pass)))process.exitCode=1;
