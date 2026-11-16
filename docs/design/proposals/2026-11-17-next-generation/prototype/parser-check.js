// Exercise the actual parser shipped in index.html, not a second implementation.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const start = html.indexOf('function safeCalculate(source)');
const end = html.indexOf('\nfunction calculate()', start);
if (start < 0 || end < 0) throw new Error('Cannot locate prototype parser');
const safeCalculate = vm.runInNewContext(html.slice(start, end) + '; safeCalculate', Object.create(null), {timeout: 1000});
const cases=[['(248 + 136) × 0.85','326.4'],['-(-4)+.5','4.5'],['2*(3+4)/2','7'],['0.1 + 0.2','0.3']];
for(const [expr,result] of cases){if(safeCalculate(expr)!==result)throw Error(expr);}
for(const expr of ['1/0','2+','alert(1)','2**3','(1+2']){let threw=false;try{safeCalculate(expr)}catch{threw=true}if(!threw)throw Error('Should reject: '+expr)}
console.log(JSON.stringify({scope:'prototype parser',validCases:4,rejectedCases:5,passed:true}));
