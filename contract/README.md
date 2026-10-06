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

## Used by the clients

Fakes and tests load `samples/` and `manifest.json` instead of typing payloads. An override may
change values but not a value's JSON type.

## App tests

`app/test/support/sample.dart` loads samples for Flutter tests (found by walking up from the
working directory, so it works under `flutter test` from `app/`):

```dart
final page = Sample.load('pay_page.unpaid')              // contract/samples/pay_page.unpaid.json
    .patch({'amount_due': 50000, 'attempt': {'status': 'pending'}})
    .withItems('lines', [{'label': 'Konsumsi'}, {}]);
page.json;      // Map<String, dynamic>, a fresh deep copy
page.encode();  // JSON string for a fake HTTP response

Sample.error('idempotency_key_required').json   // contract/samples/errors/<code>.json
```

`patch` takes field names or dotted paths (`'lines.0.amount'`); a nested map merges into the
object. It throws `SampleOverrideError` when a value changes the sample's JSON type (int, double,
string, bool, list, map), adds or drops an object key, or names a path the sample does not have;
`null` on either side is free. `withItems(path, [...])` builds a list from the sample's first
element, one element per entry with its own overrides. `contract/rupiah.json` runs in
`app/test/contract/rupiah_contract_test.dart`.
