# Deployment environment variables

What to put in Dokploy's environment list for `ErgoServer`. `compose.yaml` passes everything in that list to the server, so a new variable needs no change there. Nothing here is strictly required, because the vault key is created automatically in the data volume.

The full reference is the Configuration section of `README.md`.

## How it reaches the server

- Dokploy writes the list to a `.env` beside `compose.yaml`, and `env_file` hands all of it to the container. This needs Docker Compose 2.24 or newer.
- Each launch logs what isn't set, by name and never by value: a line for each variable that leaves something off, and one line for those on their default.
- A key must be on one line, with literal `\n` in place of its newlines.
- A key that doesn't read stops the server from starting, and the log says why. So does a key without its id.
- An empty `ERGO_APPLE_APP_ID=`, `ERGO_MAX_PROCESSES=` or `ERGO_STAGE_TIMEOUT=` also stops it. Leave those out unless they have a value.

## Already in the list

| Variable | Notes |
|---|---|
| `ERGO_DATABASE_URL` | `postgres://user:password@host:5432/database`, with the password percent-encoded. Unset uses SQLite. |
| `ERGO_CLAUDE_MODEL` | Applies to every stage |
| `ERGO_CODEX_MODEL` | Applies to every stage |
| `ERGO_MODEL_EFFORT` | Applies to every stage |
| `ERGO_OPENROUTER_API_KEY` | Unset, the server's own model isn't offered |
| `ERGO_OPENROUTER_MODEL` | Required with the API key |
| `ERGO_APNS_KEY` | The `.p8`. Unset, no pushes are sent. `ERGO_APNS_KEY_FILE` is the alternative. |
| `ERGO_APNS_KEY_ID` | Required with the key |
| `ERGO_APNS_TEAM_ID` | Default `P6PV2R9443` |

## Add before launch

| Variable | Notes |
|---|---|
| `ERGO_DEVICECHECK_KEY` | A `.p8` with DeviceCheck enabled, formatted like the APNs key. Without it, one person gets a new free allowance with each new account. `ERGO_DEVICECHECK_KEY_FILE` is the alternative. |
| `ERGO_DEVICECHECK_KEY_ID` | Required with the key |

## Add once you have it

| Variable | Notes |
|---|---|
| `ERGO_APP_STORE_ID` | Adds an App Store link and banner to the join page |

## Optional

| Variable | Default | Notes |
|---|---|---|
| `ERGO_OPENROUTER_PLUS_MODEL` | `ERGO_OPENROUTER_MODEL` | The model paying accounts get |
| `ERGO_WEB_SEARCH` | off | Deep research on the server's model sees a few web results. Costs extra for each run. |
| `ERGO_FREE_DAILY_USD` | 0.03 | The day's allowance, in dollars at the reference price |
| `ERGO_PLUS_DAILY_USD` | 1 | The day's allowance, in dollars at the reference price |
| `ERGO_FREE_DEEP_PER_WEEK` | 1 | Deep research runs a week |
| `ERGO_PLUS_DEEP_PER_WEEK` | 30 | Deep research runs a week |
| `ERGO_USAGE_PRICE_INPUT` | 0.2 | The reference price, dollars per million tokens |
| `ERGO_USAGE_PRICE_OUTPUT` | 1.2 | The reference price, dollars per million tokens |
| `ERGO_PUBLIC_URL` | `https://ergo-15.235.184.129.sslip.io` | What invite links are built on |
| `ERGO_APPLE_APP_ID` | `com.adonis.Ergo` | The app's bundle id |
| `ERGO_APPLE_TEAM_IDS` | `P6PV2R9443` | Comma separated |
| `ERGO_APNS_TOPIC` | `ERGO_APPLE_APP_ID` | The `apns-topic` |
| `ERGO_DEVICECHECK_TEAM_ID` | `P6PV2R9443` | |
| `ERGO_MAX_PROCESSES` | 8 | CLI processes at once, across all users |
| `ERGO_STAGE_TIMEOUT` | 120 | Seconds per CLI call |
| `ERGO_MODELS_FILE` | none | A path inside the container, to JSON overriding the models per stage |
| `ERGO_TRUST_PROXY` | `1` in `compose.yaml`, off in the server | Keep it on behind Dokploy's Traefik. Never use it on a server that's reachable without the proxy. |

## Don't add yet

| Variable | Notes |
|---|---|
| `ERGO_ENFORCE_PLANS` | Turning it on without `ERGO_APPLE_ROOT_CERT_FILE` stops the server from starting. Turn it on once the App Store products exist. |
| `ERGO_APPLE_ROOT_CERT_FILE` | A path to Apple Root CA G3 in PEM, inside the container. Nothing puts the certificate there yet, so it needs a mount or a Dockerfile change. Without it, purchases are refused. |

## Don't set

The Dockerfile sets these, and a value in the list would override it.

- `ERGO_DATABASE_PATH`
- `ERGO_VAULT_KEY_FILE`
- `ERGO_RUNS_DIRECTORY`
- `ERGO_CLAUDE_PATH`
- `ERGO_CODEX_PATH`
- `ERGO_CLI_DIRECTORY`
- `ERGO_CLAUDE_CODE_VERSION`
- `ERGO_CODEX_VERSION`
- `ERGO_RUNNER_USER`
- `ERGO_RUNNER_PREFIX`
