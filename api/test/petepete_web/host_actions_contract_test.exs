defmodule PetepeteWeb.HostActionsContractTest do
  @moduledoc """
  The contract of every host money action (ADR-0003), run through its HTTP route from
  `PetepeteWeb.HostActionsTable`: audited exactly once, replayable, key required, host only,
  and a refused request leaves neither an audit row nor a ledger txn.
  """
  # Not async: the withdrawal row reads the fake gateway's balance from application config.
  use PetepeteWeb.ConnCase, async: false

  import Petepete.Fixtures

  alias Petepete.Clock
  alias Petepete.Groups.PayoutAccount
  alias Petepete.Ledger.{AuditLog, Txn}
  alias Petepete.Payments.Gateway.Fake
  alias Petepete.Payments.Withdrawal
  alias Petepete.Repo
  alias PetepeteWeb.HostActionsTable

  setup do
    Clock.freeze(~U[2026-10-06 03:00:00Z])
    original = Application.fetch_env!(:petepete, Fake)

    Application.put_env(
      :petepete,
      Fake,
      Keyword.put(original, :balance, HostActionsTable.withdrawal_balance())
    )

    on_exit(fn -> Application.put_env(:petepete, Fake, original) end)
    :ok
  end

  # Everything a host action may change: the audit log, the ledger and the two tables that
  # only payouts write.
  defp state do
    %{
      audit: Repo.all(AuditLog) |> Enum.map(&{&1.id, &1.action}) |> Enum.sort(),
      txns: Repo.aggregate(Txn, :count),
      payout_accounts: Repo.aggregate(PayoutAccount, :count),
      withdrawals: Repo.aggregate(Withdrawal, :count)
    }
  end

  defp actions_since(before) do
    for {id, action} <- state().audit, id not in Enum.map(before.audit, fn {old, _} -> old end) do
      action
    end
    |> Enum.sort()
  end

  defp keyed(conn, key), do: put_req_header(conn, "idempotency-key", key)

  defp key, do: "contract-#{System.unique_integer([:positive])}"

  defp stable(body, row), do: Map.drop(body, ["replayed" | Map.get(row, :replay_drops, [])])

  defp created(row), do: Map.get(row, :created, 201)

  for row <- HostActionsTable.rows() do
    describe row.name do
      setup %{conn: conn} do
        spec = Enum.find(HostActionsTable.rows(), &(&1.name == unquote(row.name)))
        ctx = spec.setup.(HostActionsTable.base())

        %{
          row: spec,
          ctx: ctx,
          host: bearer_conn(conn, ctx.host_user),
          member: bearer_conn(conn, ctx.member_user),
          outsider: bearer_conn(conn, ctx.outsider_user)
        }
      end

      test "a host with a key succeeds and writes exactly the expected audit rows", t do
        {path, body} = t.row.request.(t.ctx)
        before = state()

        resp = t.host |> keyed(key()) |> post(path, body)

        assert resp.status == created(t.row), "got #{resp.status}: #{resp.resp_body}"
        assert actions_since(before) == t.row.audit

        new =
          Enum.reject(
            Repo.all(AuditLog),
            &(&1.id in Enum.map(before.audit, fn {id, _} -> id end))
          )

        assert new != []

        assert Enum.all?(
                 new,
                 &(&1.subject_type == t.row.subject and &1.group_id == t.ctx.group.id)
               )
      end

      test "the same key again returns the same result and no extra audit row", t do
        {path, body} = t.row.request.(t.ctx)
        k = key()

        first = t.host |> keyed(k) |> post(path, body)
        assert first.status == created(t.row)
        after_first = state()

        second = t.host |> keyed(k) |> post(path, body)

        assert second.status == 200, "expected 200 on replay, got: #{second.resp_body}"

        assert stable(json_response(second, 200), t.row) ==
                 stable(json_response(first, created(t.row)), t.row)

        assert state() == after_first
      end

      test "a missing Idempotency-Key is 422 and changes nothing", t do
        {path, body} = t.row.request.(t.ctx)
        before = state()

        resp = post(t.host, path, body)

        assert %{"error" => "idempotency_key_required"} = json_response(resp, 422)
        assert state() == before
      end

      test "a plain member gets 403, a member of another group 404, both without audit", t do
        {path, body} = t.row.request.(t.ctx)
        before = state()

        assert t.member |> keyed(key()) |> post(path, body) |> json_response(403)
        assert t.outsider |> keyed(key()) |> post(path, body) |> json_response(404)
        assert state() == before
      end

      test "a request the domain refuses writes no audit row and no txn", t do
        {path, body, status} = t.row.reject.(t.ctx)
        before = state()

        resp = t.host |> keyed(key()) |> post(path, body)

        assert resp.status == status, "expected #{status}, got #{resp.status}: #{resp.resp_body}"
        assert state() == before
      end
    end
  end
end
