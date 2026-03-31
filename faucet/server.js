require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

const app = express();
app.use(cors());
app.use(express.json());

const PORT = process.env.PORT || 3456;
const MOR_TOKEN = process.env.MOR_TOKEN || '0x7431aDa8a591C955a994a21710752EF9b882b8e3';
const MOR_AMOUNT = process.env.MOR_AMOUNT || '3';
const ETH_AMOUNT = process.env.ETH_AMOUNT || '0.003';
const MAX_TOTAL_MOR = parseFloat(process.env.MAX_TOTAL_MOR || '300');
const MAX_TOTAL_ETH = parseFloat(process.env.MAX_TOTAL_ETH || '0.3');
const CODES_FILE = path.join(__dirname, 'codes.json');

// ERC-20 transfer ABI
const ERC20_ABI = ['function transfer(address to, uint256 amount) returns (bool)'];

// Rate limiting
const ipTimestamps = new Map();
const RATE_LIMIT_MS = 60000;

// In-memory lock for concurrent code redemption
const pendingCodes = new Set();

let provider, wallet, morContract;

function loadCodes() {
  if (!fs.existsSync(CODES_FILE)) {
    console.error('codes.json not found. Run: node generate-codes.js');
    process.exit(1);
  }
  return JSON.parse(fs.readFileSync(CODES_FILE, 'utf8'));
}

function saveCodes(codes) {
  fs.writeFileSync(CODES_FILE, JSON.stringify(codes, null, 2) + '\n');
}

function getTotalDisbursed(codes) {
  const used = Object.values(codes).filter(c => c.used);
  return {
    mor: used.length * parseFloat(MOR_AMOUNT),
    eth: used.length * parseFloat(ETH_AMOUNT)
  };
}

app.get('/health', (req, res) => {
  const codes = loadCodes();
  const total = getTotalDisbursed(codes);
  const totalCodes = Object.keys(codes).length;
  const usedCodes = Object.values(codes).filter(c => c.used).length;
  res.json({
    status: 'ok',
    codes: { total: totalCodes, used: usedCodes, available: totalCodes - usedCodes },
    disbursed: { mor: total.mor, eth: total.eth },
    budget: { maxMor: MAX_TOTAL_MOR, maxEth: MAX_TOTAL_ETH }
  });
});

app.post('/fund', async (req, res) => {
  const { code, address } = req.body;

  // Validate inputs
  if (!code || !address) {
    return res.status(400).json({ error: 'Missing code or address' });
  }

  if (!ethers.isAddress(address)) {
    return res.status(400).json({ error: 'Invalid Ethereum address' });
  }

  // Rate limit by IP
  const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
  const lastRequest = ipTimestamps.get(ip);
  if (lastRequest && Date.now() - lastRequest < RATE_LIMIT_MS) {
    return res.status(429).json({ error: 'Rate limited. Try again in a minute.' });
  }

  // Check code
  const codes = loadCodes();
  const entry = codes[code];

  if (!entry) {
    return res.status(403).json({ error: 'Invalid invite code' });
  }

  if (entry.used) {
    return res.status(403).json({ error: 'Invite code already used' });
  }

  // Concurrency lock
  if (pendingCodes.has(code)) {
    return res.status(409).json({ error: 'Code redemption in progress' });
  }
  pendingCodes.add(code);

  try {
    // Check budget cap
    const total = getTotalDisbursed(codes);
    if (total.mor + parseFloat(MOR_AMOUNT) > MAX_TOTAL_MOR) {
      return res.status(503).json({ error: 'Faucet MOR budget depleted' });
    }
    if (total.eth + parseFloat(ETH_AMOUNT) > MAX_TOTAL_ETH) {
      return res.status(503).json({ error: 'Faucet ETH budget depleted' });
    }

    // Record rate limit
    ipTimestamps.set(ip, Date.now());

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

    // Mark code as used
    codes[code] = {
      used: true,
      usedBy: address,
      usedAt: new Date().toISOString(),
      ethTx: ethTx.hash,
      morTx: morTx.hash
    };
    saveCodes(codes);

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
    res.status(500).json({ error: 'Transaction failed: ' + err.message });
  } finally {
    pendingCodes.delete(code);
  }
});

async function start() {
  if (!process.env.FAUCET_PRIVATE_KEY) {
    console.error('FAUCET_PRIVATE_KEY not set');
    process.exit(1);
  }

  if (!process.env.RPC_URL) {
    console.error('RPC_URL not set');
    process.exit(1);
  }

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

  const codes = loadCodes();
  const available = Object.values(codes).filter(c => !c.used).length;
  console.log(`Invite codes: ${available} available`);

  app.listen(PORT, () => {
    console.log(`Faucet running on port ${PORT}`);
  });
}

start().catch(err => {
  console.error('Startup failed:', err.message);
  process.exit(1);
});
