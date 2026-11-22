# Lorvex Remote MCP Bridge

Dependency-free Node 24+ server providing Streamable HTTP MCP for ChatGPT and an outbound-only HTTPS command channel to Lorvex on iPad.

The server NEVER mirrors the Lorvex SQLite task database. Only the user's own running iPad app can execute actions, through the original LorvexCoreServicing and HanlinAgentSDK catalog.

## Security model

- ChatGPT authorizes via OAuth 2.1 authorization code with PKCE.
- Pairing requires a one-time 8-character code displayed on the iPad.
- Tokens are random; only SHA256 hashes are persisted on the server.
- The iPad uses a separate bearer credential generated and saved locally in the Keychain.
- All write tools require a second interactive user approval ON THE IPAD. Default is deny.
- Commands and tool results are transient memory only. No task data is persisted.
- Calls fail if the iPad is offline or backgrounded, without claiming success.
- The server binds to localhost HTTP, and must be accessed via an HTTPS tunnel.
- Only the 22 declared Hanlin tool aliases are allowed.

## Start on Oracle Linux

Environment:
LORVEX_BRIDGE_PORT=8767
LORVEX_BRIDGE_HOST=127.0.0.1
LORVEX_BRIDGE_ORIGIN=https://your-stable-mcp-relay-hostname

Start with: node bridge/server.mjs
Test with: node --test bridge/server.test.mjs

No npm packages, Docker or other app database is needed. Keep bridge-state.json mode 0600 and out of Git.

## Cloudflare

For a trial tunnel, run cloudflared tunnel --url http://localhost:8767
The random hostname is assigned by Cloudflare. Set LORVEX_BRIDGE_ORIGIN to the HTTPS URL and restart only the Node relay. Quick Tunnels are temporary and do not support SSE, so this MCP server uses Streamable HTTP JSON responses.

For persistent use, configure a named Cloudflare Tunnel with a domain in the Cloudflare account, or a stable Tailscale Funnel HTTPS hostname.

## Pair with ChatGPT

1. Install the new Lorvex IPA with the Remote MCP Bridge feature.
2. On iPad open AI > MCP, enter the bridge HTTPS origin, tap Pair.
3. Keep Lorvex in the foreground and copy the new 8-character code.
4. On ChatGPT web: Plugins > Add custom MCP server, enter the URL ending in /mcp and select OAuth.
5. The Lorvex authorization page asks for the 8-character code. Enter it there.
6. Once linked, keep Lorvex open while making tool calls; approve each requested change on the iPad.

Important limitations:
- iPadOS does not allow indefinitely running foreground polling in the background. Remote tools fail closed while Lorvex is suspended.
- This bridge does not sign in to a ChatGPT account within Lorvex. It links ChatGPT to the iPad's local data through a separate OAuth session.
- ChatGPT custom MCP write-tool access depends on the user's plan and workspace permissions.
- Installation and execution on the user's actual iPad need a new signed/sideloaded IPA and must be validated.
