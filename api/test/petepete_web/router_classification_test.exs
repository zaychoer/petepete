defmodule PetepeteWeb.RouterClassificationTest do
  @moduledoc """
  Every write route under `/api` is classified here, so a new route cannot ship without a
  decision about who may call it. Classes:

    * `:host_money` - a host changes money. Needs a row in `PetepeteWeb.HostActionsTable`
      (the contract test then proves audit, idempotency, authorization and rejection).
    * `:host_other` - host-only, no money (roster, events, session drafts, claims).
    * `:member` - any member of the group.
    * `:self` - acts on the caller's own account or membership.
    * `:public` - no login (auth, pay link, webhook).

  An unclassified route fails the test: classify it below and, for `:host_money`, add the
  action to `PetepeteWeb.HostActionsTable`.

  Every route (any verb) is also classified by what a client may rely on (ADR-0004, the wire
  contract, `contract/README.md`):

    * `:client` - the app or the pay page calls it and reads the JSON body. Needs recorded
      samples in `contract/manifest.json` (written by `Petepete.Contract.check!/3` in the
      route's controller test).
    * `:no_body` - a client calls it but the success response has no body (204); nothing to
      record.
    * `:server_only` - no client reads its response (provider webhook, beta metrics).

  `@pending_samples` is the temporary list of `:client` routes whose samples are not recorded
  yet. It shrinks as areas land; the test fails when a listed route is recorded, so it must
  end up empty.

  The contract test's "missing Idempotency-Key is 422" case already proves the
  `PetepeteWeb.Plugs.IdempotencyKey` plug on every table row. Phoenix compiles a controller's
  plugs into a private function and exposes no list to inspect, so the plug is not asserted
  here separately: coverage by the table is the guarantee.
  """
  use ExUnit.Case, async: true

  alias PetepeteWeb.HostActionsTable

  @classes [:host_money, :host_other, :member, :self, :public]
  @wire_classes [:client, :no_body, :server_only]

  @classification %{
    {:post, "/api/auth/otp"} => :public,
    {:post, "/api/auth/verify"} => :public,
    {:post, "/api/auth/refresh"} => :public,
    {:post, "/api/auth/logout"} => :public,
    {:post, "/api/pay/:token/payment"} => :public,
    {:post, "/api/webhooks/:provider"} => :public,
    {:post, "/api/invites/:token/join"} => :self,
    {:post, "/api/groups"} => :self,
    {:post, "/api/groups/:group_id/invite/reset"} => :host_other,
    {:post, "/api/groups/:group_id/guests"} => :host_other,
    {:post, "/api/groups/:group_id/events"} => :host_other,
    {:post, "/api/members/:id/claim"} => :self,
    {:post, "/api/members/:id/claim/approve"} => :host_other,
    {:post, "/api/members/:id/claim/reject"} => :host_other,
    {:post, "/api/groups/:group_id/payout-account"} => :host_money,
    {:post, "/api/groups/:group_id/withdrawals"} => :host_money,
    {:post, "/api/groups/:group_id/settlements"} => :host_money,
    {:post, "/api/groups/:group_id/kas-spends"} => :host_money,
    {:post, "/api/txns/:id/correction"} => :host_money,
    {:put, "/api/sessions/:id/costs/:cid"} => :host_other,
    {:delete, "/api/sessions/:id/costs/:cid"} => :host_other,
    {:put, "/api/sessions/:id/attendance"} => :host_other,
    {:post, "/api/sessions/:id/issue"} => :host_money,
    {:post, "/api/sessions/:id/void"} => :host_money,
    {:post, "/api/bills/:id/cash"} => :host_money,
    {:post, "/api/bills/:id/cash/cancel"} => :host_money,
    {:patch, "/api/me"} => :self,
    {:delete, "/api/me"} => :self
  }

  @wire %{
    "POST /api/auth/otp" => :client,
    "POST /api/auth/verify" => :client,
    "POST /api/auth/refresh" => :client,
    "POST /api/auth/logout" => :client,
    "GET /api/pay/:token" => :client,
    "POST /api/pay/:token/payment" => :client,
    "POST /api/webhooks/:provider" => :server_only,
    "GET /api/admin/metrics" => :server_only,
    "GET /api/invites/:token" => :client,
    "POST /api/invites/:token/join" => :client,
    "GET /api/groups" => :client,
    "POST /api/groups" => :client,
    "GET /api/groups/:group_id" => :client,
    "POST /api/groups/:group_id/invite/reset" => :client,
    "POST /api/groups/:group_id/guests" => :client,
    "POST /api/groups/:group_id/events" => :client,
    "GET /api/groups/:group_id/home" => :client,
    "POST /api/members/:id/claim" => :client,
    "POST /api/members/:id/claim/approve" => :client,
    "POST /api/members/:id/claim/reject" => :client,
    "POST /api/groups/:group_id/payout-account" => :client,
    "GET /api/groups/:group_id/payout-account/balance" => :client,
    "GET /api/groups/:group_id/withdrawals" => :client,
    "POST /api/groups/:group_id/withdrawals" => :client,
    "POST /api/groups/:group_id/settlements" => :client,
    "POST /api/groups/:group_id/kas-spends" => :client,
    "GET /api/groups/:group_id/balances" => :client,
    "GET /api/groups/:group_id/txns" => :client,
    "POST /api/txns/:id/correction" => :client,
    "GET /api/sessions/:id" => :client,
    "PUT /api/sessions/:id/costs/:cid" => :client,
    "DELETE /api/sessions/:id/costs/:cid" => :no_body,
    "PUT /api/sessions/:id/attendance" => :client,
    "GET /api/sessions/:id/preview" => :client,
    "POST /api/sessions/:id/issue" => :client,
    "GET /api/sessions/:id/share/bills" => :client,
    "GET /api/sessions/:id/share/reminder" => :client,
    "GET /api/sessions/:id/share/summary" => :client,
    "POST /api/sessions/:id/void" => :client,
    "POST /api/bills/:id/cash" => :client,
    "POST /api/bills/:id/cash/cancel" => :client,
    "GET /api/me" => :client,
    "PATCH /api/me" => :client,
    "DELETE /api/me" => :client
  }

  # `:client` routes with no recorded sample yet (route keys as in contract/manifest.json).
  @pending_samples [
    "POST /api/pay/:token/payment",
    "POST /api/groups/:group_id/payout-account",
    "GET /api/groups/:group_id/payout-account/balance",
    "GET /api/groups/:group_id/withdrawals",
    "POST /api/groups/:group_id/withdrawals",
    "POST /api/groups/:group_id/settlements",
    "POST /api/groups/:group_id/kas-spends",
    "GET /api/groups/:group_id/balances",
    "GET /api/groups/:group_id/txns",
    "POST /api/txns/:id/correction",
    "GET /api/sessions/:id",
    "PUT /api/sessions/:id/costs/:cid",
    "PUT /api/sessions/:id/attendance",
    "GET /api/sessions/:id/preview",
    "POST /api/sessions/:id/issue",
    "GET /api/sessions/:id/share/bills",
    "GET /api/sessions/:id/share/reminder",
    "GET /api/sessions/:id/share/summary",
    "POST /api/sessions/:id/void",
    "POST /api/bills/:id/cash",
    "POST /api/bills/:id/cash/cancel"
  ]

  defp all_routes do
    for %{verb: verb, path: "/api" <> _ = path} <- PetepeteWeb.Router.__routes__(),
        do: "#{verb |> Atom.to_string() |> String.upcase()} #{path}"
  end

  defp write_routes do
    for %{verb: verb, path: "/api" <> _ = path} <- PetepeteWeb.Router.__routes__(),
        verb != :get,
        do: {verb, path}
  end

  test "every write route under /api is classified" do
    unclassified = write_routes() -- Map.keys(@classification)

    assert unclassified == [],
           """
           Unclassified routes: #{inspect(unclassified)}.
           Add each to @classification in #{__ENV__.file} as one of #{inspect(@classes)}; \
           for :host_money also add the action to PetepeteWeb.HostActionsTable.
           """
  end

  test "the classification names only routes that exist, with a known class" do
    assert Map.keys(@classification) -- write_routes() == []
    assert Enum.uniq(Map.values(@classification)) -- @classes == []
  end

  test "every :host_money route has a row in the host actions contract table" do
    money = for {route, :host_money} <- @classification, do: route
    covered = for row <- HostActionsTable.rows(), do: row.route

    assert money -- covered == [],
           "Host money routes without a HostActionsTable row: #{inspect(money -- covered)}"

    assert covered -- money == [],
           "HostActionsTable rows for routes not classified :host_money: #{inspect(covered -- money)}"
  end

  test "every route under /api has a wire class" do
    unclassified = all_routes() -- Map.keys(@wire)

    assert unclassified == [],
           """
           Routes without a wire class: #{inspect(unclassified)}.
           Add each to @wire in #{__ENV__.file} as one of #{inspect(@wire_classes)}.
           """
  end

  test "the wire classification names only routes that exist, with a known class" do
    assert Map.keys(@wire) -- all_routes() == []
    assert Enum.uniq(Map.values(@wire)) -- @wire_classes == []
  end

  test "the contract has samples for every :client route, and nothing else" do
    client = for {route, :client} <- @wire, do: route

    problems = Petepete.Contract.audit(client, @pending_samples, Petepete.Contract.dir())

    assert problems == [], "Contract coverage problems:\n  " <> Enum.join(problems, "\n  ")
  end
end
