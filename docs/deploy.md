# Deploy

The API runs on Fly.io in Singapore (`sin`) as two apps, each with its own Managed Postgres cluster and its own GitHub environment:

| Environment | Fly app | Config | Deployed by |
| --- | --- | --- | --- |
| `staging` | `petepete-staging` | `api/fly.staging.toml` | `deploy-staging` job in `.github/workflows/ci.yml`, on every push to `main` after all CI jobs pass |
| `production` | `petepete-production` | `api/fly.production.toml` | "Deploy production" workflow (`.github/workflows/deploy-production.yml`), run manually from the Actions tab on `main` |

Both configs run `/app/bin/migrate` as the release command, so migrations apply before new machines start.

## One-time setup

Needs a Fly account, `fly` and `gh` (logged in to GitHub with access to `zaychoer/petepete`). Run everything from `api/`. Repeat steps 2–5 for each environment: shown here for `staging`; for production replace `staging` with `production` everywhere.

### 1. Log in to Fly

```sh
fly auth login
```

### 2. Create the app

```sh
fly apps create petepete-staging
```

Fly app names are global. If the name is taken, pick another and change `app` and `PHX_HOST` in the matching `api/fly.<env>.toml`.

### 3. Create and attach the database

```sh
fly mpg create --name petepete-staging-db --region sin --pg-major-version 17
fly mpg attach <cluster-id-printed-above> -a petepete-staging
```

`attach` stores the connection string as the app's `DATABASE_URL` secret. Fly Managed Postgres offers 16 and 17 only; local and CI run 18 (see `docker-compose.yml`), so avoid Postgres 18-only features.

### 4. Set the app's secret key

```sh
fly secrets set -a petepete-staging --stage SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')"
```

`--stage` stores the secret without restarting machines; it takes effect on the next deploy.

### 4b. Set the OTP secrets

```sh
fly secrets set -a petepete-staging --stage OTP_HMAC_KEY="$(openssl rand -base64 48 | tr -d '\n')"
fly secrets set -a petepete-staging --stage OTP_SENDER=Elixir.Petepete.Accounts.OtpSender.<Provider>
```

`OTP_HMAC_KEY` keys the hashes of OTP codes and phones (at least 32 bytes). `OTP_SENDER` names the module that delivers OTP codes over WhatsApp. **The app refuses to boot in production without both**, and refuses `OtpSender.Fake` as the sender, so that no login code is ever dropped silently. The provider adapter is not written yet (the choice of WhatsApp provider is an open question in the spec); until it exists a production release does not start.

### 5. Give GitHub a deploy token

The workflow reads `FLY_API_TOKEN` from the GitHub environment named exactly like the `environment:` key in the workflow (`staging` or `production`). Create the environment first: `gh secret set --env` fails if it doesn't exist. Creating an environment that already exists is harmless.

```sh
gh api -X PUT repos/zaychoer/petepete/environments/staging
fly tokens create deploy -a petepete-staging -x 8760h -n github-actions \
  | gh secret set FLY_API_TOKEN --env staging -R zaychoer/petepete
```

