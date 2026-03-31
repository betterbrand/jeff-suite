#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KEYCHAIN_PATH="$HOME/.morpheus-wallet.keychain-db"
KEYCHAIN_PASS_FILE="$HOME/.morpheus-keychain-pass"
KEYCHAIN_SERVICE="morpheus-consumer-wallet"
KEYCHAIN_ACCOUNT="j-suite"

echo "=== Starting Morpheus Proxy-Router ==="
echo ""

# --- Validate setup ---
if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo "[FAIL] No .env file found. Run ./scripts/setup.sh first."
    exit 1
fi

if [ ! -f "$KEYCHAIN_PATH" ]; then
    echo "[FAIL] Keychain not found at $KEYCHAIN_PATH. Run ./scripts/setup.sh first."
    exit 1
fi

if [ ! -f "$KEYCHAIN_PASS_FILE" ]; then
    echo "[FAIL] Keychain password file not found. Run ./scripts/setup.sh first."
    exit 1
fi

# --- Read key from Keychain ---
echo "Reading wallet key from Keychain..."
KEYCHAIN_PASS=$(cat "$KEYCHAIN_PASS_FILE")
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"

WALLET_KEY=$(security find-generic-password \
    -s "$KEYCHAIN_SERVICE" \
    -a "$KEYCHAIN_ACCOUNT" \
    -w "$KEYCHAIN_PATH")

if [ -z "$WALLET_KEY" ]; then
    echo "[FAIL] Could not read wallet key from Keychain."
    exit 1
fi
echo "[OK] Wallet key loaded from Keychain"

# --- Inject key into .env, start, restore sentinel ---
echo "Starting proxy-router..."
cd "$PROJECT_DIR"

# Temporarily write key into .env for Docker
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|^WALLET_PRIVATE_KEY=.*|WALLET_PRIVATE_KEY=$WALLET_KEY|" "$PROJECT_DIR/.env"
else
    sed -i "s|^WALLET_PRIVATE_KEY=.*|WALLET_PRIVATE_KEY=$WALLET_KEY|" "$PROJECT_DIR/.env"
fi

# Guarantee sentinel is restored even if the script exits unexpectedly
trap 'if [[ "$OSTYPE" == "darwin"* ]]; then sed -i "" "s|^WALLET_PRIVATE_KEY=.*|WALLET_PRIVATE_KEY=KEYCHAIN|" "$PROJECT_DIR/.env"; else sed -i "s|^WALLET_PRIVATE_KEY=.*|WALLET_PRIVATE_KEY=KEYCHAIN|" "$PROJECT_DIR/.env"; fi' EXIT

docker compose up -d

# Clear key from shell
unset WALLET_KEY
unset KEYCHAIN_PASS

echo ""
echo "[OK] Proxy-router started"
echo ""
echo "  API:     http://localhost:8082"
echo "  Swagger: http://localhost:8082/swagger/index.html"
echo ""
echo "  Next: ./scripts/health.sh"
echo ""
