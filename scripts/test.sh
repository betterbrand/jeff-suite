#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0
SKIP=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; SKIP=$((SKIP + 1)); }

echo "=== Jeff Suite Tests ==="
echo ""

# -------------------------------------------------------
# 1. File structure
# -------------------------------------------------------
echo "--- File Structure ---"

for f in docker-compose.yml .env.example .gitignore CLAUDE.md README.md; do
    if [ -f "$PROJECT_DIR/$f" ]; then
        pass "$f exists"
    else
        fail "$f missing"
    fi
done

for s in setup.sh start.sh balance.sh health.sh list-models.sh open-session.sh chat.sh teardown.sh; do
    if [ -x "$PROJECT_DIR/scripts/$s" ]; then
        pass "scripts/$s exists and is executable"
    elif [ -f "$PROJECT_DIR/scripts/$s" ]; then
        fail "scripts/$s exists but is not executable"
    else
        fail "scripts/$s missing"
    fi
done

echo ""

# -------------------------------------------------------
# 2. .env.example validation
# -------------------------------------------------------
echo "--- .env.example ---"

ENV_FILE="$PROJECT_DIR/.env.example"

for var in ETH_NODE_ADDRESS WALLET_PRIVATE_KEY ETH_NODE_CHAIN_ID DIAMOND_CONTRACT_ADDRESS \
           MOR_TOKEN_ADDRESS BLOCKSCOUT_API_URL PROXY_ADDRESS WEB_ADDRESS WEB_PUBLIC_URL \
           COOKIE_CONTENT AUTH_CONFIG_FILE_PATH COOKIE_FILE_PATH PROXY_STORAGE_PATH \
           MODELS_CONFIG_PATH RATING_CONFIG_PATH; do
    if grep -q "^${var}=" "$ENV_FILE"; then
        pass "$var defined in .env.example"
    else
        fail "$var missing from .env.example"
    fi
done

# Sentinel check
if grep -q '^WALLET_PRIVATE_KEY=KEYCHAIN' "$ENV_FILE"; then
    pass "WALLET_PRIVATE_KEY uses KEYCHAIN sentinel"
else
    fail "WALLET_PRIVATE_KEY should be KEYCHAIN sentinel"
fi

# Chain ID check
if grep -q '^ETH_NODE_CHAIN_ID=8453' "$ENV_FILE"; then
    pass "Chain ID is 8453 (BASE mainnet)"
else
    fail "Chain ID should be 8453"
fi

echo ""

# -------------------------------------------------------
# 3. docker-compose.yml validation
# -------------------------------------------------------
echo "--- docker-compose.yml ---"

DC_FILE="$PROJECT_DIR/docker-compose.yml"

if grep -q 'ghcr.io/morpheusais/morpheus-lumerin-node' "$DC_FILE"; then
    pass "Correct Docker image"
else
    fail "Wrong or missing Docker image"
fi

if grep -q '8082:8082' "$DC_FILE"; then
    pass "Port 8082 mapped"
else
    fail "Port 8082 not mapped"
fi

if grep -q '3333:3333' "$DC_FILE"; then
    pass "Port 3333 mapped"
else
    fail "Port 3333 not mapped"
fi

if grep -q './data:/app/data' "$DC_FILE"; then
    pass "Data volume mounted"
else
    fail "Data volume not mounted"
fi

echo ""

# -------------------------------------------------------
# 4. Wallet generation (pure Python, no blockchain needed)
# -------------------------------------------------------
echo "--- Wallet Generation ---"

if command -v python3 &>/dev/null; then
    pass "python3 available"
else
    fail "python3 not available"
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
    exit 1
fi

# Test address derivation using shared eth_address.py module
# Private key = 1 -> well-known Ethereum address
TEST_KEY="0000000000000000000000000000000000000000000000000000000000000001"
TEST_ADDR=$(PRIVATE_KEY="$TEST_KEY" python3 "$SCRIPT_DIR/eth_address.py")

EXPECTED="0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
TEST_ADDR_LOWER=$(echo "$TEST_ADDR" | tr '[:upper:]' '[:lower:]')
EXPECTED_LOWER=$(echo "$EXPECTED" | tr '[:upper:]' '[:lower:]')
if [ "$TEST_ADDR_LOWER" = "$EXPECTED_LOWER" ]; then
    pass "Address derivation correct ($TEST_ADDR)"
else
    fail "Address derivation wrong: got $TEST_ADDR, expected $EXPECTED"
fi

# Test random key generation
RAND_KEY=$(openssl rand -hex 32)
if [ ${#RAND_KEY} -eq 64 ]; then
    pass "Random key generation (64 hex chars)"
else
    fail "Random key generation failed (got ${#RAND_KEY} chars)"
fi

echo ""

# -------------------------------------------------------
# 5. macOS Keychain (non-destructive check)
# -------------------------------------------------------
echo "--- macOS Keychain ---"

if command -v security &>/dev/null; then
    pass "security command available"
else
    fail "security command not available (not macOS?)"
fi

echo ""

# -------------------------------------------------------
# 6. Docker
# -------------------------------------------------------
echo "--- Docker ---"

if command -v docker &>/dev/null; then
    pass "Docker installed"
else
    skip "Docker not installed"
fi

if docker compose version &>/dev/null 2>&1; then
    pass "Docker Compose available"
else
    skip "Docker Compose not available"
fi

# Validate compose file syntax
cd "$PROJECT_DIR"
if docker compose config --quiet 2>/dev/null; then
    pass "docker-compose.yml is valid"
else
    skip "Could not validate docker-compose.yml (Docker may not be running)"
fi

echo ""

# -------------------------------------------------------
# 7. Script syntax check (bash -n)
# -------------------------------------------------------
echo "--- Script Syntax ---"

for s in "$PROJECT_DIR"/scripts/*.sh; do
    SNAME=$(basename "$s")
    if bash -n "$s" 2>/dev/null; then
        pass "$SNAME syntax OK"
    else
        fail "$SNAME has syntax errors"
    fi
done

echo ""

# -------------------------------------------------------
# 8. No secrets in tracked files
# -------------------------------------------------------
echo "--- Security ---"

if [ -f "$PROJECT_DIR/.env" ]; then
    if grep -q '^WALLET_PRIVATE_KEY=KEYCHAIN' "$PROJECT_DIR/.env"; then
        pass ".env uses KEYCHAIN sentinel (no plaintext key)"
    elif grep -q '^WALLET_PRIVATE_KEY=$' "$PROJECT_DIR/.env"; then
        pass ".env has empty WALLET_PRIVATE_KEY"
    else
        fail ".env may contain a plaintext private key"
    fi
else
    pass "No .env file (will be created by setup.sh)"
fi

if git -C "$PROJECT_DIR" ls-files --cached 2>/dev/null | grep -q '\.env$'; then
    fail ".env is tracked by git"
else
    pass ".env is not tracked by git"
fi

echo ""

# -------------------------------------------------------
# Results
# -------------------------------------------------------
echo "==========================================="
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
