#!/usr/bin/env node
require('dotenv').config();
const crypto = require('crypto');
const { Pool } = require('pg');

const count = parseInt(process.argv[2]) || 10;

async function main() {
  const url = process.env.DATABASE_PUBLIC_URL || process.env.DATABASE_URL;
  if (!url) {
    console.error('Set DATABASE_PUBLIC_URL in .env');
    process.exit(1);
  }

  const db = new Pool({
    connectionString: url,
    ssl: { rejectUnauthorized: false }
  });

  // Ensure table exists
  await db.query(`
    CREATE TABLE IF NOT EXISTS codes (
      code TEXT PRIMARY KEY,
      used BOOLEAN NOT NULL DEFAULT false,
      used_by TEXT,
      used_at TIMESTAMPTZ,
      status TEXT DEFAULT 'available',
      eth_tx TEXT,
      mor_tx TEXT,
      error TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);

  const generated = [];
  for (let i = 0; i < count; i++) {
    const code = crypto.randomBytes(4).toString('hex').toUpperCase();
    try {
      await db.query('INSERT INTO codes (code) VALUES ($1) ON CONFLICT DO NOTHING', [code]);
      generated.push(code);
    } catch (err) {
      // skip duplicates
    }
  }

  const { rows: [stats] } = await db.query(
    `SELECT COUNT(*) FILTER (WHERE NOT used) AS available, COUNT(*) AS total FROM codes`
  );

  console.log(`Generated ${generated.length} invite code(s):`);
  generated.forEach(c => console.log(`  ${c}`));
  console.log(`\nTotal: ${stats.total} codes (${stats.available} available)`);

  await db.end();
}

main().catch(err => {
  console.error('Error:', err.message);
  process.exit(1);
});
