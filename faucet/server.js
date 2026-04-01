require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { ethers } = require('ethers');
const { Pool } = require('pg');

const app = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.PORT || 3456;
const MOR_TOKEN = process.env.MOR_TOKEN || '0x7431aDa8a591C955a994a21710752EF9b882b8e3';
const MOR_AMOUNT = process.env.MOR_AMOUNT || '3';
const ETH_AMOUNT = process.env.ETH_AMOUNT || '0.00005';
const MAX_TOTAL_MOR = parseFloat(process.env.MAX_TOTAL_MOR || '300');
const MAX_TOTAL_ETH = parseFloat(process.env.MAX_TOTAL_ETH || '0.005');

const ERC20_ABI = [
  'function transfer(address to, uint256 amount) returns (bool)',
  'function balanceOf(address) view returns (uint256)'
];

// Rate limiting (in-memory, per-instance)
const ipTimestamps = new Map();
const RATE_LIMIT_MS = 60000;

const crypto = require('crypto');

let provider, wallet, morContract, db;

// --- Admin auth ---

function requireAdmin(req, res, next) {
  if (!process.env.ADMIN_SECRET) {
    return res.status(503).json({ error: 'Admin endpoints not configured' });
  }
  const secret = req.headers['x-admin-secret'];
  if (!secret || secret.length !== process.env.ADMIN_SECRET.length) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  try {
    if (!crypto.timingSafeEqual(Buffer.from(secret), Buffer.from(process.env.ADMIN_SECRET))) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
  } catch {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
}

// --- Database ---

async function initDb() {
  db = new Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.DATABASE_URL?.includes('railway') ? { rejectUnauthorized: false } : false
  });

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
}

// --- Routes ---

app.get('/health', async (req, res) => {
  try {
    const { rows: [stats] } = await db.query(`
      SELECT
        COUNT(*) AS total,
        COUNT(*) FILTER (WHERE used) AS used,
        COUNT(*) FILTER (WHERE NOT used) AS available
      FROM codes
    `);
    const disbursed = {
      mor: parseInt(stats.used) * parseFloat(MOR_AMOUNT),
      eth: parseInt(stats.used) * parseFloat(ETH_AMOUNT)
    };
    res.json({
      status: 'ok',
      codes: { total: parseInt(stats.total), used: parseInt(stats.used), available: parseInt(stats.available) },
      disbursed,
      budget: { maxMor: MAX_TOTAL_MOR, maxEth: MAX_TOTAL_ETH }
    });
  } catch (err) {
    res.status(500).json({ status: 'error', error: 'Database unavailable' });
  }
});

// --- Admin routes ---

app.get('/admin/codes', requireAdmin, async (req, res) => {
  try {
    const { rows } = await db.query(
      'SELECT code, used, status, used_by, used_at, eth_tx, mor_tx, created_at FROM codes ORDER BY created_at DESC'
    );
    const { rows: [stats] } = await db.query(`
      SELECT COUNT(*) AS total,
             COUNT(*) FILTER (WHERE used) AS used,
             COUNT(*) FILTER (WHERE NOT used) AS available
      FROM codes
    `);
    res.json({ codes: rows, stats: { total: parseInt(stats.total), used: parseInt(stats.used), available: parseInt(stats.available) } });
  } catch (err) {
    res.status(500).json({ error: 'Database error' });
  }
});

app.post('/admin/generate', requireAdmin, async (req, res) => {
  const count = Math.min(Math.max(parseInt(req.body.count) || 5, 1), 50);
  const generated = [];
  try {
    for (let i = 0; i < count; i++) {
      const code = crypto.randomBytes(6).toString('hex').toUpperCase();
      const { rowCount } = await db.query('INSERT INTO codes (code) VALUES ($1) ON CONFLICT DO NOTHING', [code]);
      if (rowCount > 0) generated.push(code);
    }
    const { rows: [stats] } = await db.query(`
      SELECT COUNT(*) AS total, COUNT(*) FILTER (WHERE NOT used) AS available FROM codes
    `);
    console.log(`Admin: generated ${generated.length} codes`);
    res.json({ generated, stats: { total: parseInt(stats.total), available: parseInt(stats.available) } });
  } catch (err) {
    res.status(500).json({ error: 'Database error' });
  }
});

// --- Public routes ---

