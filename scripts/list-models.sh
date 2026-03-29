#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
API_URL="http://localhost:8082"

# --- Load auth ---
if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo "[FAIL] No .env found. Run ./scripts/setup.sh first."
    exit 1
fi

COOKIE_CONTENT=$(grep '^COOKIE_CONTENT=' "$PROJECT_DIR/.env" | cut -d= -f2)
AUTH_USER="${COOKIE_CONTENT%%:*}"
AUTH_PASS="${COOKIE_CONTENT#*:}"

echo "=== Available Models on Morpheus Marketplace ==="
echo ""

RESPONSE=$(curl -sf -u "$AUTH_USER:$AUTH_PASS" "$API_URL/blockchain/models" 2>/dev/null)

if [ -z "$RESPONSE" ]; then
    echo "[FAIL] Could not fetch models. Is the proxy-router running?"
    echo "       Run: ./scripts/health.sh"
    exit 1
fi

echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = data.get('models', data) if isinstance(data, dict) else data
if not isinstance(models, list):
    print('Unexpected response format'); sys.exit(1)

llms = [m for m in models if (m.get('ModelType') or '') == 'LLM']
others = [m for m in models if (m.get('ModelType') or '') != 'LLM']

print(f'Found {len(llms)} LLM model(s):')
print()
for m in llms:
    tags = ', '.join(m.get('Tags') or [])
    tee = ' [TEE]' if 'TEE' in (m.get('Tags') or []) else ''
    print(f'  {m[\"Name\"]}{tee}')
    print(f'    ID:   {m[\"Id\"]}')
    print(f'    Tags: {tags}')
    print()

tee_models = [m for m in llms if 'TEE' in (m.get('Tags') or [])]
if tee_models:
    print('--- TEE Providers ---')
    for m in tee_models:
        print(f'  [TEE] {m[\"Name\"]} -> {m[\"Id\"]}')
    print()

glm = [m for m in llms if 'glm' in (m.get('Name') or '').lower()]
if glm:
    print('--- GLM Models ---')
    for m in glm:
        print(f'  {m[\"Name\"]} -> {m[\"Id\"]}')
    print()

if others:
    print(f'Also found {len(others)} non-LLM model(s) (embedding, STT, TTS)')
    print()
"

echo "To open a session: ./scripts/open-session.sh <MODEL_ID>"
echo ""