The pipe stores the token without printing it. A deploy token can only manage its one app; `-x 8760h` makes it expire after one year (Fly's default is 20 years).

Web UI alternative: Settings → Environments → `staging` (create it if missing) → Add environment secret, name `FLY_API_TOKEN`, value from `fly tokens create deploy -a petepete-staging -x 8760h -n github-actions`.

### 6. Check and deploy

```sh
gh api repos/zaychoer/petepete/environments --jq '.environments[].name'   # staging, production
gh secret list -R zaychoer/petepete --env staging                          # FLY_API_TOKEN
```

Then push to `main` or re-run the latest CI run from the Actions tab. For production, run "Deploy production" from the Actions tab.

## Gateway adapter

Everything provider-shaped (create a payment, verify and normalize webhooks, per-method fees, sub-account registration, withdrawals) sits behind the `Petepete.Payments.Gateway` behaviour. The adapter comes from `config :petepete, :gateway`: dev and test set `Petepete.Payments.Gateway.Fake` in `config/dev.exs` and `config/test.exs`.

In prod the app reads `PAYMENT_GATEWAY` in `api/config/runtime.exs` and **refuses to boot (and so does the release command `/app/bin/migrate`) when it is missing or unknown**. This is deliberate: money must never flow through a gateway nobody chose. The only adapter that exists today is `fake`, which moves no money. `fly.staging.toml` sets `PAYMENT_GATEWAY = "fake"`; `fly.production.toml` leaves it unset, so production cannot deploy until a real adapter exists. Choosing Xendit or Midtrans, obtaining sandbox credentials and completing KYC for a real sub-account are human steps that come first.

To add a real adapter (say `Petepete.Payments.Gateway.Xendit`):

1. Create `api/lib/petepete/payments/gateway/xendit.ex` with `@behaviour Petepete.Payments.Gateway` and implement every callback; the module doc of the behaviour lists the types. Return `{:error, :unsupported}` from `cancel_payment/1` and `{:managed, dashboard_url}` from `withdraw/2` if the provider has no such API. Adapters do no database writes.
2. Put the provider's per-method fee table in config (`config :petepete, Petepete.Payments.Gateway.Xendit, fees: %{...}`) and implement `fee_for/2` with `Petepete.Payments.Gateway.FeeTable`, so net to the host equals `amount_due`. Figures include PPN.
3. Add its name to the `case` on `PAYMENT_GATEWAY` in `api/config/runtime.exs`, map it to the module, and put credentials in `fly secrets set` plus matching `System.get_env` lines in the same file. Add each new variable to `.env.example`.
4. Set `PAYMENT_GATEWAY=<name>` in the matching `fly.*.toml`, then write adapter tests like `api/test/petepete/payments/gateway/fake_test.exs` (signed and forged webhooks, normalization, fees netting exactly `amount_due`) before deploying.

## Rotating a deploy token

Tokens created above expire after a year. To replace one:

```sh
fly tokens create deploy -a petepete-staging -x 8760h -n github-actions \
  | gh secret set FLY_API_TOKEN --env staging -R zaychoer/petepete
fly tokens list -a petepete-staging
fly tokens revoke <id-of-the-older-github-actions-token>
```

## Error monitoring (Sentry)

One Sentry project per layer, so every event carries the tag `layer` = `api`, `web` or `app` (set in code, not in Sentry). All three layers mask Indonesian phone numbers (`08…`, `62…`, `+62…`) as `[PHONE]` before sending, and the API also masks them in its logs. Each layer is **off** when its DSN is absent.

| Layer | Where the DSN goes | Notes |
| --- | --- | --- |
| API | Fly secret `SENTRY_DSN` | `SENTRY_ENVIRONMENT` is already set per app in `api/fly.*.toml` |
| WEB | Vercel project env var `NEXT_PUBLIC_SENTRY_DSN` (public by design) | Read at build time: redeploy after changing it |
| APP | `--dart-define=SENTRY_DSN=<dsn>` on `flutter run` / `flutter build` | Optional `--dart-define=SENTRY_ENVIRONMENT=staging` |

```sh
fly secrets set -a petepete-staging SENTRY_DSN=<api-project-dsn>
```

Send a test event from each layer and check in Sentry that the issue has the right `layer` tag and that the phone number in the message shows as `[PHONE]`:

```sh
# API: run inside the app (the message contains a phone number on purpose)
fly ssh console -a petepete-staging -C '/app/bin/petepete rpc "Sentry.capture_message(~s[Sentry test event (api) 081234567890])"'

# WEB: set SENTRY_TEST_TOKEN in Vercel (any random string), redeploy, then
curl "https://<web-host>/api/sentry-test?token=<SENTRY_TEST_TOKEN>"
# remove SENTRY_TEST_TOKEN again afterwards: the route answers 404 without it

# APP: starts the app and sends one test error
flutter run --dart-define=SENTRY_DSN=<app-project-dsn> --dart-define=SENTRY_TEST_EVENT=true
```

## Daily database backup

Fly Managed Postgres keeps its own automatic backups; the workflow `.github/workflows/backup.yml` additionally takes a **full backup of every cluster each day at 02:00 WIB** (`flyctl mpg backup create <cluster-id> --type full`) so the schedule is under our control and visible in the Actions tab. It runs for `staging` and `production`.

One-time setup per environment (`staging`, `production`):

```sh
fly mpg list                                    # note the cluster id
gh variable set MPG_CLUSTER_ID --env staging -R zaychoer/petepete --body <cluster-id>
fly tokens create org -o <fly-org-slug> -x 8760h -n github-backup \
  | gh secret set FLY_BACKUP_TOKEN --env staging -R zaychoer/petepete
```

Then run the workflow once by hand (Actions tab → "Backup database" → Run workflow) and confirm the backup shows up:

```sh
fly mpg backup list <cluster-id>          # last 24 hours; add --all for everything
```

The token is an organization token because `fly mpg` commands act on the cluster, not on one app; rotate it yearly like the deploy tokens (see "Rotating a deploy token", same steps with `fly tokens create org`). If the workflow fails with "must be set", the variable or secret above is missing from that environment.

### Restoring

A restore never touches the source cluster: it creates a **new** cluster, so you can inspect it before switching anything over.

```sh
fly mpg backup list <cluster-id>                                        # pick a backup id
fly mpg restore <cluster-id> --backup-id <backup-id> --name petepete-staging-db-restore
# or to a point in time (RFC3339, must be inside the cluster's recovery window):
fly mpg restore <cluster-id> --pitr-time 2026-10-06T12:00:00Z --name petepete-staging-db-restore
```

Check the restored data with `fly mpg connect <new-cluster-id>`, then either point the app at it (`fly mpg attach <new-cluster-id> -a petepete-staging`) or copy what you need back. Destroy the test cluster afterwards (`fly mpg destroy <new-cluster-id>`); restored clusters are billed separately.

Do this restore test once on `staging` before launch and note the date here: PP-FND-04 is not done until a person has restored a backup and read the data back.

## Troubleshooting

**`failed to fetch public key: HTTP 404: Not Found (…/environments/<name>/secrets/public-key)`**
The GitHub environment `<name>` does not exist, often because of a typo when creating it. List environments with `gh api repos/zaychoer/petepete/environments --jq '.environments[].name'`, create the correct one (step 5), and delete a misspelled one with `gh api -X DELETE repos/zaychoer/petepete/environments/<misspelled>`. Because `fly tokens create` ran before the GitHub step failed, a valid token now exists that is stored nowhere: rerun step 5, then revoke the older `github-actions` token as in "Rotating a deploy token".

**`deploy-staging` fails with "FLY_API_TOKEN is not set in the staging environment"**
Step 5 has not been done for `staging`, or the secret was added as a repository secret instead of an environment secret.

**Deploy fails after the token check**
The app is missing its database (step 3), `SECRET_KEY_BASE` (step 4) or the OTP secrets (step 4b). `fly secrets list -a petepete-staging` should show `DATABASE_URL`, `SECRET_KEY_BASE`, `OTP_HMAC_KEY` and `OTP_SENDER`.
