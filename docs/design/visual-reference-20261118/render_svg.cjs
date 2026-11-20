const fs=require('fs');
const path=require('path');
const sharp=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES ? path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'sharp') : 'sharp');
async function main(){
 const dir=path.join(__dirname,'assets');
 const requested=new Set(process.argv.slice(2).map(f=>f.replace(/\.(svg|png)$/,'')));
 const files=fs.readdirSync(dir).filter(f=>f.endsWith('.svg')&&(!requested.size||requested.has(f.replace(/\.svg$/,''))));
 for(const f of files){
  const source=fs.readFileSync(path.join(dir,f));
  await sharp(source,{density:144}).png().toFile(path.join(dir,f.replace(/\.svg$/,'.png')));
 }
 process.stdout.write(JSON.stringify({png_count:files.length,scale:2})+'\n');
}
main().catch(e=>{process.stderr.write(e.message+'\n');process.exit(1)});
