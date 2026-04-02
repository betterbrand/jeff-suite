require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { ethers } = require('ethers');
const { Pool } = require('pg');

const app = express();
app.set('trust proxy', 1);
app.use(cors({ origin: 'null' }));  // Allow file:// origin (browsers send Origin: null for file://)
app.use(express.json({ limit: '10kb' }));

const PORT = process.env.PORT || 3456;
const MOR_TOKEN = process.env.MOR_TOKEN || '0x7431aDa8a591C955a994a21710752EF9b882b8e3';
const MOR_AMOUNT = process.env.MOR_AMOUNT || '3';
const ETH_AMOUNT = process.env.ETH_AMOUNT || '0.005';
const MAX_TOTAL_MOR = parseFloat(process.env.MAX_TOTAL_MOR || '300');
const MAX_TOTAL_ETH = parseFloat(process.env.MAX_TOTAL_ETH || '0.5');

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
      assigned_to TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);

  // Migrations for existing tables
  await db.query(`ALTER TABLE codes ADD COLUMN IF NOT EXISTS assigned_to TEXT`);
  await db.query(`ALTER TABLE codes ADD COLUMN IF NOT EXISTS redeemed_ip_hash TEXT`);

  await db.query(`
    CREATE TABLE IF NOT EXISTS analytics_snapshots (
      id SERIAL PRIMARY KEY,
      wallet TEXT NOT NULL,
      code TEXT,
      mor_balance TEXT NOT NULL,
      eth_balance TEXT NOT NULL,
      mor_purchased TEXT NOT NULL DEFAULT '0',
      sessions_opened INTEGER NOT NULL DEFAULT 0,
      last_active TIMESTAMPTZ,
      snapshot_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);
  await db.query(`CREATE INDEX IF NOT EXISTS idx_snapshots_wallet ON analytics_snapshots(wallet, snapshot_at)`);
}

// --- Blockscout + RPC helpers ---

const BLOCKSCOUT_BASE = 'https://base.blockscout.com/api/v2';
const DIAMOND_CONTRACT = '0x6aBE1d282f72B474E54527D93b979A4f64d3030a'.toLowerCase();
const FAUCET_MOR = parseFloat(MOR_AMOUNT);

async function fetchJSON(url) {
  const resp = await fetch(url);
  if (!resp.ok) return null;
  return resp.json();
}

async function getWalletAnalytics(walletAddr) {
  // Validate address
  const wallet = ethers.getAddress(walletAddr);
  const walletLower = wallet.toLowerCase();

  // Current balances via RPC
  const [ethBal, morBal] = await Promise.all([
    provider.getBalance(wallet),
    morContract.balanceOf(wallet)
  ]);

  // MOR transfers from Blockscout
  const transfers = await fetchJSON(
    `${BLOCKSCOUT_BASE}/addresses/${wallet}/token-transfers?type=ERC-20&token=${MOR_TOKEN}&limit=100`
  );

  let morIn = 0;
  let morOut = 0;
  if (transfers && transfers.items) {
    for (const t of transfers.items) {
      const value = parseFloat(t.total?.value || '0') / 1e18;
      const to = (t.to?.hash || '').toLowerCase();
      const from = (t.from?.hash || '').toLowerCase();
      if (to === walletLower) morIn += value;
      if (from === walletLower) morOut += value;
    }
  }

  // Transactions to Diamond contract (sessions)
  const txs = await fetchJSON(
    `${BLOCKSCOUT_BASE}/addresses/${wallet}/transactions?limit=100`
  );

  let sessionsOpened = 0;
  let lastActive = null;
  if (txs && txs.items) {
    for (const tx of txs.items) {
      const to = (tx.to?.hash || '').toLowerCase();
      if (to === DIAMOND_CONTRACT) {
        sessionsOpened++;
      }
      if (!lastActive && tx.timestamp) {
        lastActive = tx.timestamp;
      }
    }
  }

  const morPurchased = Math.max(0, morIn - FAUCET_MOR);
  const currentMor = parseFloat(ethers.formatUnits(morBal, 18));
  const currentEth = parseFloat(ethers.formatEther(ethBal));

  // Determine status
  const now = Date.now();
  const lastActiveMs = lastActive ? new Date(lastActive).getTime() : 0;
  const daysSinceActive = lastActiveMs ? (now - lastActiveMs) / (1000 * 60 * 60 * 24) : Infinity;

  let status;
  if (daysSinceActive <= 7) status = 'active';
  else if (morPurchased > 0) status = 'purchased';
  else if (daysSinceActive > 14) status = 'inactive';
  else status = 'faucet only';

  return {
    currentMor: currentMor.toFixed(4),
    currentEth: currentEth.toFixed(6),
    morPurchased: morPurchased.toFixed(4),
    morSpent: morOut.toFixed(4),
    sessionsOpened,
    lastActive,
    status
  };
}

// --- Routes ---

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.get('/admin/stats', requireAdmin, async (req, res) => {
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
      codes: { total: parseInt(stats.total), used: parseInt(stats.used), available: parseInt(stats.available) },
      disbursed,
      budget: { maxMor: MAX_TOTAL_MOR, maxEth: MAX_TOTAL_ETH }
    });
  } catch (err) {
    res.status(500).json({ error: 'Database unavailable' });
  }
});

// --- Admin routes ---

app.get('/admin/codes', requireAdmin, async (req, res) => {
  try {
    const { rows } = await db.query(
      'SELECT code, used, status, used_by, used_at, eth_tx, mor_tx, error, assigned_to, created_at FROM codes ORDER BY created_at DESC'
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

app.get('/admin/wallet', requireAdmin, async (req, res) => {
  try {
    const balance = await provider.getBalance(wallet.address);
    const morBalance = await morContract.balanceOf(wallet.address);
    const nonce = await provider.getTransactionCount(wallet.address);
    res.json({
      address: wallet.address,
      eth: ethers.formatEther(balance),
      mor: ethers.formatUnits(morBalance, 18),
      nonce,
      perInvite: { mor: MOR_AMOUNT, eth: ETH_AMOUNT },
      invitesRemaining: Math.floor(parseFloat(ethers.formatUnits(morBalance, 18)) / parseFloat(MOR_AMOUNT))
    });
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch wallet info' });
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

app.post('/admin/assign', requireAdmin, async (req, res) => {
  const { code, name } = req.body;
  if (!code) return res.status(400).json({ error: 'Missing code' });
  if (name && name.length > 100) return res.status(400).json({ error: 'Name too long' });
  try {
    const { rowCount } = await db.query(
      'UPDATE codes SET assigned_to = $1 WHERE code = $2',
      [name || null, code]
    );
    if (rowCount === 0) return res.status(404).json({ error: 'Code not found' });
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: 'Database error' });
  }
});

app.get('/admin/analytics', requireAdmin, async (req, res) => {
  try {
    const { rows: codes } = await db.query(
      `SELECT code, assigned_to, used_by, used_at, redeemed_ip_hash
       FROM codes WHERE used = true AND status = 'completed' ORDER BY used_at DESC`
    );

    if (codes.length === 0) {
      return res.json({ users: [], summary: { totalInvited: 0, totalConverted: 0, conversionRate: '0%', totalMorPurchased: '0', totalMorSpent: '0' } });
    }

    // Process wallets in batches of 5
    const users = [];
    for (let i = 0; i < codes.length; i += 5) {
      const batch = codes.slice(i, i + 5);
      const results = await Promise.all(batch.map(async c => {
        try {
          const analytics = await getWalletAnalytics(c.used_by);
          const daysSinceInvite = c.used_at ? Math.floor((Date.now() - new Date(c.used_at).getTime()) / (1000 * 60 * 60 * 24)) : 0;

          // Store snapshot if last one is >1 hour old
          const { rows: lastSnap } = await db.query(
            `SELECT snapshot_at FROM analytics_snapshots WHERE wallet = $1 ORDER BY snapshot_at DESC LIMIT 1`,
            [c.used_by]
          );
          const needsSnapshot = !lastSnap.length || (Date.now() - new Date(lastSnap[0].snapshot_at).getTime() > 3600000);
          if (needsSnapshot) {
            await db.query(
              `INSERT INTO analytics_snapshots (wallet, code, mor_balance, eth_balance, mor_purchased, sessions_opened, last_active)
               VALUES ($1, $2, $3, $4, $5, $6, $7)`,
              [c.used_by, c.code, analytics.currentMor, analytics.currentEth, analytics.morPurchased, analytics.sessionsOpened, analytics.lastActive]
            );
          }

          return {
            code: c.code,
            name: c.assigned_to,
            wallet: c.used_by,
            invitedAt: c.used_at,
            daysSinceInvite,
            ipHash: c.redeemed_ip_hash,
            ...analytics
          };
        } catch (err) {
          return {
            code: c.code,
            name: c.assigned_to,
            wallet: c.used_by,
            invitedAt: c.used_at,
            daysSinceInvite: 0,
            currentMor: '0', currentEth: '0', morPurchased: '0', morSpent: '0',
            sessionsOpened: 0, lastActive: null, status: 'error'
          };
        }
      }));
      users.push(...results);
    }

    // Summary
    const totalInvited = users.length;
    const totalConverted = users.filter(u => parseFloat(u.morPurchased) > 0).length;
    const totalMorPurchased = users.reduce((sum, u) => sum + parseFloat(u.morPurchased), 0).toFixed(4);
    const totalMorSpent = users.reduce((sum, u) => sum + parseFloat(u.morSpent), 0).toFixed(4);

    res.json({
      users,
      summary: {
        totalInvited,
        totalConverted,
        conversionRate: totalInvited > 0 ? Math.round(totalConverted / totalInvited * 100) + '%' : '0%',
        totalMorPurchased,
        totalMorSpent
      }
    });
  } catch (err) {
    console.error('Analytics error:', err.message);
    res.status(500).json({ error: 'Analytics query failed' });
  }
});

app.get('/admin/analytics/:wallet/history', requireAdmin, async (req, res) => {
  try {
    const wallet = ethers.getAddress(req.params.wallet);
    const { rows } = await db.query(
      `SELECT mor_balance, eth_balance, mor_purchased, sessions_opened, last_active, snapshot_at
       FROM analytics_snapshots WHERE wallet = $1 ORDER BY snapshot_at ASC`,
      [wallet]
    );
    res.json({ wallet, history: rows });
  } catch (err) {
    res.status(500).json({ error: 'History query failed' });
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
  const ip = req.ip;
  const lastRequest = ipTimestamps.get(ip);
  if (lastRequest && Date.now() - lastRequest < RATE_LIMIT_MS) {
    return res.status(429).json({ error: 'Rate limited. Try again in a minute.' });
  }
  ipTimestamps.set(ip, Date.now());

  try {
    // Hash the IP for privacy (store hash, not raw IP)
    const ipHash = crypto.createHash('sha256').update(ip || 'unknown').digest('hex').slice(0, 16);

    // Atomic claim: mark code as used only if it exists and is unused
    const { rows } = await db.query(
      `UPDATE codes SET used = true, used_by = $1, used_at = NOW(), status = 'in-flight', redeemed_ip_hash = $3
       WHERE code = $2 AND used = false
       RETURNING *`,
      [address, code, ipHash]
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

    // Send ETH, wait for confirmation before MOR to avoid nonce collision
    const ethTx = await wallet.sendTransaction({
      to: address,
      value: ethers.parseEther(ETH_AMOUNT)
    });
    await ethTx.wait();

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
