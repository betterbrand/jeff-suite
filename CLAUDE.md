# Jeff Suite

Dead-simple consumer onboarding for the Morpheus Lumerin Node. One curl command installs everything, generates a wallet, starts the node, waits for funding, and opens a browser-based chat UI connected to decentralized AI models with TEE verification.

## Architecture

The install is a single curl-to-bash pipeline that:
1. Downloads the project via GitHub zip (no git required)
2. Generates an Ethereum wallet, stores the private key in macOS Keychain (`morpheus-consumer-wallet`)
3. Configures `.env` with Alchemy RPC (injected at install time, not committed)
4. Pulls and starts the proxy-router Docker container (key injected from Keychain, restored to sentinel after start)
5. Polls wallet balance every 10 seconds until MOR + ETH arrive
6. Opens `chat.html` in the browser

The chat UI (`chat.html`) is a single-file HTML/CSS/JS app that:
- Connects to the proxy-router API at `localhost:8082` with Basic Auth
- Checks for existing active sessions on load (resumes if found)
- Handles MOR approval (amount in wei: `100000000000000000000`) and session creation
- Streams responses via SSE (`/v1/chat/completions` with `stream: true`)
- Persists chat history in `localStorage` across sessions and model switches
- Sidebar shows live Morpheus network data (balances, block, supply, budget, provider info)
- Models modal fetched live from `/blockchain/models`
- Session countdown timer with close/refund button

## File Inventory

| File | Purpose |
|------|---------|
| `install.sh` | Curl one-liner entry point, downloads zip, runs setup |
| `chat.html` | Browser-based chat UI with sidebar, models modal, session management |
| `docker-compose.yml` | Proxy-router container with `.env` mounted at `/app/.env` |
| `.env.example` | Config template (public RPC default, setup.sh injects Alchemy) |
| `scripts/setup.sh` | Full install: wallet gen, keychain, config, docker pull, start, fund, launch |
| `scripts/start.sh` | Reads key from Keychain, writes to .env, starts container, restores sentinel |
| `scripts/chat-ui.sh` | Reopens chat (starts node if not running) |
| `scripts/balance.sh` | Checks MOR + ETH via JSON-RPC (pure curl, no dependencies) |
| `scripts/health.sh` | Verifies proxy-router container and API |
| `scripts/list-models.sh` | Lists marketplace models with TEE/GLM sections |
| `scripts/open-session.sh` | Auto-selects TEE/glm-5, approves MOR, opens session |
| `scripts/chat.sh` | CLI chat via curl |
| `scripts/teardown.sh` | Closes session (refunds MOR), stops container |
| `scripts/test.sh` | 51 tests: file structure, env vars, address derivation, syntax, security |
| `scripts/eth_address.py` | Pure Python secp256k1 + keccak-256 address derivation (no dependencies) |

## Key Constants

- Chain: BASE mainnet (8453)
- Diamond Contract: `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`
- MOR Token: `0x7431aDa8a591C955a994a21710752EF9b882b8e3`
- Docker Image: `ghcr.io/morpheusais/morpheus-lumerin-node:latest`
- Proxy-Router API: `http://localhost:8082`
- Auth: Basic Auth, credentials from `COOKIE_CONTENT` in `.env`

## Lessons Learned

Things that were discovered through testing and iteration:

- **Approve amount is in wei.** `amount=100` approves 100 wei (nothing). Must use `amount=100000000000000000000` for 100 MOR.
- **The models response is `{"models": [...]}`, not a bare array.** Parsing must unwrap the wrapper.
- **Model name is `glm-5`, not `glmb5`.** The marketplace model names are what they are.
- **`WALLET_PRIVATE_KEY` via `env_file` in docker-compose overrides shell env vars.** The key must be written into `.env` before `docker compose up`, not passed as a shell variable. Restored to `KEYCHAIN` sentinel immediately after.
- **The proxy-router also reads `.env` from its working directory inside the container.** Must mount `.env` at `/app/.env` in addition to using `env_file`.
- **`PROXY_STORAGE_PATH` validation requires the directory to exist.** `mkdir -p data/data` in setup.
- **`/dev/tty` is not available when piped from curl.** No interactive prompts in setup — poll automatically.
- **The public BASE RPC (`mainnet.base.org`) rate-limits aggressively.** The proxy-router makes many blockchain calls. An Alchemy free-tier key is required for reliability.
- **macOS Keychain ACL: `-T ""` blocks all access, prompting a GUI dialog.** Use `-T /usr/bin/security` to allow CLI reads without prompts.
- **Session fees are 1 wei/second on most models.** Essentially free. The real cost is gas (~0.002-0.003 ETH per session open/close).
- **`set -euo pipefail` with `((PASS++))` exits when PASS is 0** because `((0++))` returns exit code 1. Use `PASS=$((PASS + 1))` instead.
- **Python `hashlib.sha3_256` is NIST SHA-3, not keccak-256.** Ethereum uses keccak-256 which has different padding. Had to implement keccak-256 from scratch in `eth_address.py`.
- **MorpheusUI (Electron app) crashes when Docker proxy-router is already on port 8082.** They can't coexist. Use `chat.html` instead.
- **Codesigning Electron apps for notarization: every `.node`, `.dylib`, and nested binary must be individually signed** with `--options runtime --timestamp` before signing the outer `.app`. The `ShipIt` binary inside `Squirrel.framework` is easy to miss.
- **GitHub raw content CDN caches for ~5 minutes.** After pushing, the curl one-liner may serve stale content. Use commit SHA URLs to bust cache during testing.
- **Filter out `Mistral-Fake:TEE` and any model tagged `Negtest`.** These are test/invalid entries on the marketplace.
- **chat.html runs via `file://`, not a localhost HTTP server.** A Python HTTP server was considered but adds port management, PID cleanup, process lifecycle, port conflicts, and exposes `.env` and other files to local processes. `file://` works fine — `localStorage` is supported in Safari and Chrome on `file://`, and the only external call is to `localhost:8082` (proxy-router API). If a browser issue arises, revisit with a single-file-only server, not a directory serve.

## Conventions

- Never hardcode model names (marketplace is dynamic)
- Private key stored in macOS Keychain (`morpheus-consumer-wallet`), never in plaintext files
- Approve amounts always in wei
- No AI attributions in commits, PRs, or code
- Alchemy API key injected at install time by setup.sh, not committed to repo
