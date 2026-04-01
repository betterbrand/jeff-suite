#!/usr/bin/env node
require('dotenv').config();
const { Pool } = require('pg');

const url = process.env.DATABASE_PUBLIC_URL || process.env.DATABASE_URL;
if (!url) {
  console.error('Set DATABASE_PUBLIC_URL in .env');
  process.exit(1);
}

const db = new Pool({ connectionString: url, ssl: { rejectUnauthorized: false } });

async function main() {
  const { rows } = await db.query(
    'SELECT code, used, status, used_by, used_at FROM codes ORDER BY created_at'
  );

  const available = rows.filter(r => !r.used);
  const used = rows.filter(r => r.used);

  console.log(`\n${available.length} available, ${used.length} used, ${rows.length} total\n`);

  if (available.length) {
    console.log('Available:');
    available.forEach(r => console.log(`  ${r.code}`));
    console.log();
  }

  if (used.length) {
    console.log('Used:');
    used.forEach(r => console.log(`  ${r.code}  ${r.status}  ${(r.used_by || '').slice(0, 10)}...  ${r.used_at ? new Date(r.used_at).toLocaleString() : ''}`));
    console.log();
  }

  await db.end();
}

main().catch(err => { console.error(err.message); process.exit(1); });
