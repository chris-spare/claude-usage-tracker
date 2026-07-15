# Investigation: should we auto-refresh the OAuth token?

**Status:** investigated, **not implemented** (deliberately). This documents what
we learned so a future change can be done safely — or so we can decide it's not
worth it.

## Background

`ClaudeUsageFetcher` reads the OAuth access token from the login Keychain item
`Claude Code-credentials` (account `$USER`) and calls
`GET https://api.anthropic.com/api/oauth/usage`. The stored JSON is:

```json
{ "claudeAiOauth": { "accessToken", "refreshToken", "expiresAt", "scopes",
                     "subscriptionType", "rateLimitTier" } }
```

The access token expires. When it does we get a `401 authentication_error`. Today
we treat that as transient: we re-read the Keychain every fetch, so once Claude
Code (CC) refreshes the token in the background, our next fetch picks it up. If CC
isn't running long enough for the token to expire, we simply can't fetch until CC
runs again. This is the safe, read-only posture.

## How Claude Code refreshes (ground truth from the CC bundle)

Found in the unminified CC CLI source (`oauth token refresh` path):

- **Endpoint:** `POST https://platform.claude.com/v1/oauth/token`
- **Client ID:** `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- **Body:** `{ grant_type: "refresh_token", refresh_token, client_id,
  scope: "user:profile user:inference user:sessions:claude_code user:mcp_servers" }`
- **Response:** `{ access_token, refresh_token, expires_in }` — the code is
  `refresh_token = <old>`, i.e. **the server may rotate the refresh token**, and CC
  persists whatever it gets back.
- **When:** only within **5 minutes** of `expiresAt` (`Date.now() + 300_000 >= expiresAt`).
- **Write-back:** `security add-generic-password -U -a "$USER" -s "Claude Code-credentials" -X <hex>`
  (the full `claudeAiOauth` JSON, hex-encoded, fed via `security -i`).

CC wraps the whole thing in **four layers of safety**:

1. **In-process singleton** — one in-flight refresh is shared, never duplicated.
2. **Cross-process file lock** (`proper-lockfile`) on the config dir (`$CLAUDE_CONFIG_DIR`
   or `~/.claude`), retried up to 5× on `ELOCKED` with jittered backoff.
3. **Double-checked expiry after acquiring the lock** — re-reads the Keychain and,
   if another process already refreshed while we waited, **bails without refreshing
   again** (`token_refresh_race_resolved`).
4. **401 recovery** — on a 401 it re-reads the Keychain first; if the stored token
   changed, it just adopts it (`401_recovered_from_keychain`) instead of refreshing.

## The risk

**Refresh-token rotation + a race can log the user out of Claude Code.** If our app
and CC both refresh at ~the same time using the same refresh token, the server
invalidates the old one; whoever writes last wins, and the loser is left holding a
**dead refresh token**. Its next refresh fails → CC forces re-authentication. That
is strictly worse than our tray showing a stale-token error.

The user's two instincts are exactly the hazards to design against:
- **Don't refresh multiple times** → needs the in-process singleton + cross-process
  lock + double-checked expiry.
- **Don't leave the old token in place** → must persist the (possibly rotated) new
  token atomically, in CC's exact format, or the two processes desync.

## If we ever implement it: mirror CC exactly

Non-negotiable — replicate CC's protocol faithfully:

1. Read `claudeAiOauth`; only proceed if `expiresAt` is within 5 min (`$p`).
2. Acquire the **same** `proper-lockfile` lock on the CC config dir (same path,
   same stale/mtime semantics, same ≤5 retries w/ jittered backoff). This is the
   fiddly part — a mkdir-based lock with staleness checks; getting it subtly wrong
   reintroduces the race.
3. **After** acquiring the lock, re-read and re-check expiry; if already fresh, do
   nothing (another process — likely CC — just refreshed).
4. `POST` the refresh with the exact `client_id`/`scope` above.
5. Write back the **full** `claudeAiOauth` JSON via
   `security add-generic-password -U … -X <hex>`, preserving every field
   (including a rotated `refreshToken` and the new `expiresAt`).
6. Also honor CC's in-process singleton behavior for our own instances, and add
   401-recovery (re-read before refreshing).

**Caveats:** this couples us to CC's internal lock path and storage format, which
can change between CC versions (brittle). The downside of a bug is breaking the
user's real Claude Code login.

## Recommendation

**Stay read-only.** Don't refresh or write the Keychain. Rely on CC (which holds
the lock and does it correctly) to keep the token fresh, and keep our behavior:
re-read the Keychain each fetch + treat 401 as transient and retry. Optionally, a
zero-risk nicety: read `expiresAt` and, on a 401 with an expired token, show
"Credentials expired — open Claude Code to refresh" instead of the raw 401.

Only revisit self-refresh if there's a real need (e.g. running without CC for long
stretches), and only by mirroring CC's locking exactly as above.
