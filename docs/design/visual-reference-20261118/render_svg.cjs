const fs=require('fs');
const path=require('path');
const sharp=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES ? path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'sharp') : 'sharp');
async function main(){
 const dir=path.join(__dirname,'assets');
 for(const f of fs.readdirSync(dir).filter(f=>f.endsWith('.svg'))){
  const source=fs.readFileSync(path.join(dir,f));
  await sharp(source,{density:144}).png().toFile(path.join(dir,f.replace(/\.svg$/,'.png')));
  process.stdout.write(f+' rendered\n');
 }
}
main().catch(e=>{process.stderr.write(e.message+'\n');process.exit(1)});
