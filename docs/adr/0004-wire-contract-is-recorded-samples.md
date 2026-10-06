---
status: accepted
---

# The wire contract is recorded samples, not OpenAPI or generated types

The API's own controller tests record one real response per client-facing route and per error code into `contract/samples/`; the same tests compare later responses with the committed sample by shape (same keys, same JSON types, free values), and the app's fake servers and the web tests load those files instead of hand-typed JSON, with per-test overrides that must keep the sample's JSON types. The server owns all user-facing text: every status field carries its Indonesian `status_label` and every error carries a `message`, so clients keep only icon, tone and a network-failure fallback; rupiah formatting stays in Dart, TypeScript and Elixir but all three run one shared table of cases. We chose this because the login crash (Dart read `user.id` as a String while the API sends an integer) passed 150 app tests that used hand-typed fakes, and status maps and error messages were re-typed in four places.

## Considered Options

- **OpenAPI / JSON Schema with generated Dart and TS types**: strongest guarantee, but a spec and two generators to maintain for 44 routes owned by one developer, and Phoenix has no zero-cost source of truth for it.
- **Generated types without recorded samples**: no good generator for Phoenix JSON, and it would not make the fakes honest.
- **Server-formatted rupiah strings**: rejected because the app computes local estimates and sums.

## Consequences

- An API shape change fails the `api` job until the sample is re-recorded (`CONTRACT_RECORD=1`), and the `app` and `web` jobs then fail until clients follow, all in the same PR.
- Coverage is only as wide as the recorded routes: the router classification test requires every client-facing route to have a sample and every error code a client can see to have one.
- Samples can go stale only if a controller test stops exercising the route; the coverage test is the guard.
