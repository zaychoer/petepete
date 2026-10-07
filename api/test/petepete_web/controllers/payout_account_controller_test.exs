defmodule PetepeteWeb.PayoutAccountControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Petepete.Fixtures
  import Ecto.Query

  alias Petepete.Groups.PayoutAccount
  alias Petepete.Ledger.AuditLog
  alias Petepete.Repo

  @bank %{bank_name: "BCA", account_number: "1234567890", account_holder_name: "Budi"}

  setup %{conn: conn} do
    g = group_fixture()
    host = login_user(conn, g, "host")
    plain = login_user(conn, g, "member")
    outsider = login_user(conn, group_fixture(), "host")
    %{g: g, host: host, plain: plain, outsider: outsider}
  end

  defp login_user(conn, group, role) do
    user = user_fixture(phone: valid_phone())
    member_fixture(group, role: role, user: user)
    bearer_conn(conn, user)
  end

  test "host registers the payout account and the audit row is written", ctx do
    conn = post(ctx.host, ~p"/api/groups/#{ctx.g.id}/payout-account", @bank)

    assert %{"payout_account_id" => id, "status" => "pending_kyc"} = json_response(conn, 201)
    assert %PayoutAccount{account_last4: "7890"} = Repo.get!(PayoutAccount, id)

    assert [%{subject_type: "payout_account", subject_id: ^id, metadata: meta}] =
             Repo.all(from a in AuditLog, where: a.action == "payout_account.register")

    refute inspect(meta) =~ "1234567890"
  end

  test "bad bank data is 422 and leaves nothing behind", ctx do
    conn =
      post(ctx.host, ~p"/api/groups/#{ctx.g.id}/payout-account", %{@bank | account_number: "12"})

    assert %{"error" => "invalid_params", "details" => %{"account_number" => _}} =
             json_response(conn, 422)

    assert Repo.aggregate(PayoutAccount, :count) == 0
    assert Repo.aggregate(AuditLog, :count) == 0
  end

  test "only the group's host may register", ctx do
    path = ~p"/api/groups/#{ctx.g.id}/payout-account"
    assert ctx.plain |> post(path, @bank) |> json_response(403)
    assert ctx.outsider |> post(path, @bank) |> json_response(404)
    assert Repo.aggregate(PayoutAccount, :count) == 0
  end
end
