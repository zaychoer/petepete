defmodule PetepeteWeb.WithdrawalControllerTest do
  # Not async: the fake gateway's balance and withdraw mode are application config.
  use PetepeteWeb.ConnCase, async: false

  import Ecto.Query
  import Petepete.Fixtures

  alias Petepete.Ledger.{AuditLog, Entry, Txn}
  alias Petepete.Payments.Gateway.Fake
  alias Petepete.Payments.Withdrawal
  alias Petepete.Repo

  setup %{conn: conn} do
    original = Application.fetch_env!(:petepete, Fake)
    Application.put_env(:petepete, Fake, Keyword.put(original, :balance, 500_000))
    on_exit(fn -> Application.put_env(:petepete, Fake, original) end)

    g = group_fixture()
    {owner_conn, owner_member} = login(conn, g, "host")
    {other_host, _} = login(conn, g, "host")
    {plain, _} = login(conn, g, "member")
    {outsider, _} = login(conn, group_fixture(), "host")
    account = payout_account_fixture(g, owner_member, status: "active")

    %{
      g: g,
      account: account,
      owner: owner_conn,
      other_host: other_host,
      plain: plain,
      outsider: outsider
    }
  end

  defp login(conn, group, role) do
    user = user_fixture(%{phone: valid_phone()})
    member = member_fixture(group, role: role, user: user)
    {bearer_conn(conn, user), member}
  end

  defp withdraw(conn, group, amount, key \\ nil) do
    conn
    |> put_req_header("idempotency-key", key || "w-#{uniq()}")
    |> post(~p"/api/groups/#{group.id}/withdrawals", %{amount: amount})
  end

  defp ledger_rows, do: {Repo.aggregate(Txn, :count), Repo.aggregate(Entry, :count)}

  test "the owner withdraws, history lists it, the audit row is written, the ledger is untouched",
       ctx do
    before = ledger_rows()

    assert %{"withdrawal_id" => id, "status" => "submitted", "managed_url" => nil} =
             ctx.owner |> withdraw(ctx.g, 200_000) |> json_response(201)

    assert %Withdrawal{amount: 200_000, provider_ref: "fake-withdrawal-" <> _} =
             Repo.get!(Withdrawal, id)

    assert [%{subject_type: "withdrawal", subject_id: ^id, metadata: %{"amount" => 200_000}}] =
             Repo.all(from a in AuditLog, where: a.action == "withdrawal.request")

    assert %{"withdrawals" => [%{"id" => ^id, "amount" => 200_000, "status_label" => label}]} =
             ctx.owner |> get(~p"/api/groups/#{ctx.g.id}/withdrawals") |> json_response(200)

    assert is_binary(label)
    assert ledger_rows() == before
  end

  test "the same Idempotency-Key withdraws once", ctx do
    assert %{"replayed" => false, "withdrawal_id" => id} =
             ctx.owner |> withdraw(ctx.g, 100_000, "same") |> json_response(201)

    assert %{"replayed" => true, "withdrawal_id" => ^id} =
             ctx.owner |> withdraw(ctx.g, 100_000, "same") |> json_response(200)

    assert %{"error" => "idempotency_key_conflict"} =
             ctx.owner |> withdraw(ctx.g, 150_000, "same") |> json_response(422)

    assert Repo.aggregate(Withdrawal, :count) == 1

    assert Repo.aggregate(from(a in AuditLog, where: a.action == "withdrawal.request"), :count) ==
             1
  end

  test "a withdrawal needs the Idempotency-Key header", ctx do
    conn = post(ctx.owner, ~p"/api/groups/#{ctx.g.id}/withdrawals", %{amount: 1_000})
    assert %{"error" => "idempotency_key_required"} = json_response(conn, 422)
  end

  test "more than the balance is rejected and nothing is recorded", ctx do
    assert %{"error" => "insufficient_balance"} =
             ctx.owner |> withdraw(ctx.g, 500_001) |> json_response(422)

    assert %{"status" => "submitted"} =
             ctx.owner |> withdraw(ctx.g, 500_000) |> json_response(201)

    assert Repo.aggregate(Withdrawal, :count) == 1
  end

  test "amounts must be positive whole rupiah", ctx do
    assert %{"error" => "amount_not_positive"} =
             ctx.owner |> withdraw(ctx.g, 0) |> json_response(422)

    assert %{"error" => "invalid_params"} =
             ctx.owner |> withdraw(ctx.g, "100") |> json_response(422)

    assert Repo.aggregate(Withdrawal, :count) == 0
  end

  test "a managed sub-account answers with the dashboard url", ctx do
    original = Application.fetch_env!(:petepete, Fake)

    Application.put_env(
      :petepete,
      Fake,
      Keyword.put(original, :withdraw, {:managed, "https://dashboard.fake.test/withdraw"})
    )

    on_exit(fn -> Application.put_env(:petepete, Fake, original) end)

    assert %{"status" => "managed", "managed_url" => "https://dashboard.fake.test/withdraw"} =
             ctx.owner |> withdraw(ctx.g, 100_000) |> json_response(201)
  end

  test "only the payout account owner may withdraw", ctx do
    assert %{"error" => "forbidden"} =
             ctx.other_host |> withdraw(ctx.g, 100_000) |> json_response(403)

    assert %{"error" => "forbidden"} = ctx.plain |> withdraw(ctx.g, 100_000) |> json_response(403)

    assert %{"error" => "not_found"} =
             ctx.outsider |> withdraw(ctx.g, 100_000) |> json_response(404)

    assert Repo.aggregate(Withdrawal, :count) == 0
  end

  test "an account still in KYC cannot withdraw", ctx do
    ctx.account |> Ecto.Changeset.change(status: "pending_kyc") |> Repo.update!()

    assert %{"error" => "payout_account_not_active"} =
             ctx.owner |> withdraw(ctx.g, 100_000) |> json_response(422)
  end

  test "a group without a payout account cannot withdraw", %{conn: conn} do
    g = group_fixture()
    {host, _} = login(conn, g, "host")

    assert %{"error" => "no_payout_account"} = host |> withdraw(g, 1_000) |> json_response(422)
  end

  test "withdrawals of another group are never visible", ctx do
    withdraw(ctx.owner, ctx.g, 100_000)

    assert ctx.outsider |> get(~p"/api/groups/#{ctx.g.id}/withdrawals") |> response(404)

    assert ctx.outsider
           |> get(~p"/api/groups/#{ctx.g.id}/payout-account/balance")
           |> response(404)

    assert ctx.plain |> get(~p"/api/groups/#{ctx.g.id}/withdrawals") |> response(403)
  end

  describe "GET payout-account/balance" do
    test "the owner sees the balance and may withdraw", ctx do
      assert %{
               "balance" => 500_000,
               "status" => "active",
               "owner" => true,
               "can_withdraw" => true
             } =
               ctx.owner
               |> get(~p"/api/groups/#{ctx.g.id}/payout-account/balance")
               |> json_response(200)
    end

    test "another host sees the balance but cannot withdraw", ctx do
      assert %{"balance" => 500_000, "owner" => false, "can_withdraw" => false} =
               ctx.other_host
               |> get(~p"/api/groups/#{ctx.g.id}/payout-account/balance")
               |> json_response(200)
    end
  end
end
