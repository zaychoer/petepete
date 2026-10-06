defmodule PetepeteWeb.BillControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Ecto.Query
  import Petepete.Fixtures

  alias Petepete.{Billing, Clock, Ledger, Repo}
  alias Petepete.Billing.Bill
  alias Petepete.Ledger.{AuditLog, Txn}

  @t0 ~U[2026-10-06 03:00:00Z]

  setup %{conn: conn} do
    Clock.freeze(@t0)
    group = group_fixture()
    host_user = user_fixture(%{phone: valid_phone()})
    plain_user = user_fixture(%{phone: valid_phone()})
    stranger_user = user_fixture(%{phone: valid_phone()})
    host = member_fixture(group, role: "host", user: host_user)
    member_fixture(group, role: "member", user: plain_user)
    other_group = group_fixture()
    member_fixture(other_group, role: "host", user: stranger_user)

    a = member_fixture(group, role: "member")
    session = session_fixture(event_fixture(group))
    for m <- [host, a], do: attendance_fixture(session, m)
    cost_item_fixture(session, amount: 100_000, paid_by: host)

    {:ok, %{bills: bills}} =
      Billing.issue(session.id, actor: host_actor(group, host), idempotency_key: "issue-1")

    bill = Enum.find(bills, &(&1.member_id == a.id))

    %{
      group: group,
      bill: bill,
      session: session,
      host_conn: bearer_conn(conn, host_user),
      plain_conn: bearer_conn(conn, plain_user),
      stranger_conn: bearer_conn(conn, stranger_user)
    }
  end

  defp keyed(conn, key), do: put_req_header(conn, "idempotency-key", key)
  defp cash(conn, bill, key), do: conn |> keyed(key) |> post(~p"/api/bills/#{bill.id}/cash")

  defp cancel(conn, bill, key, reason) do
    conn |> keyed(key) |> post(~p"/api/bills/#{bill.id}/cash/cancel", %{reason: reason})
  end

  defp txn_count(group),
    do: Repo.aggregate(from(t in Txn, where: t.group_id == ^group.id), :count)

  defp audit_count(group, action),
    do:
      Repo.aggregate(
        from(a in AuditLog, where: a.group_id == ^group.id and a.action == ^action),
        :count
      )

  describe "POST /api/bills/:id/cash" do
    test "marks the bill paid in cash", ctx do
      body = cash(ctx.host_conn, ctx.bill, "cash-1") |> json_response(201)

      assert %{"txn_id" => txn_id, "replayed" => false, "bill" => bill} = body
      assert %{"status" => "paid", "paid_via" => "cash", "amount_due" => 50_000} = bill
      assert %Txn{kind: "cash_received"} = Repo.get!(Txn, txn_id)
      assert %Bill{status: "paid", paid_txn_id: ^txn_id} = Repo.get!(Bill, ctx.bill.id)
      assert audit_count(ctx.group, "bill.mark_paid_cash") == 1
    end

    test "a bill that is not open is 409", ctx do
      cash(ctx.host_conn, ctx.bill, "k1") |> json_response(201)

      assert %{"error" => "invalid_transition", "entity" => "bill", "status" => "paid"} =
               cash(ctx.host_conn, ctx.bill, "k2") |> json_response(409)
    end

    test "only the host of the bill's group: member 403, other group's host and anon 404/401",
         ctx do
      assert cash(ctx.plain_conn, ctx.bill, "k1") |> json_response(403) == %{
               "error" => "forbidden"
             }

      assert cash(ctx.stranger_conn, ctx.bill, "k2") |> json_response(404) ==
               %{"error" => "not_found"}

      assert cash(ctx.host_conn, %{id: 0}, "k3") |> json_response(404)

      assert build_conn()
             |> keyed("k4")
             |> post(~p"/api/bills/#{ctx.bill.id}/cash")
             |> json_response(401)

      assert Repo.get!(Bill, ctx.bill.id).status == "unpaid"
      assert txn_count(ctx.group) == 1
    end
  end

  describe "POST /api/bills/:id/cash/cancel" do
    # The cash is taken exactly 24 hours before `@t0`, the clock the tokens were issued at.
    setup ctx do
      Clock.freeze(DateTime.add(@t0, -24 * 3600, :second))
      cash(ctx.host_conn, ctx.bill, "cash-1") |> json_response(201)
      Clock.freeze(@t0)
      :ok
    end

    test "cancels within 24 hours: new reversing txn, bill unpaid", ctx do
      body = cancel(ctx.host_conn, ctx.bill, "undo-1", "salah orang") |> json_response(201)

      assert %{"txn_id" => id, "replayed" => false, "bill" => %{"status" => "unpaid"}} = body
      assert %Txn{kind: "cash_payment_cancelled", reason: "salah orang"} = Repo.get!(Txn, id)
      assert Ledger.balances(ctx.group.id).members[ctx.bill.member_id] == -50_000
      assert audit_count(ctx.group, "bill.cancel_cash") == 1
    end

    test "after 24 hours is 422 undo_window_expired", ctx do
      Clock.advance(1)

      assert %{"error" => "undo_window_expired", "message" => _} =
               cancel(ctx.host_conn, ctx.bill, "undo-1", "telat") |> json_response(422)

      assert Repo.get!(Bill, ctx.bill.id).status == "paid"
      assert audit_count(ctx.group, "bill.cancel_cash") == 0
    end

    test "a repeated request is one txn and one audit row", ctx do
      first = cancel(ctx.host_conn, ctx.bill, "undo-1", "salah") |> json_response(201)
      second = cancel(ctx.host_conn, ctx.bill, "undo-1", "salah") |> json_response(200)

      assert second["replayed"] == true
      assert second["txn_id"] == first["txn_id"]
      assert txn_count(ctx.group) == 3
      assert audit_count(ctx.group, "bill.cancel_cash") == 1
    end

    test "the reason is required, as is the key", ctx do
      assert %{"error" => "reason_required"} =
               ctx.host_conn
               |> keyed("u1")
               |> post(~p"/api/bills/#{ctx.bill.id}/cash/cancel")
               |> json_response(422)

      assert %{"error" => "reason_required"} =
               cancel(ctx.host_conn, ctx.bill, "u2", "  ") |> json_response(422)

      assert %{"error" => "idempotency_key_required"} =
               post(ctx.host_conn, ~p"/api/bills/#{ctx.bill.id}/cash/cancel", %{reason: "x"})
               |> json_response(422)
    end

    test "a bill that was not paid in cash is 422 not_cash_payment", ctx do
      host_bill =
        Repo.one!(
          from b in Bill,
            where:
              b.session_id == ^ctx.session.id and b.status == "paid" and b.paid_via == "credit"
        )

      assert %{"error" => "not_cash_payment"} =
               cancel(ctx.host_conn, host_bill, "u1", "x") |> json_response(422)
    end

    test "only the host of the bill's group", ctx do
      assert cancel(ctx.plain_conn, ctx.bill, "u1", "x") |> json_response(403)
      assert cancel(ctx.stranger_conn, ctx.bill, "u2", "x") |> json_response(404)
      assert Repo.get!(Bill, ctx.bill.id).status == "paid"
    end
  end
end
