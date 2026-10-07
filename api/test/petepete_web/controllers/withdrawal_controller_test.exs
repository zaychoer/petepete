defmodule PetepeteWeb.WithdrawalControllerTest do
  # Not async: the fake gateway's balance and withdraw mode are application config.
  use PetepeteWeb.ConnCase, async: false

  import Ecto.Query
  import Petepete.Fixtures

  alias Petepete.Contract
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

    conn = withdraw(ctx.owner, ctx.g, 200_000)
    Contract.check!("withdrawal.submitted", conn)

    assert %{
             "withdrawal_id" => id,
             "status" => "submitted",
             "status_label" => "Penarikan diajukan",
             "managed_url" => nil
           } = json_response(conn, 201)

    assert %Withdrawal{amount: 200_000, provider_ref: "fake-withdrawal-" <> _} =
             Repo.get!(Withdrawal, id)

    assert [%{subject_type: "withdrawal", subject_id: ^id, metadata: %{"amount" => 200_000}}] =
             Repo.all(from a in AuditLog, where: a.action == "withdrawal.request")

    assert %{"withdrawals" => [%{"id" => ^id, "amount" => 200_000, "status_label" => label}]} =
             ctx.owner |> get(~p"/api/groups/#{ctx.g.id}/withdrawals") |> json_response(200)

    assert label == "Penarikan diajukan"
    assert ledger_rows() == before
  end

  test "the same Idempotency-Key withdraws once", ctx do
    assert %{"replayed" => false, "withdrawal_id" => id} =
             ctx.owner |> withdraw(ctx.g, 100_000, "same") |> json_response(201)

    assert %{"replayed" => true, "withdrawal_id" => ^id} =
             ctx.owner |> withdraw(ctx.g, 100_000, "same") |> json_response(200)

    conflict = withdraw(ctx.owner, ctx.g, 150_000, "same")
    Contract.check!("errors/idempotency_key_conflict", conflict)
    assert %{"error" => "idempotency_key_conflict"} = json_response(conflict, 422)

    assert Repo.aggregate(Withdrawal, :count) == 1

    assert Repo.aggregate(from(a in AuditLog, where: a.action == "withdrawal.request"), :count) ==
             1
  end

  test "more than the balance is rejected and nothing is recorded", ctx do
    over = withdraw(ctx.owner, ctx.g, 500_001)
    Contract.check!("errors/insufficient_balance", over)
    assert %{"error" => "insufficient_balance"} = json_response(over, 422)

    assert %{"status" => "submitted"} =
             ctx.owner |> withdraw(ctx.g, 500_000) |> json_response(201)

    assert Repo.aggregate(Withdrawal, :count) == 1
  end

  test "amounts must be positive whole rupiah", ctx do
    zero = withdraw(ctx.owner, ctx.g, 0)
    Contract.check!("errors/amount_not_positive", zero)
    assert %{"error" => "amount_not_positive"} = json_response(zero, 422)

    text = withdraw(ctx.owner, ctx.g, "100")
    # `details` is a free-form field => message map, so this one test owns the sample.
    Contract.check!("errors/invalid_params", text)
    assert %{"error" => "invalid_params"} = json_response(text, 422)

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

    conn = withdraw(ctx.owner, ctx.g, 100_000)
    Contract.check!("withdrawal.managed", conn)

    assert %{
             "status" => "managed",
             "status_label" => "Selesaikan di dashboard gateway",
             "managed_url" => "https://dashboard.fake.test/withdraw"
           } = json_response(conn, 201)
  end

  test "a replay of a request whose outcome is not stored yet is pending", ctx do
    Repo.insert!(%Withdrawal{
      group_id: ctx.g.id,
      payout_account_id: ctx.account.id,
      amount: 100_000,
      status: "pending",
      idempotency_key: "stuck"
    })

    conn = withdraw(ctx.owner, ctx.g, 100_000, "stuck")
    Contract.check!("withdrawal.pending", conn)

    assert %{
             "status" => "pending",
             "status_label" => "Penarikan lagi diproses",
             "replayed" => true
           } =
             json_response(conn, 200)
  end

  test "a refused request is 502 gateway_error and listed as failed", ctx do
    Petepete.FakeGateway.configure(withdraw: {:error, :provider_down})

    conn = withdraw(ctx.owner, ctx.g, 100_000)
    Contract.check!("errors/gateway_error", conn)
    assert %{"error" => "gateway_error"} = json_response(conn, 502)

    assert %{"withdrawals" => [%{"status" => "failed", "status_label" => label}]} =
             ctx.owner |> get(~p"/api/groups/#{ctx.g.id}/withdrawals") |> json_response(200)

    assert label == "Penarikan gagal. Coba lagi."
  end

  test "history lists every status with its label, newest first", ctx do
    rows = [
      {"failed", nil, nil},
      {"pending", nil, nil},
      {"submitted", "fake-withdrawal-1", nil},
      {"managed", nil, "https://dashboard.fake.test/withdraw"}
    ]

    for {{status, ref, url}, i} <- Enum.with_index(rows) do
      Repo.insert!(%Withdrawal{
        group_id: ctx.g.id,
        payout_account_id: ctx.account.id,
        amount: 10_000 * (i + 1),
        status: status,
        provider_ref: ref,
        managed_url: url,
        idempotency_key: "h#{i}",
        inserted_at: DateTime.add(~U[2026-10-06 03:00:00Z], i, :minute)
      })
    end

    conn = get(ctx.owner, ~p"/api/groups/#{ctx.g.id}/withdrawals")
    Contract.check!("withdrawals.history", conn)

    assert %{"withdrawals" => list} = json_response(conn, 200)

    assert Enum.map(list, &{&1["status"], &1["status_label"]}) == [
             {"managed", "Selesaikan di dashboard gateway"},
             {"submitted", "Penarikan diajukan"},
             {"pending", "Penarikan lagi diproses"},
             {"failed", "Penarikan gagal. Coba lagi."}
           ]
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

    conn = withdraw(ctx.owner, ctx.g, 100_000)
    Contract.check!("errors/payout_account_not_active", conn)
    assert %{"error" => "payout_account_not_active"} = json_response(conn, 422)
  end

  test "a group without a payout account cannot withdraw", %{conn: conn} do
    g = group_fixture()
    {host, _} = login(conn, g, "host")

    conn = withdraw(host, g, 1_000)
    Contract.check!("errors/no_payout_account", conn)
    assert %{"error" => "no_payout_account"} = json_response(conn, 422)

    balance = get(host, ~p"/api/groups/#{g.id}/payout-account/balance")
    assert %{"error" => "no_payout_account", "message" => _} = json_response(balance, 422)
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
      conn = get(ctx.owner, ~p"/api/groups/#{ctx.g.id}/payout-account/balance")
      Contract.check!("payout_balance.active", conn)

      assert %{
               "balance" => 500_000,
               "status" => "active",
               "status_label" => "Aktif",
               "owner" => true,
               "can_withdraw" => true
             } = json_response(conn, 200)
    end

    test "an account still in KYC says so", ctx do
      ctx.account |> Ecto.Changeset.change(status: "pending_kyc") |> Repo.update!()

      assert %{
               "status" => "pending_kyc",
               "status_label" => "Menunggu verifikasi (KYC)",
               "can_withdraw" => false
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
