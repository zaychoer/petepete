# Petepete

Group expense billing for recurring sports sessions: the host enters costs and attendance, Petepete splits the bill, participants pay through a no-login web page, and a double-entry ledger tracks who owes the group.

Spec and tickets: [`docs/spec.md`](docs/spec.md).

## Layout

| Path | Stack | Role |
| --- | --- | --- |
| `api/` | Elixir/Phoenix JSON API, Ecto, PostgreSQL | Contexts `Accounts`, `Groups`, `Sessions`, `Billing`, `Ledger`, `Payments`; webhooks |
| `web/` | TanStack Start (React, Vite, Nitro) | Participant pay page and web join |
| `app/` | Flutter (Android first) | Host app |
| `bin/dev` | bash | Local one-command start |

## Requirements

- Erlang/Elixir and Node versions from `.tool-versions` (asdf)
- pnpm
- Docker (local Postgres on port 55432, to avoid clashing with other local Postgres instances)
- Flutter 3.47.6 (same version CI pins, `.github/workflows/ci.yml`)

## Run locally

```sh
bin/dev
```

Creates `.env` if missing, starts Postgres in Docker, sets up the database, and runs the API on http://localhost:4000 and the pay page on http://localhost:3000. If `flutter` is on `PATH` (or `FLUTTER=/path/to/flutter` is set) and an Android device or emulator is connected, it also runs the host app on it; otherwise it prints why it skipped. Stop with Ctrl-C; `docker compose down` stops Postgres.

## Secrets

Local secrets live in `.env` at the repo root (gitignored). `.env.example` is the committed template and lists every variable the code reads; add new variables there in the same change that starts reading them.

- `bin/dev` creates `.env` on first run with generated values and loads it before starting anything.
- Running `mix` in `api/` directly needs the same variables: with [direnv](https://direnv.net) hooked into your shell, run `direnv allow` once and `.envrc` loads `.env` automatically; otherwise `set -a; . ./.env; set +a` first.
- Production secrets are set with `fly secrets set` and never stored in files. The Flutter app and the web pay page ship to clients, so they must not hold secrets.

## Tests

```sh
(cd api && mix precommit)                   # warnings as errors, unlock unused deps, format, mix test
(cd web && pnpm lint && pnpm test && pnpm build)
(cd app && flutter analyze && flutter test)
```

`mix test` alone is enough while iterating. API tests need the local Postgres (`bin/dev` or `docker compose up -d`). The web tests (`pnpm test`, Vitest) cover the pay page state machine and helpers; the app tests (`flutter test`) are widget and unit tests against fake API servers, not a real device.

CI runs the same checks (`mix format --check-formatted` instead of rewriting files) on every push to `main` and on pull requests (`.github/workflows/ci.yml`), and also builds the API Docker image (`api/Dockerfile`).

## Deploy

The API runs on Fly.io in Singapore (`sin`): `petepete-staging` (`api/fly.staging.toml`) and `petepete-production` (`api/fly.production.toml`). Both run `/app/bin/migrate` as the release command, so migrations apply before new machines start.

- **Staging:** every push to `main` deploys after all CI jobs pass (`deploy-staging` job).
- **Production:** run the "Deploy production" workflow manually from the Actions tab on `main`.

First-time setup (Fly apps, databases, secrets, GitHub deploy tokens), token rotation, and troubleshooting: [`docs/deploy.md`](docs/deploy.md).
