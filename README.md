# Petepete

Group expense billing for recurring sports sessions: the host enters costs and attendance, Petepete splits the bill, participants pay through a no-login web page, and a double-entry ledger tracks who owes the group.

Spec and tickets: [`docs/spec.md`](docs/spec.md).

## Layout

| Path | Stack | Role |
| --- | --- | --- |
| `api/` | Elixir/Phoenix JSON API, Ecto, PostgreSQL | Contexts `Accounts`, `Groups`, `Sessions`, `Billing`, `Ledger`, `Payments`; webhooks |
| `web/` | Next.js (Vercel) | Participant pay page and web join |
| `app/` | Flutter (Android first) | Host app |
| `bin/dev` | bash | Local one-command start |

## Requirements

- Erlang/Elixir and Node versions from `.tool-versions` (asdf)
- pnpm
- Docker (local Postgres on port 55432, to avoid clashing with other local Postgres instances)
- Flutter 3.35.3 (same version CI pins)

## Run locally

```sh
bin/dev
```

Creates `.env` if missing, starts Postgres in Docker, sets up the database, and runs the API on http://localhost:4000 and the pay page on http://localhost:3000. If `flutter` is on `PATH` (or `FLUTTER=/path/to/flutter` is set) and an Android device or emulator is connected, it also runs the host app on it; otherwise it prints why it skipped. Stop with Ctrl-C; `docker compose down` stops Postgres.

## Secrets

Local secrets live in `.env` at the repo root (gitignored). `.env.example` is the committed template and lists every variable the code reads; add new variables there in the same change that starts reading them.

- `bin/dev` creates `.env` on first run with generated values and loads it before starting anything.
- Running `mix` in `api/` directly needs the same variables: with [direnv](https://direnv.net) hooked into your shell, run `direnv allow` once and `.envrc` loads `.env` automatically; otherwise `set -a; . ./.env; set +a` first.
- Production secrets are set with `fly secrets set` and never stored in files. The Flutter app and the Next.js pay page ship to clients, so they must not hold secrets.

## Tests

```sh
(cd api && mix test)
(cd web && pnpm lint && pnpm build)
(cd app && flutter analyze)
```

The Flutter app has no tests yet; add `flutter test` here and in CI with the first one.

CI runs the same commands on every push to `main` and on pull requests (`.github/workflows/ci.yml`), and also builds the API Docker image (`api/Dockerfile`).

## Deploy

The API runs on Fly.io in Singapore (`sin`): `petepete-staging` (`api/fly.staging.toml`) and `petepete-production` (`api/fly.production.toml`). Both run `/app/bin/migrate` as the release command, so migrations apply before new machines start.

- **Staging:** every push to `main` deploys after all CI jobs pass (`deploy-staging` job).
- **Production:** run the "Deploy production" workflow manually from the Actions tab on `main`.

One-time provisioning (needs a Fly account; run from `api/`):

```sh
fly auth login
for env in staging production; do
  fly apps create "petepete-$env"
  fly mpg create --name "petepete-$env-db" --region sin --pg-major-version 17
  fly mpg attach <cluster-id-printed-above> -a "petepete-$env"   # sets DATABASE_URL
  fly secrets set -a "petepete-$env" --stage SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')"
  fly tokens create deploy -a "petepete-$env"                    # copy the token
done
```

Then in GitHub (Settings → Environments) create `staging` and `production`, each with a `FLY_API_TOKEN` secret holding that app's deploy token. Until `staging` has the secret, the `deploy-staging` job fails on `main` with a message pointing here. Fly app names are global; if one is taken, change `app` and `PHX_HOST` in the matching `fly.*.toml`.
