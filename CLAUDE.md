# Jeff Suite

Dead-simple consumer onboarding for the Morpheus Lumerin Node. Run the proxy-router in Docker, chat with decentralized AI models (TEE providers, glmb5 preferred) via MorpheusUI or CLI scripts.

## File Inventory

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Single proxy-router service |
| `.env.example` | Config template (1 value to fill in: RPC URL) |
| `scripts/setup.sh` | Generates wallet, stores in macOS Keychain, creates .env |
| `scripts/start.sh` | Reads key from Keychain, starts Docker container |
| `scripts/balance.sh` | Checks MOR + ETH balances |
| `scripts/health.sh` | Checks proxy-router health |
| `scripts/list-models.sh` | Lists marketplace models, flags TEE providers |
| `scripts/open-session.sh` | Approves MOR + opens session (prefers TEE/glmb5) |
| `scripts/chat.sh` | Sends a prompt to an active session |
| `scripts/teardown.sh` | Closes session, stops containers |

## Key Constants

- Chain: BASE mainnet (8453)
- Diamond Contract: `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`
- MOR Token: `0x7431aDa8a591C955a994a21710752EF9b882b8e3`
- Docker Image: `ghcr.io/morpheusais/morpheus-lumerin-node:latest`
- Proxy-Router API: `http://localhost:8082`

## Conventions

- Never hardcode model names (marketplace is dynamic)
- Private key stored in macOS Keychain, never in plaintext files
- No AI attributions in commits, PRs, or code
