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

Starts Postgres in Docker, sets up the database, and runs the API on http://localhost:4000 and the pay page on http://localhost:3000. Stop with Ctrl-C; `docker compose down` stops Postgres.

The host app runs separately against a device or emulator:

```sh
cd app && flutter run
```

## Tests

```sh
(cd api && mix test)
(cd web && pnpm lint && pnpm build)
(cd app && flutter analyze && flutter test)
```

CI runs the same commands on every push to `main` and on pull requests (`.github/workflows/ci.yml`).
