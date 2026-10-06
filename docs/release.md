# Release

PP-REL-03 (closed beta and Play Store release) is **not done**. This page is its checklist and the record of what is still blocked. Everything marked "human" needs a person, a real device, a real provider or provisioning; no code in this repo can tick it.

## Beta gate (spec "Gerbang beta")

The beta starts when the full money path works end to end on staging: bill → pay → webhook → paid, cash, cancel. Sprint 6 tickets do not block payment; if the gate is missed the beta slips, the payment scope is not cut.

- [ ] (human) All sprint 1–5 tickets merged and the Definition of Done in `docs/spec.md` met for each, including the manual test on a low-to-mid-range Android phone.
- [ ] (human) Staging runs the merged `main` with the variables below and a tester can log in and pay a test bill end to end.
- [ ] (human) 5–10 real groups invited into Play **internal testing** during sprint 6.
- [ ] (human) Crash-free sessions ≥ 99 % over the beta, read from Sentry (project `app`, release health) and Play Console vitals. Both numbers are recorded here with the date when measured: _not measured yet_.
- [ ] (human) Release only after every P0 ticket is done. Open P0 bugs from the beta are fixed first.

### Reading the MVP metrics during the beta

PP-REL-02 records four events on the server (table `metric_events`, no phone numbers or names): session build duration (first cost or attendance edit → issue), bills sent, time to paid (issue → paid by gateway or cash) and paid without install (gateway payment by a member with no linked account).

```sh
# Against staging or production, with the secret:
curl -H "authorization: Bearer $METRICS_TOKEN" https://<host>/api/admin/metrics
# Against a local database (a release has no Mix):
cd api && mix petepete.metrics
```

The endpoint answers 404 while `METRICS_TOKEN` is unset and 401 on a wrong token. It reports the last 30 WIB days, as totals and per day: sessions billed, median / p90 build duration, bills sent, median / p90 time to paid, bills paid, bills paid without install and their share of paid bills. A bill paid by credit at issue is not a paid bill here; a bill whose cash is cancelled and taken again counts once.

## Play Store listing (all human)

- [ ] App name, short description (≤ 80 chars) and full description in Indonesian casual language, matching the UI tone.
- [ ] Icon 512×512, feature graphic 1024×500, at least 2 phone screenshots (host session flow; pay page).
- [ ] Privacy policy URL: the public page from PP-REL-01 (data stored, account deletion right, balance is not stored money). Required before any release track beyond internal testing.
- [ ] Data safety form: phone number and name collected, linked to the user, used for account and app function; no sale, no ads; deletion on request (`DELETE /api/me`).
- [ ] Content rating questionnaire and target audience (adults).
- [ ] App signing: Play App Signing enabled, upload key kept out of the repo.
- [ ] Release build with `--dart-define=SENTRY_DSN=<app-project-dsn>` and `SENTRY_ENVIRONMENT=production` (see `docs/deploy.md`, "Error monitoring").
- [ ] Production API reachable from the app build (`PHX_HOST`, TLS), pay link host matches `WEB_BASE_URL`.

## Runtime configuration the API reads

Authoritative source: `api/config/runtime.exs`. `.env.example` lists every variable. Prod fails to boot (and so does the release command `/app/bin/migrate`) when a required one is missing.

| Variable | Where | Required in prod | Notes |
| --- | --- | --- | --- |
| `DATABASE_URL` | Fly secret (set by `fly mpg attach`) | yes | Postgres 16/17 on Fly |
| `SECRET_KEY_BASE` | Fly secret | yes | `mix phx.gen.secret` |
| `PHX_HOST` | `api/fly.*.toml` `[env]` | defaults to `example.com` | public hostname |
| `OTP_HMAC_KEY` | Fly secret | yes | ≥ 32 bytes; keys OTP hashes; rotating voids pending codes |
| `OTP_SENDER` | Fly secret or `[env]` | to log anyone in | module name implementing `Petepete.Accounts.OtpSender`, e.g. `Elixir.Petepete.Accounts.OtpSender.<Provider>`; the fake is refused in prod; boot fails without it |
| `PAYMENT_GATEWAY` | `api/fly.*.toml` `[env]` | yes, no default | only `fake` exists; staging sets it, production leaves it unset on purpose |
| `WEB_BASE_URL` | Fly secret or `[env]` | yes | origin of the web app; invite links are `<WEB_BASE_URL>/join/<token>` |
| `METRICS_TOKEN` | Fly secret | no | bearer secret of `GET /api/admin/metrics`; unset = the endpoint is 404. Generate with `openssl rand -base64 32` |
| `SENTRY_DSN` | Fly secret | no | unset or blank disables Sentry |
| `SENTRY_ENVIRONMENT` | `api/fly.*.toml` `[env]` | no | `staging` / `production` |
| `POOL_SIZE`, `ECTO_IPV6`, `DNS_CLUSTER_QUERY`, `PORT`, `PHX_SERVER` | `[env]` | no | defaults in `runtime.exs` |

Staging example:

```sh
fly secrets set -a petepete-staging --stage METRICS_TOKEN="$(openssl rand -base64 32 | tr -d '\n')"
```

Other layers: web `NEXT_PUBLIC_SENTRY_DSN` (Vercel env var), app `--dart-define=SENTRY_DSN=...`. See `docs/deploy.md`.

## Known blocked items

- **Payment gateway not chosen** (spec open question, blocks PAY-01): only the `fake` adapter exists, which moves no money. `fly.production.toml` leaves `PAYMENT_GATEWAY` unset, so production cannot deploy and real group money cannot flow. A real beta with money needs the Xendit/Midtrans decision, sandbox credentials, sub-account KYC and a real `Petepete.Payments.Gateway` adapter (`docs/deploy.md`, "Gateway adapter").
- **WhatsApp OTP provider not chosen** (spec open question, blocks AUTH-01 in practice): no real `Petepete.Accounts.OtpSender` adapter exists, so a production release does not start and nobody can log in outside dev/test.
- **No Sentry projects, Vercel project or Play Console app are provisioned from this repo.** DSNs and the internal testing track are human setup.
- **Crash-free ≥ 99 %**, the beta groups and the Play Store listing cannot be verified before the beta runs.
- **Open spec assumptions** still to confirm: pay link validity (max 30 days) with the gateway rules, and the Tandai-lunas-on-`needs_review` limit in "Batasan P0".