app.post('/fund', async (req, res) => {
  const { code, address } = req.body;

  if (!code || !address) {
    return res.status(400).json({ error: 'Missing code or address' });
  }

  if (!ethers.isAddress(address)) {
    return res.status(400).json({ error: 'Invalid Ethereum address' });
  }

  // Rate limit by IP
  const ip = req.socket.remoteAddress;
  const lastRequest = ipTimestamps.get(ip);
  if (lastRequest && Date.now() - lastRequest < RATE_LIMIT_MS) {
    return res.status(429).json({ error: 'Rate limited. Try again in a minute.' });
  }
  ipTimestamps.set(ip, Date.now());

  try {
    // Atomic claim: mark code as used only if it exists and is unused
    const { rows } = await db.query(
      `UPDATE codes SET used = true, used_by = $1, used_at = NOW(), status = 'in-flight'
       WHERE code = $2 AND used = false
       RETURNING *`,
      [address, code]
    );

    if (rows.length === 0) {
      // Check if code exists at all
      const { rows: existing } = await db.query('SELECT used FROM codes WHERE code = $1', [code]);
      if (existing.length === 0) {
        return res.status(403).json({ error: 'Invalid invite code' });
      }
      return res.status(403).json({ error: 'Invite code already used' });
    }

    // Check budget cap
    const { rows: [stats] } = await db.query(
      `SELECT COUNT(*) AS used FROM codes WHERE used = true`
    );
    const totalUsed = parseInt(stats.used);
    if (totalUsed * parseFloat(MOR_AMOUNT) > MAX_TOTAL_MOR) {
      // Rollback the claim
      await db.query(`UPDATE codes SET used = false, used_by = NULL, used_at = NULL, status = 'available' WHERE code = $1`, [code]);
      return res.status(503).json({ error: 'Faucet MOR budget depleted' });
    }
    if (totalUsed * parseFloat(ETH_AMOUNT) > MAX_TOTAL_ETH) {
      await db.query(`UPDATE codes SET used = false, used_by = NULL, used_at = NULL, status = 'available' WHERE code = $1`, [code]);
      return res.status(503).json({ error: 'Faucet ETH budget depleted' });
    }

    // Send ETH
    const ethTx = await wallet.sendTransaction({
      to: address,
      value: ethers.parseEther(ETH_AMOUNT)
    });

    // Send MOR
    const morTx = await morContract.transfer(
      address,
      ethers.parseUnits(MOR_AMOUNT, 18)
    );

    // Mark completed
    await db.query(
      `UPDATE codes SET status = 'completed', eth_tx = $1, mor_tx = $2 WHERE code = $3`,
      [ethTx.hash, morTx.hash, code]
    );

    console.log(`Funded ${address} via code ${code}: ETH=${ethTx.hash} MOR=${morTx.hash}`);

    res.json({
      success: true,
      ethTx: ethTx.hash,
      morTx: morTx.hash,
      mor: MOR_AMOUNT,
      eth: ETH_AMOUNT
    });
  } catch (err) {
    console.error(`Fund error for ${address}:`, err.message);
    // Mark failed but keep used=true so code can't be reused
    await db.query(
      `UPDATE codes SET status = 'failed', error = $1 WHERE code = $2`,
      [err.message.slice(0, 500), code]
    ).catch(() => {});
    res.status(500).json({ error: 'Transaction failed' });
  }
});

// --- Startup ---

async function start() {
  if (!process.env.FAUCET_PRIVATE_KEY) {
    console.error('FAUCET_PRIVATE_KEY not set');
    process.exit(1);
  }

  if (!process.env.RPC_URL) {
    console.error('RPC_URL not set');
    process.exit(1);
  }

  if (!process.env.DATABASE_URL) {
    console.error('DATABASE_URL not set');
    process.exit(1);
  }

  await initDb();
  console.log('[OK] Database connected');

  provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
  wallet = new ethers.Wallet(process.env.FAUCET_PRIVATE_KEY, provider);
  morContract = new ethers.Contract(MOR_TOKEN, ERC20_ABI, wallet);

  const balance = await provider.getBalance(wallet.address);
  const morBalance = await morContract.balanceOf(wallet.address);

  console.log(`Faucet wallet: ${wallet.address}`);
  console.log(`ETH balance: ${ethers.formatEther(balance)}`);
  console.log(`MOR balance: ${ethers.formatUnits(morBalance, 18)}`);
  console.log(`Per invite: ${MOR_AMOUNT} MOR + ${ETH_AMOUNT} ETH`);
  console.log(`Budget cap: ${MAX_TOTAL_MOR} MOR / ${MAX_TOTAL_ETH} ETH`);

  const { rows: [stats] } = await db.query(
    `SELECT COUNT(*) FILTER (WHERE NOT used) AS available, COUNT(*) AS total FROM codes`
  );
  console.log(`Invite codes: ${stats.available} available / ${stats.total} total`);

  app.listen(PORT, () => {
    console.log(`Faucet running on port ${PORT}`);
  });
}

start().catch(err => {
  console.error('Startup failed:', err.message);
  process.exit(1);
});
