/** One-time import; run locally ONLY. Never deploy the service role key. */
import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const url=process.env.SUPABASE_URL?.trim();
const secret=(process.env.SUPABASE_SECRET_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY)?.trim();
if(!url||!secret||url.includes('YOUR-PROJECT')||secret.includes('YOUR_')) {
 console.error('Missing SUPABASE_URL / SUPABASE_SECRET_KEY in .env.local.');process.exit(1);
}
const db=createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
const data=JSON.parse(readFileSync(path.join(root,'seed/requirements.json'),'utf8'));
const {data:workspace,error:workspaceError}=await db.from('board_projects').select('id').eq('slug','website-requirements-original').single();
if(workspaceError)throw new Error('Run supabase/upgrade_multi_project.sql before import: '+workspaceError.message);
const projectId=workspace.id;
const requiredCategories=[...new Set(data.tasks.map(t=>t.category))].filter(Boolean);
for(const name of requiredCategories){
  const {data:existing,error:lookupError}=await db.from('board_categories').select('id').eq('project_id',projectId).eq('name',name).limit(1);
  if(lookupError)throw lookupError;
  if(!existing?.length){
    const {error}=await db.from('board_categories').insert({project_id:projectId,name,sort_order:100});
    if(error)throw error;
  }
}

const paths=[...new Set([...data.tasks.flatMap(t=>[...t.sources,...t.references]),...data.extras])];
console.log(`Importing ${data.tasks.length} requirements and ${paths.length} private images...`);
let uploaded=0,skipped=0;
for(const target of paths){
 const file=path.join(root,'seed/images',path.basename(target));
 const bytes=readFileSync(file);
 const {error}=await db.storage.from('requirements-private').upload(target,bytes,{contentType:'image/png',upsert:false});
 if(error){
  if(/already exists|duplicate|resource exists/i.test(error.message)||error.statusCode===409){skipped++;continue;}
  console.error(`Upload failed for ${target}: ${error.message}`);process.exit(1);
 }
 uploaded++;
}
const reqs=data.tasks.map((row,idx)=>({...row,project_id:projectId,priority:'normal',sort_order:(idx+1)*100}));
const {error:reqErr}=await db.from('requirements').upsert(reqs,{onConflict:'id',ignoreDuplicates:true});
if(reqErr)throw new Error('Requirement seed failed: '+reqErr.message);
const assets=data.extras.map((path,idx)=>({path,label:`独立参考素材 ${idx+1}`,project_id:projectId,sort_order:(idx+1)*100}));
const {error:assetErr}=await db.from('board_assets').upsert(assets,{onConflict:'path',ignoreDuplicates:true});
if(assetErr)throw new Error('Extra assets seed failed: '+assetErr.message);
const {count,error:countErr}=await db.from('requirements').select('id',{head:true,count:'exact'});
if(countErr)throw countErr;
console.log(`Done. ${uploaded} images uploaded, ${skipped} already existed. ${count} requirements in DB.`);
console.log('Existing requirements are NOT overwritten when importing again.');
