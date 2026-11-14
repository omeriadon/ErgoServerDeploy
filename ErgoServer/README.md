# ErgoServer

Ergo's server. It runs Ask, Break Down and English → logic translation through the official `claude` and `codex` CLIs, each user with their own Claude or ChatGPT credential, and streams to the app over WebSockets. Ergo provides no model access of its own. The app no longer translates, so only `Evals/` uses the translate route.

It also syncs boards, bookmarks and a few settings between a user's devices, once they sign in, with Apple or with an email and password, and shares boards between people.

The wire protocol is `ErgoProtocol` in ErgoKit. The design is in `Plans/02-Server.md` and `Plans/05-Sync.md`.

## Routes

Every request from the app sends `Ergo-Protocol-Version: 1`, and all but `POST v1/accounts` send `Authorization: Bearer <token>`. Errors are a `ServiceError` body. The one route the app doesn't call, `POST v1/apple/notifications`, needs neither, see [Sign in with Apple notifications](#sign-in-with-apple-notifications).

| Route | Needs | |
|---|---|---|
| `POST v1/accounts` | nothing | A new anonymous account and this device's token. 5 an hour per address. |
| `DELETE v1/account` | token | Deletes the account, its connections, its synced records and every device's token. Revokes its Sign in with Apple first, see [Revoking Sign in with Apple](#revoking-sign-in-with-apple). |
| `POST v1/account/apple` | token | `SignInWithAppleRequest` → `SignedIn`. Attaches the Apple ID, or merges this device's account into the one that has it. The optional `authorizationCode` is traded for a refresh token, see [Revoking Sign in with Apple](#revoking-sign-in-with-apple). |
| `POST v1/account/register` | token | `EmailCredentials` → `204`. Attaches an email and password to this device's account. `409` `emailInUse` if the email is taken, `400` if the account already has one. 10 an hour per address. |
| `POST v1/account/login` | token | `EmailCredentials` → `SignedIn`. Merges this device's anonymous account into the one that owns the email, like Sign in with Apple. `401` `invalidCredentials` for a wrong password or an unknown email, `429` `rateLimited` after too many failures. |
| `POST v1/account/password` | token | `ChangePasswordRequest` → `204`. Signs out every other device of the account and closes their sockets; this device's token stays. |
| `DELETE v1/account/token` | token | Signs out this device only. An anonymous account with no device left is deleted. |
| `GET v1/connections` | token | `[ConnectionStatus]` |
| `PUT` / `DELETE v1/connections/<provider>` | token | Checks a credential with one real call, then stores it, or removes it |
| `WS v1/connections/codex/device-login` | token | Codex's device login |
| `WS v1/translate` | token | One translation, streamed. `TranslateRequest.scope` is `statement` (the default: the whole pipeline for one statement, ends with a `Translation`) or `argument` (gate and breakdown only, for pasted English: ends with an `ArgumentBreakdown`). `descriptors` carries the board's letter names so claims keep their letters. |
| `POST v1/sync` | signed in | `SyncRequest` → `SyncResponse` |
| `WS v1/sync/live` | signed in | `SyncLiveMessage.changed(cursor:)` whenever another device pushes |
| `POST v1/apple/notifications` | Apple's signature | Sign in with Apple's server-to-server notifications. Called by Apple, never the app. |
| `POST` / `DELETE v1/boards/<board>/invites` | signed in, owner | `CreateBoardInvite` → `BoardInvite`, the first one shares the board. `DELETE` revokes every open link. |
| `POST` / `DELETE v1/boards/<board>/members/<member>` | signed in, owner | `UpdateBoardMember` → `204`, or removes them |
| `DELETE v1/boards/<board>/share` | signed in, owner | Stops sharing: everyone else loses the board, the owner keeps it |
| `POST` / `DELETE v1/boards/<board>/analysis` | signed in, can edit the board | `BoardAnalysisRequest` → `202`, and the run carries on without the request. `DELETE` stops it, keeping what's been written. See Board analysis. |
| `POST v1/boards/<board>/report` | signed in, on the board | `ReportBoard` → `204`. Saves the reason for whoever looks after the server, see [Reporting a board](#reporting-a-board). 10 an hour per account. |
| `POST v1/invites/preview` | version header only | `BoardInviteToken` → `BoardInvitePreview`. 30 a minute per address. |
| `POST v1/invites/accept` | signed in | `AcceptBoardInvite` → `JoinedBoard`. Accepting twice, or as the owner, keeps the role you have. |
| `PUT` / `DELETE v1/push/device` | signed in | `PushDevice` → `204`, or forgets this device's token only |
| `GET /.well-known/apple-app-site-association` | nothing | What makes invite links open the app. No version header. |
| `GET /join/<token>` | nothing | A small page for someone without the app. No version header, reads nothing from the database, and its path is never logged. |
| `GET /policy`, `GET /terms` | nothing | The privacy policy and the terms as web pages, made from the markdown in `Sources/ErgoServer/Legal/`. No version header. |

"Signed in" means an Apple ID, an email, or both, on one account. An anonymous account gets `403` `signInRequired` from both sync routes, and from every signed-in route above.

`invalidCredentials` is `401` like a dead token (`unauthorized`), but it's a different `code` and means the device's token is still good. The app must read the code, never the status.

## Running locally

Xcode is a beta at a non-default path, so prefix every `swift` command:

```sh
export DEVELOPER_DIR="/Applications/Xcode 27.3 beta 1.app/Contents/Developer"
cd ErgoServer
swift build
swift test
swift run ErgoServer serve --hostname 127.0.0.1 --port 8080
```

In development the server makes up a vault key when there isn't one, so stored connections only last until it restarts. `claude` and `codex` are found on `PATH`.

Then, by hand:

```sh
curl -X POST -H 'Ergo-Protocol-Version: 1' http://127.0.0.1:8080/v1/accounts
# {"id":"…","token":"…"}

curl -X PUT -H 'Ergo-Protocol-Version: 1' -H "Authorization: Bearer $TOKEN" \
	-d '{"kind":"apiKey","secret":"sk-ant-api…"}' http://127.0.0.1:8080/v1/connections/claude
```

A fake token (`sk-ant-oat01-fake`) costs nothing and must come back as `422` with `credentialRejected`.

Sync needs a signed-in account, so an anonymous account is turned away:

```sh
curl -X POST -H 'Ergo-Protocol-Version: 1' -H "Authorization: Bearer $TOKEN" \
	-d '{"changes":[]}' http://127.0.0.1:8080/v1/sync
# 403 {"code":"signInRequired","message":"Sign in to sync"}
```

Email accounts can be tried entirely by hand:

```sh
curl -X POST -H 'Ergo-Protocol-Version: 1' -H "Authorization: Bearer $TOKEN" \
	-d '{"email":"ada@example.com","password":"correct horse"}' http://127.0.0.1:8080/v1/account/register
# 204, and the sync above now works
```

Signing in with Apple needs a real identity token from the app. To try sync by hand against a scratch database only, mark the account signed in directly: `sqlite3 ergo.sqlite "UPDATE accounts SET apple_subject = 'test' WHERE id = '<account id>'"` (ids are stored as their uppercase text).

## Testing from a device

Debug builds of the app can use this server instead of the hosted one: Settings → Translation → Server → This Mac. `127.0.0.1` only takes connections from the Mac itself, so listen on every interface:

```sh
swift run ErgoServer serve --hostname 0.0.0.0 --port 8080
```

- In the app, enter `http://<Mac name>.local:8080`. The name is `scutil --get LocalHostName`, or System Settings → General → Sharing. The Mac's LAN address works too (`ipconfig getifaddr en0`). The phone and the Mac need to be on the same network, and the macOS firewall may ask to let ErgoServer accept connections.
- The first request shows iOS's local network prompt. If it was turned down, turn it back on in Settings → Privacy & Security → Local Network. Only debug builds have the usage description, so release builds never ask.
- Plain `http://` and `ws://` to a `.local` name or a local address are allowed by the app's `NSAllowsLocalNetworking`, so no other ATS exception is needed.
- Settings → Translation → Test Server (debug builds only) tries REST and the translate socket separately, and shows each one's error as the app would.
- The log is quiet while things work, see [Logs](#logs). To see what reached the server, list your own account in `ERGO_VERBOSE_ACCOUNTS` (an email, or the account id for an account signed in with Apple alone). Its requests then log one line each at `info` with the status:

	```
	[ INFO ] GET /v1/connections 200 [account: …, duration: …, request-id: …]
	[ INFO ] GET /v1/translate 101 (WebSocket upgrade) [account: …, duration: …, request-id: …]
	```

	A translation always starts with `GET /v1/translate`. A status other than 101 is why it was turned away, and that shows for every account, as a `warning` that names the `ServiceError` `code`: 401 `unauthorized` for an unknown account, 426 `outdatedApp` for another protocol version.

	```
	[ WARNING ] GET /v1/translate 401 (WebSocket upgrade) [code: unauthorized, request-id: …]
	```

	With no line at all, either the account isn't a verbose one and it worked, or the upgrade never reached the server, so look at the address, the network, local network access and the firewall.
- Don't run with `--log trace` outside your own machine: Vapor's trace lines print every request's headers, bearer token included.

## Configuration

Everything comes from the environment. `compose.yaml` passes the server everything in the `.env` beside it, so a new variable needs no change there. Each launch logs, by name and never by value, what isn't set: a line for each that leaves something off, and one line for those on their default. A new variable goes in `ServerConfig`'s `featureVariables` or `defaultedVariables`.

| Variable | Default | |
|---|---|---|
| `ERGO_DATABASE_URL` | none | Postgres, as `postgres://user:password@host:5432/database` with the password percent-encoded. Empty or unset uses SQLite. Migrations run at every launch either way. |
| `ERGO_DATABASE_PATH` | `./ergo.sqlite` | SQLite file, created `0600` |
| `ERGO_VAULT_KEY` or `ERGO_VAULT_KEY_FILE` | required in production | 32 bytes, base64. Seals credentials at rest. Make one with `head -c 32 /dev/urandom \| base64`. |
| `ERGO_RUNS_DIRECTORY` | temp + `/ergo-runs` | One scratch directory per CLI call, always removed afterwards |
| `ERGO_CLAUDE_PATH` / `ERGO_CODEX_PATH` | found on `PATH` | The CLIs |
| `ERGO_CLI_DIRECTORY` | none | Set, a CLI that doesn't run at launch gets installed here with npm, and launch waits for it. Needs `ERGO_CLAUDE_CODE_VERSION` and `ERGO_CODEX_VERSION`. The Dockerfile sets all three. |
| `ERGO_RUNNER_PREFIX` | empty | Put before every CLI call, e.g. `setpriv --reuid=ergo-runner …` |
| `ERGO_RUNNER_USER` | none | Who each run directory is handed to while a CLI runs in it, when the prefix switches users |
| `ERGO_MAX_PROCESSES` | 8 | CLI processes at once, across all users |
| `ERGO_STAGE_TIMEOUT` | 120 | Seconds per CLI call |
| `ERGO_MODELS_FILE` | none | JSON overriding the models, see below |
| `ERGO_APPLE_APP_ID` | `com.adonis.Ergo` | The audience Sign in with Apple tokens must have, the app's bundle id |
| `ERGO_TRUST_PROXY` | off | `1` or `true` behind a proxy on the same machine or Docker network, such as nginx or Traefik. `compose.yaml` turns it on. Then the per-address limits use the client address the proxy put in `X-Forwarded-For`, see below. Anything but `1`, `true`, `0`, `false` or empty refuses to start. |
| `ERGO_PUBLIC_URL` | `https://ergo-15.235.184.129.sslip.io` | What invite links are built on |
| `ERGO_APPLE_TEAM_IDS` | `P6PV2R9443` | Comma separated. The teams in the Apple App Site Association file: the app target's team, not the project's. |
| `ERGO_APNS_KEY` or `ERGO_APNS_KEY_FILE` | none | The APNs key (`.p8`, PEM; a literal `\n` is accepted in the variable). Unset sends no pushes, and says so once at launch. One that doesn't read refuses to start. |
| `ERGO_APNS_KEY_ID` | required with a key | The key's id |
| `ERGO_APNS_TEAM_ID` | `P6PV2R9443` | The team the key belongs to |
| `ERGO_APNS_TOPIC` | `ERGO_APPLE_APP_ID` | The `apns-topic`, the app's bundle id |
| `ERGO_APPLE_SIGNIN_KEY` or `ERGO_APPLE_SIGNIN_KEY_FILE` | none | A Sign in with Apple key (`.p8`, PEM; a literal `\n` is accepted in the variable). Unset, deleting an account can't revoke its Apple sign-in, and launch says so once. One that doesn't read refuses to start. See [Revoking Sign in with Apple](#revoking-sign-in-with-apple). |
| `ERGO_APPLE_SIGNIN_KEY_ID` | required with a key | The key's id |
| `ERGO_APPLE_SIGNIN_TEAM_ID` | `P6PV2R9443` | The team the key belongs to |
| `ERGO_APP_STORE_ID` | none | Adds an App Store link and banner to the join page |
| `ERGO_MINIMUM_PROTOCOL` | the oldest the code answers | Apps below it get `outdatedApp` and can't use the server until they update. Raise it once nearly everyone has. |
| `ERGO_RECOMMENDED_PROTOCOL` | the minimum | Apps below it are still answered, with `Ergo-App-Update: recommended` on every reply, and show a badge asking for an update. Raise it only once the newer app is out. |
| `ERGO_VERBOSE_ACCOUNTS` | none | Comma separated emails and account ids of your own accounts, whose activity is logged in full. An email matches in any case. An account signed in with Apple alone has no email on the server, so list its id. Anything that is neither refuses to start, without saying which. Unset logs only problems, for everyone. The list is never logged, only how many entries it has. See [Logs](#logs). |

Production is `serve --env production`. It refuses to start without a vault key, an unreadable models file, or an unknown runner user.

### Models

Users only choose the provider. By default every stage (gate, breakdown, formalize, verify) uses the same model and effort, and checking a new connection uses the gate stage's:

| Provider | Model | Effort |
|---|---|---|
| Claude (`--model`, `--effort`) | `claude-haiku-5-5` | `medium` |
| Codex (`-m`, `model_reasoning_effort`) | `gpt-6-luna` | `medium` |

`ERGO_CLAUDE_MODEL`, `ERGO_CODEX_MODEL` and `ERGO_MODEL_EFFORT` change that for every stage, and take effect at the next restart. For different models per stage, `ERGO_MODELS_FILE` replaces any cell, and the retry policy. The three variables win over the file:

```json
{
	"claude": { "formalize": { "model": "sonnet", "effort": "high" } },
	"codex": { "verify": { "model": "gpt-5.5", "effort": "medium" } },
	"attempts": 3,
	"verifies": true
}
```

A cell replaces the default cell whole, and leaving out `model` or `effort` leaves out the flag.

### OpenRouter

OpenRouter is the one provider that isn't a user's own login. The server calls it directly, with its own key and model, for every stage, Ask and board analysis, and streams the answer like the CLIs do. Both variables are read at launch:

| Variable | |
|---|---|
| `ERGO_OPENROUTER_API_KEY` | The server's OpenRouter key. Leaving it out removes OpenRouter from the app. |
| `ERGO_OPENROUTER_MODEL` | The model id, like `anthropic/claude-sonnet-4.5`. Required with the key. |

It must support tool calls and structured outputs, since requests set `provider.require_parameters`. Every account can use it, so it spends the server's credit, within the allowances below. `ERGO_MODEL_EFFORT` and `ERGO_MODELS_FILE` don't apply to it. It shows in `GET v1/connections` as always connected, and `PUT` or `DELETE` on it are refused.

### Allowances and the paid plan

What an account spends on the server's own model is counted at one reference price, so a free model counts the same as a paid one. A run on someone's own Claude or ChatGPT login is never counted. Days and weeks are UTC.

| Variable | Default | |
|---|---|---|
| `ERGO_OPENROUTER_PLUS_MODEL` | `ERGO_OPENROUTER_MODEL` | The model paying accounts get |
| `ERGO_FREE_DAILY_USD` / `ERGO_PLUS_DAILY_USD` | 0.03 / 1 | The day's allowance, in dollars at the reference price |
| `ERGO_USAGE_PRICE_INPUT` / `ERGO_USAGE_PRICE_OUTPUT` | 0.2 / 1.2 | The reference price, dollars per million tokens |
| `ERGO_FREE_DEEP_PER_WEEK` / `ERGO_PLUS_DEEP_PER_WEEK` | 1 / 30 | Deep research runs a week. A run that fails with nothing written is given back. |
| `ERGO_ENFORCE_PLANS` | off | On, the free plan is held back from what's paid only. Turn it on once the App Store products exist. |
| `ERGO_WEB_SEARCH` | off | Deep research on the server's model sees a few web results, once at the start of a run, and cites what it uses. Costs extra for each run. |
| `ERGO_APPLE_ROOT_CERT_FILE` | none | Apple Root CA G3, as PEM. Without it a purchase can't be verified, and `POST v1/account/plan` is refused. |
| `ERGO_DEVICECHECK_KEY` or `ERGO_DEVICECHECK_KEY_FILE` | none | A `.p8` with DeviceCheck enabled. Without it every account gets the free allowance, so one person with many accounts gets many. |
| `ERGO_DEVICECHECK_KEY_ID` / `ERGO_DEVICECHECK_TEAM_ID` | required with a key | |

A phone's free allowance can move to a different account at most once a calendar month. `GET v1/usage` says what's left, and `POST v1/account/device-claim` claims it.

## Deploying

The Dockerfile builds from the repository root, since the server needs `../ErgoKit`:

```sh
docker build -f ErgoServer/Dockerfile -t ergo-server .

# Once: a vault key in the data volume, readable only by the server
docker run --rm -v ergo-data:/data --entrypoint sh ergo-server -c \
	'head -c 32 /dev/urandom | base64 > /data/vault.key && chown ergo:ergo /data/vault.key && chmod 600 /data/vault.key'

docker run -d -p 8080:8080 -v ergo-data:/data ergo-server
```

- Claude Code and Codex are pinned with the build arguments `CLAUDE_CODE_VERSION` and `CODEX_VERSION`. Bump them deliberately: the server relies on their flags and output formats. The image build fails if either doesn't run, and if one stops running anyway, the server installs that version again at launch. Neither CLI is ever interactive, so there's no onboarding: each call is `claude -p` or `codex exec` in an empty home, with only that account's credential.
- Put it behind a TLS-terminating proxy. Sockets ping every 20 seconds so a proxy doesn't drop a slow translation or a quiet sync socket.
- New accounts are limited per client address, 5 an hour, and so are registrations (10 an hour) and failed logins. Behind a proxy every request comes from the proxy's own address, so without `ERGO_TRUST_PROXY=1` all clients would share one limit. With it, the right-most `X-Forwarded-For` entry that isn't a local address is the client: the proxy appended it, and everything to its left is the client's to make up. nginx needs `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`. It only applies when the connection itself comes from this machine or a private network (`127.0.0.0/8`, `::1`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`), so a client on the internet that reaches the server directly can't set it. Anything else on that private network can, so never set it on a server that is reachable without the proxy.
- Run one instance. The sync socket's broadcaster is in memory, so a push on one instance wouldn't reach devices connected to another. More than one would need Redis pub/sub (or similar) between them, and Postgres rather than SQLite.
- Sign in with Apple fetches Apple's public keys from `appleid.apple.com` and caches them, so the server needs outbound HTTPS.

## Security model

The CLIs run with users' secrets on a machine holding everyone's sealed credentials.

- **Storage:** credentials are sealed with AES-GCM. The associated data is `<account>/<provider>`, so a sealed blob only opens in its own row. Account tokens are stored only as their SHA-256.
- **No tools:** Claude gets `--tools ""`, no settings files and no MCP servers. Codex gets a read-only sandbox, every tool-like feature disabled, no user config and `--strict-config`, so a setting a newer Codex no longer knows fails the call instead of quietly leaving a tool on. Prompt injection can then only produce wrong output, which the app re-parses anyway.
- **Isolation:** every call gets a fresh `0700` directory, with `home/` as its `HOME` and `work/` as its working directory, and an environment built from nothing: a minimal `PATH`, `HOME`, `TMPDIR`, `LANG`, and exactly one credential variable. Nothing from the server's environment reaches a CLI. The user's English only ever reaches a CLI on stdin, as JSON, never in argv.
- **Codex logins:** `auth.json` is written `0600` for each call and read back afterwards. If Codex refreshed it, it's sealed and saved again. Refresh tokens rotate, so each account runs one thing at a time: a second translation, or a connection check, gets `busy` while one is running.
- **Users in production:** the server runs as `ergo`, and every CLI runs as `ergo-runner` through `ERGO_RUNNER_PREFIX`.
  - `/data` (database and key file) is `0700 ergo`, so the runner can't read it.
  - Each run directory is handed to `ergo-runner` with `chown` before the call and taken back afterwards, so the server can read the answer and delete it. The runs directory itself is `0711`: the runner can reach the run it's given but can't list the others.
  - For that the server needs `setuid`, `setgid` and `chown` and nothing else. The image starts as root only long enough to drop to `ergo` with exactly those three as ambient capabilities. The runner prefix clears them again before the CLI starts.
  - All runs share one runner user, so a CLI could in principle reach another call's directory if it knew its random name. With no tools that isn't reachable from a prompt.
- **Email and password:** bcrypt through Vapor's password hasher on its thread pool, so a hash never blocks an event loop. Cost 12, `passwordCost` in tests. Passwords are 10 to 72 bytes (UTF-8) with no NUL, since bcrypt only reads 72 and would quietly accept anything after them; they're hashed as given, with no trimming or normalizing. Emails are trimmed, Unicode-normalized and lowercased, at most 254 bytes, with one `@` and a dot in the domain, and kept in the clear (a login looks them up) behind a unique index. The shapes are `AccountEmail` and `AccountPassword` in ErgoKit, so the app can check before sending. A password is never stored, logged or sent back, and a hash never leaves the server.
- **No account enumeration:** a login for an unknown email checks the password against a made-up hash, so it takes as long as a wrong password, and both answer with the same `invalidCredentials`. Registering an email that's taken does say so (`emailInUse`), which the app needs to offer signing in instead. Anyone can find out whether an email has an account by trying to register it.
- **Brute force:** 10 failed logins per 15 minutes per client address and 10 per email, counted whether or not the email has an account, answered with `rateLimited` and how long to wait. Wrong current passwords when changing a password count too. A success forgets that email's failures, not the address's. In memory, so a restart forgets. The cost: anyone can use up an email's failures to lock its owner out of logging in for 15 minutes.
- **Lost devices:** changing the password deletes every other device's token and closes their live sockets. Signing in with the password on a device doesn't sign the others out.
- **Logs:** see [Logs](#logs) for what is said and to whom. Never request bodies, secrets, CLI output or synced values. Emails, passwords and hashes are never logged: SQL query logging is off (it prints bound values at debug), and the email routes use a database handle at `info` so Fluent's own debug log of every query stays quiet. Tests capture the server's logs at `trace` through a real register, login and password change and check none of them appear.

## Sync

Sync follows `Plans/05-Sync.md`. The merge rules are ErgoKit's `ErgoSync`, so the server and the app merge identically.

- **Accounts and devices:** an account starts anonymous, one per install. Each device has its own token (`account_tokens`), so one device can sign out without the others.
- **Sign in with Apple:** the identity token's signature, issuer, expiry and audience (`ERGO_APPLE_APP_ID`) are checked with Apple's keys, and its `nonce` claim must be the SHA-256 (lowercase hex) of the raw nonce the app sends alongside, so a token meant for another sign-in can't be replayed.
  - No account has that Apple ID yet: the caller's account takes it.
  - Another account has it: the caller's account is merged into it in one transaction. Connections move only for providers the target has none for, synced records merge with `SyncRecord.merge`, the caller's token moves over, and the caller's account is deleted. The device keeps its token.
  - A device already signed in to a different Apple ID has to sign out first.
- **Records:** one row per record (`sync_records`). The fields are sealed with the same key as credentials, with associated data `<account>/sync/<kind>/<id>`, so a board's text is never at rest in the clear and a row can't be moved to another account or record. The server opens them only to merge. In the clear are only the kind, id, seq, when it last changed, for a tombstone when it was deleted and, for a statement or link, which board it is on.
- **Seq:** every record that changes takes the account's next seq, in the same transaction, so a cursor is exactly "everything up to here". Each sync transaction starts with a write, so SQLite hands it the write lock before it reads anything, and two syncs of one account can't take the same seq.
- **One request does both directions:** the push is applied, then everything after the cursor comes back in seq order, at most `limit` records (default 500, at most 1000) and about 4 MB. `more` says to ask again.
- **Conflicts:** an edit whose base isn't what the server has is concurrent. It still merges by stamp, and only the device that pushed it gets the losing value in `superseded`, so the copy is made exactly once.
- **Kinds:** `board` (`created`, `deleted`), `statement` (`board`, `position`, `content`, `deleted`), `link` (`board`, `premise`, `conclusion`, `deleted`), `scratchpad` (`created`, `descriptor.0`…`5`, `content`, `deleted`), `bookmark` and `setting`, and the server-owned `share`, `annotation` and `analysis`. Board, statement, link and scratchpad ids are uppercase UUIDs. A statement's `content` (`english`, `logic`, `source`, `translation`) is an opaque JSON value to the server, like a board's used to be. Two devices typing in one statement at once give the later pusher a `superseded` `content` for that statement alone; moving a box never conflicts with typing in it.
- **Limits:** a body of 1 MB, a value of 256 KB, 50,000 records per account (statements and links count), 60 syncs a minute per account, and no stamp more than 10 minutes ahead of the server's clock. Kinds, field names and ids are checked against ErgoSync's lists.
- **Pruning:** at launch and then daily, tombstones whose `deleted` stamp is over 90 days old are removed and the account's `prunedThrough` moves past them. A device whose cursor is below it, or ahead of the account, gets `410` `syncResetRequired` and pulls from the start. When a board's tombstone is pruned its statements and links go too, and statements and links with no board record (or no `board` field) go once they're 90 days old; those don't move `prunedThrough`. The owning board's id is kept in a `board_id` column, in the clear like the record id, so none of this opens a sealed row. Annotations and analysis statuses go with their board the same way. Devices ignore a statement or link whose board is deleted or missing on read, so nothing waits on the server.
- **Live:** `WS v1/sync/live` sends `changed(cursor:)` to every socket of the account except those of the token that pushed. Signing out closes that device's sockets, and deleting the account closes all of them.

- **Email accounts:** `accounts.email` (unique) and `accounts.password_hash`, both empty until someone registers. An account can have an Apple ID and an email at once, and either gets back in.
  - Registering needs a token and attaches to that device's account. An account has one email.
  - Logging in is the Apple flow with a password: it refuses a device that's already signed in as another account ("sign out first"), and otherwise merges the anonymous account in with `AccountMerger`. `isNewAccount` is always `false`, since an email can only be logged in to once registered. `AccountMerger` refuses to merge away an account that has an email.
  - An account with an email isn't deleted when its last device signs out.

## Sharing boards

Sharing follows `Plans/09-Sharing.md`. Each member keeps their own copy of a board's records, sealed for their account, and the server copies every change to the others, each taking that account's own seq. Who's on a board reaches devices as a `share` record, which only the server writes.

- **Tables:** `board_shares` (the board's id, its owner, the title sealed by the vault), `board_members` (role and name, unique per board and account; the owner has a row too), `board_invites` (only the token's hash, 30 days, at most 20 open per board), `push_devices` (one per APNs token, tied to the account token, so signing out of a device stops its pushes) and `reports`, see [Reporting a board](#reporting-a-board).
- **Pushing:** a change on a board the caller can't edit, or a pushed `share`, comes back in `SyncResponse.rejected` with what the account has, and the rest of the request goes through. A board record with only `deleted: true` is allowed from anyone: the owner's deletes for everyone, and a member's leaves.
- **Locks:** everyone on a touched board is locked in sorted order before a shared write, so two pushes can't deadlock on Postgres.
- **Limits:** 30 people per board. What other members' pushes copy in doesn't count towards the 50,000 records, so nobody's limit can fail someone else's push.
- **Pushes:** `Sharing/Push/`, with no dependency beyond swift-crypto and Vapor's client. Edits alert at most once per board and person per 15 minutes, otherwise silently at most once per account per minute. A device with a live socket gets nothing. In memory, so a restart forgets. A `410`, `BadDeviceToken` or `Unregistered` deletes the device.
- **Logs:** never an invite token, an APNs token, a title or a name. The sharing routes use the quiet database handle, and the request log says `/join` for an invite link. A push that couldn't be sent is a `warning` with Apple's reason or the status, for the person it was meant for. Everything else is for verbose accounts.

## Sign in with Apple notifications

Apple posts to `POST v1/apple/notifications` when someone changes their Hide My Email forwarding, stops using Sign in with Apple with Ergo, or deletes their Apple Account. It's the server's only route that Apple calls rather than the app.

- **Body:** JSON `{"payload": "<JWT>"}`, or the same `payload` field as `application/x-www-form-urlencoded`. At most 16 KB.
- **Exemptions:** no bearer token, and the only request `ProtocolVersionMiddleware` lets through without `Ergo-Protocol-Version`, since Apple doesn't send it. Only `POST` to exactly this path is exempt.
- **Checks:** the JWT's signature against Apple's published keys (`https://appleid.apple.com/auth/keys`, fetched and cached the same way as for signing in), `iss` is `https://appleid.apple.com`, `aud` is `ERGO_APPLE_APP_ID`, and `iat` is at most a day old and at most 5 minutes ahead of the server's clock. `events` is JSON inside a string; only its `type` and `sub` are read, so `email`, `is_private_email` (a bool or a string) and `event_time` can come in any shape.
- **Answers:** an empty `200` for every verified notification, including one about an Apple ID no account has, one already handled, and an unknown type, so Apple doesn't retry. `400` with the same vague `ServiceError` for anything that doesn't verify, whatever the reason. `413` for a body over 16 KB, `429` after 120 a minute from one address (per address as for the other limits, so `ERGO_TRUST_PROXY` applies), and `502` if Apple's keys can't be fetched, so Apple tries again later.
- **Replays:** each `jti` is remembered for 25 hours (a day being the oldest `iat` accepted) and a repeat is answered `200` without doing anything. If handling fails, the `jti` is forgotten so Apple's retry is handled. The set is in memory, so a restart forgets it: a notification captured in the day before a restart could be handled once more. Every event is safe to repeat except that a replayed `consent-revoked` would sign out devices that signed in again since.

| Event | What the server does |
|---|---|
| `email-enabled`, `email-disabled` | Nothing. The relay address is never stored. |
| `consent-revoked` | Deletes every device token of the account with that `sub` and closes its live sockets, so each device is signed out on its next request. The account, its `appleSubject` and all its data stay, so signing in with Apple again gets back to them. |
| `account-delete` | That Apple ID can never sign in again. An account that also has an email only loses its `appleSubject`, and its devices stay signed in. Otherwise the whole account goes, exactly like `DELETE v1/account`: connections, synced records, every token, and its live sockets. |
| anything else | Nothing, and the type is logged as a `warning`. |

This route has no account of its own, so a handled notification is only logged, as an event type and whether an account matched, for a verbose account it was about. A notification that doesn't verify, a repeat, or an unknown type is a `warning` (the first two at most once a minute). Never the `sub`, an email, a token or the JWT, and the route's queries use the quiet database handle, so Fluent's debug log can't print the `sub` either.

**Registering it**, once the server is hosted: in the developer portal, open Certificates, Identifiers & Profiles → Identifiers → the App ID `com.adonis.Ergo` → Sign in with Apple → Configure (or Edit), and set **Server-to-Server Notification Endpoint** to `https://<production host>/v1/apple/notifications`. It must be an absolute HTTPS URL with TLS 1.2 or later, and there's one per primary App ID group. Then save the App ID.

## Reporting a board

`POST v1/boards/<board>/report` is how a member says a shared board has something on it that shouldn't be. Anyone on the board can send one, the owner too. It follows App Store guideline 1.2: blocking is leaving the board (a member) or removing someone (the owner), which already exist, and this is the way to tell someone who can act.

- **Request:** `ReportBoard`, a `reason` of 1 to 1,000 characters after trimming. `invalidRequest` for anything else. The same `invalidRequest` ("Expected a board you're on, found none with that id") for a board the caller isn't on and one that doesn't exist, so it can't be used to find boards. A member who left or was removed isn't on it any more.
- **Answers:** `204`. 10 an hour per account (`429` `rateLimited`), counted only for reports that are saved, and in memory, so a restart forgets.
- **Table:** `reports` has the id, when, the reporter's account id, the board's id, the board owner's account id, the reason, and `handled`, empty until dealt with. No foreign keys, so a report outlives the accounts and the board it names, and deleting an account doesn't remove the reports it sent.
- **Nothing is sent yet.** There is no mail provider, so a report only waits in the table: read it with the database. The plan is for a mail provider to send every row whose `handled` is empty to whoever looks after the server, and set `handled`.
- **Logs:** one `warning` for each saved report with the report's id, which is how to find it in the table. Never the reason, which is a stranger's words about someone else's board, or the board's id.

## Board analysis

`POST v1/boards/<board>/analysis` starts an agent that goes through a whole board and annotates it with what's relevant in the library. It follows `Plans/10-BoardAnalysis.md`. The instructions are `Prompts/BoardAnalysis/analyse.md`, and the model is `ask`'s, from the models file.

- **Starting:** the body is at most 2 MB. `problem` is `invalidRequest`, and so is a board that isn't a live record of the account ("Expected a synced board, sync and try again") or a shared one the caller can only view. A run already going on the board, or three on the account, is `busy`. It answers `202` once the `analysis` record says `running`.
- **The job outlives the request.** `BoardAnalysisJobs` owns the tasks, one per board and three per account, and cancels them on shutdown. It uses the application's database and logger, never the request's. In memory, so a restart loses a run, and the `running` record is shown as interrupted once it's older than `BoardAnalysisStatus.staleAfter`.
- **Tools:** the CLI reaches this run's tools at the same `v1/ask/tools/<token>` route Ask uses, now with a responder per token (`AskRuns`), so a token is Ask's or an analysis's. Claude Code's `--allowedTools` is `BoardAnalysisTools.names`, with up to 400 turns and 600 seconds.
- **Reports** are checked in `BoardAnalysisTools` (ErgoKit), and each accepted one is written straight away as an `annotation` record in every member's row, in one transaction with them locked in order (`BoardLedger.writeServerOwned`). When the run finishes well, annotations from other runs are tombstoned for everyone, the `analysis` record says how it went and holds the discussion (at most 40,000 characters), and a silent push syncs devices without a live socket. A job on a board that was deleted, or that the person left, stops without writing.
- **Long sources in parts:** `BoardAnalysisRequest.passes()` (ErgoKit) cuts any source over 50,000 characters with Break Down's `TextParts`, and the job makes one model call per pass, one after another, in the same run. The first has the whole board with each source's first part. Each later one has only the next parts, with the cards and arrows in its message as context, and tools built from just those parts, so a quote is checked against the part the model read and nothing on the board is reported on twice. What's left of the 150-report limit carries over, only the first pass's words become the discussion, and before each later pass the `analysis` record gets a new `heartbeat`, so a run longer than `staleAfter` isn't shown as interrupted. Each pass has its own 600 seconds.
- **One call at a time:** a Claude Code login doesn't take the per-account lock, so a run doesn't block Ask. A Codex login keeps it: the job checks every 3 seconds for up to 5 minutes, and Ask answers `busy` meanwhile.
- **Sync:** `annotation` (`board`, `content`, `deleted`) and `analysis` (the same, id = the board's) are server-owned like `share`: a pushed one is rejected. Joining a shared board copies them with the rest, since they carry `board`.
- **Logs:** counts and states only: how many parts, and each later part's number and size in characters. Never the board's text, a report, the discussion or the token. A run that fails, or is cut short by a shutdown, is a `warning` for everyone, and waiting for a Codex login's turn is said once.

## Revoking Sign in with Apple

App Store guideline 5.1.1(v) wants deleting an account to revoke its Sign in with Apple, so Apple stops listing Ergo for the person. Apple only revokes with a refresh token, which a sign-in's `authorizationCode` buys once.

- **Off without a key.** Set `ERGO_APPLE_SIGNIN_KEY` (or `_FILE`), `ERGO_APPLE_SIGNIN_KEY_ID`, and `ERGO_APPLE_SIGNIN_TEAM_ID` if it isn't `P6PV2R9443`. The client id is `ERGO_APPLE_APP_ID`. Without a key the code is ignored and nothing is revoked.
- **Signing in:** the app sends `SignInWithAppleRequest.authorizationCode` (optional, so older apps still work). With a key, the server posts it to `https://appleid.apple.com/auth/token` (`grant_type=authorization_code`) with a client secret: an ES256 JWT signed with the key (`iss` the team, `sub` the client id, `aud` `https://appleid.apple.com`, five minutes), made by the same signing as APNs and DeviceCheck. The `refresh_token` it returns is sealed with the vault (associated data `<account>/apple/refresh`) into `accounts.apple_refresh_token` of the account that signed in, which after a merge is the surviving one. A newer token replaces the older. If the reply's id token names a different Apple ID, nothing is kept.
- **A failed trade never fails the sign-in.** The code is single use and expires in minutes, so it isn't retried. The log says only why Apple refused or what the error was, never the code.
- **Deleting:** `DELETE v1/account` posts the stored token to `https://appleid.apple.com/auth/revoke` (`token_type_hint=refresh_token`) before the account's rows go. A failure logs a warning and the account is deleted anyway. Signing out of a device, and Apple's own `consent-revoked` and `account-delete` notifications, revoke nothing: Apple already knows. An `account-delete` for an account that also has an email forgets the stored token.
- **Anyone who signed in before this shipped** has no stored token until they sign in again, so deleting their account can't revoke it.
- **Logs:** never the code, a refresh token or the client secret. A trade or a revoke that fails is a `warning` for everyone.

**In the developer portal**, once: Certificates, Identifiers & Profiles → Keys → add a key with **Sign in with Apple** turned on, configured for the primary App ID `com.adonis.Ergo`. Download the `.p8` (Apple offers it once), note its Key ID, and set `ERGO_APPLE_SIGNIN_KEY_FILE` and `ERGO_APPLE_SIGNIN_KEY_ID`. Only app builds that send `authorizationCode` fill it in, and each person has a token after their next sign-in with Apple.

## Logs

Two kinds of reader share one log. Everyone's accounts get silence while things work and a line when something doesn't. Your own accounts, listed in `ERGO_VERBOSE_ACCOUNTS`, get everything they do. Nothing is logged for the first kind that could say who it was or what they wrote.

**For every account**, only problems, as `warning` for what recovered or was refused and `error` for what shouldn't happen:

- A request that failed: its method, the route as written in `routes.swift` (`/v1/boards/:board/members/:member`, never the ids in it), the status and the `ServiceError` `code`. That covers a dead token (401 `unauthorized`), a protocol version too old (426 `outdatedApp`), a wrong password (401 `invalidCredentials`), a limit hit (429), an account that is busy (409) and an upgrade that was turned away (any status but 101). A line that can repeat is said once a minute per route, status and code, and `leftOut` says how many weren't. A 500 is an `error` with the kind of error.
- A run that was refused before it started, a CLI that timed out, couldn't be run or answered in the wrong shape, a provider that failed, a run that failed, a retry of the schema, and a login that Codex or Apple refused.
- A sync push that was rejected, a push that Apple refused, a purchase that didn't verify, a board that was reported, a board analysis that failed or was cut short, Apple's keys that couldn't be fetched, a notification or sign-in that didn't verify.
- A record or a credential that won't unseal, a run directory that couldn't be removed, a connection's status that couldn't be saved.

A line that belongs to an account says `who`, a short pseudonym: the first 8 hex characters of the SHA-256 of the account's id as the database has it (uppercase), so the same account always has the same one, and it doesn't give the id away. To find one for an id you have: `printf %s 3F2504E0-4F89-11D3-9A0C-0305E82C3301 | shasum -a 256 | cut -c1-8`.

**Verbose accounts add**, at `info`, with `account` set to the real id:

- Each request and its status and duration, with its real path (still never an invite or tool token), and each socket opening (the `101` line) and closing, with how long and how it ended.
- Each run: starting, finishing with its duration and counts, and each CLI call with its stage, exit status and token usage, and OpenRouter calls and rounds with their sizes.
- Each sync with how many records went each way (pushed, changed, returned, superseded, rejected), each invite, join, member change and stop sharing, a push device registered, each analysis starting and finishing.
- Each purchase, allowance check and use of the allowance, sign-in, registration, password change, connection, and an account being deleted.
- When something fails, the details a stranger's line leaves out: the error in full, the CLI's last lines of stderr (with the credential and anything shaped like a key taken out), and what a provider said.

**Never logged**, for anyone, verbose accounts included: account tokens, provider credentials and API keys, invite tokens, Ask tool tokens, authorization codes, refresh tokens, passwords and hashes, push tokens, emails, Apple's `sub`, and anything anyone wrote (questions, answers, board text, titles, names, a report's reason, shared text). Sizes and counts instead. The list in `ERGO_VERBOSE_ACCOUNTS` is never logged either, only how many entries it has.

**How an account is known to be yours.** The request's token gives the account's row, so its email is compared with the list (in any case) as it signs in, and again when an email is attached to it. The result is remembered, so a run that outlives its request, a push or a socket needs no query. An account that hasn't made a request since launch isn't known by its email until it does, and one listed by its id always is.

**Reading a line:**

```
[ INFO ] POST /v1/sync 200 [account: 3F2504E0-4F89-11D3-9A0C-0305E82C3301, duration: 0.021 seconds, request-id: …]
[ INFO ] Synced [account: 3F2504E0-…, pushed: 4, changed: 4, returned: 2, superseded: 0, rejected: 0, more: false, request-id: …]
[ WARNING ] POST /v1/sync 429 [who: 9c1d02ab, code: rateLimited, request-id: …]
[ WARNING ] Translation failed [who: 9c1d02ab, provider: claude, code: timedOut, duration: 120.4 seconds, request-id: …]
```

`account` is a listed account's id. `who` is anyone else's pseudonym. `request-id` ties the lines of one request together. A run that outlives its request (an answer, a breakdown, an analysis) logs without it. `code` is the `ServiceError` code the app was given.

**For the code.** `AccountAuthenticator` makes `request.logger` the account's, with `VerboseAccounts` (`request.ergo.verbose`). On it, `info` and below are dropped unless the account is listed, and `warning` and `error` carry the pseudonym. Use `logger.verbose(…)` for anything that is as normal as it gets, since it does nothing on a logger that isn't a verbose account's. Work that outlives the request takes `request.jobLogger(for: account)`, and a change to which account a request is about (a sign-in that merges) calls `request.identify(_:)`. Use `logger.reason(for: error)` for an error, since a database's can quote what was being saved.

## Known gaps

- **Emails aren't verified.** Nothing is sent to the address, so anyone can register an email they don't own, which then can't be registered by its owner. There's no mail provider yet.
- **There's no password reset.** Forgetting the password loses the email sign-in, unless the account also has Sign in with Apple. Both need a mail provider, so that's a planned item: verification mail at registration, and a reset link.
- **The login lockout can be used to annoy.** See Brute force above.

## Tests

`swift test` is offline. Shell scripts stand in for `claude` and `codex`, so it never uses a real login, a fake `AppleTokenVerifier` stands in for Apple, a fake `AppleRefreshTokens` for its token and revoke calls, and a `PushSender` that only keeps what it's given stands in for APNs. The socket and sync tests run a real server on a free port and talk to it with the app's own `ErgoClient`, and two real `SyncReplica`s converge through the actual route.

Codex can't be called from the network this was built on, so its command line follows the 0.166 docs and `codex exec --help`, and is only exercised with fakes.

## Ask

`WS v1/ask` answers one turn of a conversation with the user's own CLI, streaming text, tool activity and buttons. It needs a signed-in account, and shares translation's one call at a time per account. The model comes from the `ask` key of the models file, which defaults to `claude-sonnet-5-5` and `gpt-6-luna`.

- The CLI runs with none of its own tools. It reaches Ergo's over MCP at `http://127.0.0.1:<port>/v1/ask/tools/<token>`, so the runner user needs to reach the server on loopback.
- The token is random, lasts as long as the answer, and is the route's only auth. It can read the library and add buttons to its own answer. The request log leaves it out.
- **An answer outlives its socket.** It's a detached run (`DetachedRuns`, ErgoKit), keyed by the account and the request's `id`, and only a `cancel` message stops the CLI. Closing the socket, or the app being force quit, doesn't. The run buffers everything it says, so the app sends the same request again when it's back: the same `id` joins the run and hears it from the start, and an `id` the server no longer has simply starts again. A finished run is kept for an hour (`DetachedRuns.defaultRetention`), at most three are running per account (`busy` after that), and all of them are cancelled when the server shuts down. They're in memory only, so a restart loses them and the app asks the question again; the conversation itself is never stored. They use the application's database and logger, never the request's. A silent push on finish isn't sent: Ask is only ever resumed by the app being opened.
- **Break Down is the same.** A `translate` request with scope `argument` is a detached run too, with the same rules. Scope `statement`, which only Evals uses, still stops when its socket closes. The Codex device login also stops when its socket closes.
- `ErgoCatalog`'s resource bundle has to ship beside the binary. The Dockerfile already copies every `*.resources` directory.
