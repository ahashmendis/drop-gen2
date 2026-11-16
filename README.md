# drop-code

Drop: a small floating popup that sends exam papers / starter projects to an AI model.

Two providers, switchable from the popup — both share the same file-extraction,
prompt, Java compile-check (macOS), repair-loop and clipboard pipeline:

| | Ollama | OpenCode Go |
|---|---|---|
| Where | Local `http://127.0.0.1:11434` | Cloud `https://opencode.ai/zen/go/v1` |
| Auth | None | `Bearer` API key (`oc_…`) |
| Model | Installed **Qwen** models (auto-discovered) | `mimo-v2.6-flash` (configurable) |
| Needs internet | No | Yes |
| Discovery | `GET /api/tags`, Qwen family only | `GET /models` (falls back to configured model) |

## Mac

1. Put `install-drop.sh` and `Drop.icns` in `~/Downloads`
2. Run `bash ~/Downloads/install-drop.sh`
3. For **Ollama**: install Ollama and pull any Qwen model
   (e.g. `ollama pull qwen3-coder`) — Drop discovers every installed Qwen
   model and offers it in the popup's model dropdown
4. For **OpenCode Go**: menu-bar tray icon → **Settings…** → paste your API key
   (`oc_…` from https://opencode.ai/auth) → **Test Connection** → **Save**
5. Switch providers with the **🦙 Ollama / ☁️ OpenCode** button in the popup

## Windows

1. Open the `windows` folder and double-click `Install Drop.cmd`
2. For **Ollama**: install Ollama for Windows and pull any Qwen model
   (e.g. `ollama pull qwen3-coder`) — the popup's dropdown lists every
   installed Qwen model
3. For **OpenCode Go**: tray icon → **Settings…** → paste API key →
   **Test Connection** → **Save**
4. Switch providers with the **Ollama / OpenCode** button in the popup

## Configuration

Stored locally, never in Keychain/Credential Manager, user-only permissions (0600):

- macOS: `~/Library/Application Support/Drop/config.json`
- Windows: `%APPDATA%\Drop\config.json`

```json
{
  "provider": "ollama",
  "ollama":      { "base_url": "http://127.0.0.1:11434", "default_model": "", "context": 0 },
  "opencode_go": { "base_url": "https://opencode.ai/zen/go/v1", "api_key": "", "model": "mimo-v2.6-flash" },
  "network":     { "connect_timeout": 20, "stream_idle_timeout": 120, "retry_attempts": 3, "retry_backoff": true },
  "preferences": { "remember_provider": true, "allow_fallback": false }
}
```

### Ollama Qwen models & context

- Discovery uses `GET /api/tags` and keeps only the **Qwen family**
  (`details.family`/`details.families` metadata first, name as fallback) —
  no model is hardcoded, so the same build works on any machine with any
  installed Qwen variants. The selected model is remembered locally; if it is
  uninstalled, Drop says so and falls back to an installed one — it never
  selects a model that does not exist. With no Qwen models installed the
  dropdown says `ollama pull a Qwen model first`.
- `ollama.context` = manual `num_ctx` override, `0` (default) = hardware
  preset: **8 GB → 8192 · 16 GB → 16384 · 32 GB → 16384 · 64 GB+ → 32768**
  (conservative low end of each recommended range). Prompt-size growth still
  raises the context for large papers, capped at 65536. Adjust it in
  Settings → **Qwen ctx**.
- The API key is only ever sent to `base_url` — never logged, never shown in errors.
- OpenCode requests match the verified baseline exactly: `User-Agent: Drop/1.0`,
  a stable `x-opencode-session` id (one per conversation; retries reuse it),
  body = `model` / `messages` / `stream` only. If the server rejects the
  streaming shape (400), Drop retries once non-streaming automatically.
- Re-running the installer does **not** overwrite an existing config or key.
- Alternative official endpoint (Console docs): `https://opencode.ai/inference/go/openai/v1`
  — change `base_url` if the `zen/go` path ever changes.

## Network diagnostics

Failures are classified distinctly (never one generic "internet error"):
no internet · DNS failure · TCP/connection refused · TLS certificate ·
endpoint unreachable (possible network restriction) · invalid key (401/403) ·
model/endpoint not found (404) · rate limited (429, `Retry-After` honoured) ·
server error (5xx) · timeout · stream interrupted (partial answer kept).

- Transient errors retry with exponential backoff + jitter (max `retry_attempts`).
- Auth/400/404 never retry.
- TLS is always validated; no insecure fallback, no relays or proxies.
- If OpenCode Go is blocked by the network, Drop says so and keeps your provider
  choice. **Ollama fallback only ever prompts for explicit approval**
  (off by default, enable in Settings) — files are never sent elsewhere silently.
