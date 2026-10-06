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

  The contract test's "missing Idempotency-Key is 422" case already proves the
  `PetepeteWeb.Plugs.IdempotencyKey` plug on every table row. Phoenix compiles a controller's
  plugs into a private function and exposes no list to inspect, so the plug is not asserted
  here separately: coverage by the table is the guarantee.
  """
  use ExUnit.Case, async: true

  alias PetepeteWeb.HostActionsTable

  @classes [:host_money, :host_other, :member, :self, :public]

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
end
