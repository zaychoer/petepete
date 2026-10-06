# Wire contract

What the API sends and what the app and web client rely on, as recorded real responses
([ADR-0004](../docs/adr/0004-wire-contract-is-recorded-samples.md)). There is no hand-written
schema: the samples are the contract.

- `samples/<resource>.<variant>.json`: a real, pretty-printed response body of one client-facing
  route, e.g. `pay_page.unpaid.json`. Use non-empty arrays so the element shape is recorded.
- `samples/errors/<code>.json`: one per error `code` a client can see:
  `{"error": code, "message": "...", ...}`. `message` is required (the server owns user-facing text).
- `manifest.json`: `{"routes": {"GET /api/pay/:token": ["pay_page.unpaid", ...]}, "errors": ["not_found", ...]}`
  with sorted keys. Server-only routes (webhook, metrics) are not listed.
- `rupiah.json`: `[{"amount": 1245000, "text": "Rp1.245.000"}, ...]`, run by the Elixir, Dart and
  TypeScript test suites.

## Checked and recorded by the API tests

A controller test passes the response it already asserts on to `Petepete.Contract.check!/3`
(`api/test/support/contract.ex`):

```elixir
conn = get(conn, ~p"/api/pay/#{bill.pay_token}")
Contract.check!("pay_page.unpaid", conn)          # route derived from the conn
Contract.check!("errors/not_found", conn)         # error samples need "error" and "message"
```

The check compares shape only: same object keys, same JSON type per value (an integer is not a
float), arrays by the sample's first element, `null` on either side matches anything. Values,
ids, timestamps and tokens are free. A mismatch lists the JSON path of each difference.

When an API change is intended, re-record and commit the changed samples, then follow with the
app and web in the same PR:

```sh
cd api && CONTRACT_RECORD=1 mix test test/path/to_controller_test.exs
```

Recording rewrites the sample and adds it to `manifest.json`. A new route needs a
classification in `api/test/petepete_web/router_classification_test.exs`; that test fails on
an unrecorded `:client` route, a manifest entry without its file, and a sample file the
manifest does not list.

A route whose success response has no body (`DELETE /api/sessions/:id/costs/:cid`, 204) is
classified `:no_body` in the classification test: it needs no sample and is not in the
manifest. Its error responses still have `errors/<code>` samples.

## Used by the clients

Fakes and tests load `samples/` and `manifest.json` instead of typing payloads. An override may
change values but not a value's JSON type.
