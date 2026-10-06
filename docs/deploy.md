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

## Rotating a deploy token

Tokens created above expire after a year. To replace one:

```sh
fly tokens create deploy -a petepete-staging -x 8760h -n github-actions \
  | gh secret set FLY_API_TOKEN --env staging -R zaychoer/petepete
fly tokens list -a petepete-staging
fly tokens revoke <id-of-the-older-github-actions-token>
```

## Troubleshooting

**`failed to fetch public key: HTTP 404: Not Found (…/environments/<name>/secrets/public-key)`**
The GitHub environment `<name>` does not exist, often because of a typo when creating it. List environments with `gh api repos/zaychoer/petepete/environments --jq '.environments[].name'`, create the correct one (step 5), and delete a misspelled one with `gh api -X DELETE repos/zaychoer/petepete/environments/<misspelled>`. Because `fly tokens create` ran before the GitHub step failed, a valid token now exists that is stored nowhere: rerun step 5, then revoke the older `github-actions` token as in "Rotating a deploy token".

**`deploy-staging` fails with "FLY_API_TOKEN is not set in the staging environment"**
Step 5 has not been done for `staging`, or the secret was added as a repository secret instead of an environment secret.

**Deploy fails after the token check**
The app is missing its database (step 3), `SECRET_KEY_BASE` (step 4) or the OTP secrets (step 4b). `fly secrets list -a petepete-staging` should show `DATABASE_URL`, `SECRET_KEY_BASE`, `OTP_HMAC_KEY` and `OTP_SENDER`.
