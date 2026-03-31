#!/usr/bin/env node
const fs = require('fs');
const crypto = require('crypto');
const path = require('path');

const count = parseInt(process.argv[2]) || 10;
const codesFile = path.join(__dirname, 'codes.json');

let codes = {};
if (fs.existsSync(codesFile)) {
  codes = JSON.parse(fs.readFileSync(codesFile, 'utf8'));
}

const generated = [];
for (let i = 0; i < count; i++) {
  const code = crypto.randomBytes(4).toString('hex').toUpperCase();
  if (!codes[code]) {
    codes[code] = { used: false };
    generated.push(code);
  }
}

fs.writeFileSync(codesFile, JSON.stringify(codes, null, 2) + '\n');
console.log(`Generated ${generated.length} invite code(s):`);
generated.forEach(c => console.log(`  ${c}`));
console.log(`\nTotal codes: ${Object.keys(codes).length}`);
