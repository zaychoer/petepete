defmodule PetepeteWeb.SessionVoidControllerTest do
  use PetepeteWeb.ConnCase, async: true
  use Oban.Testing, repo: Petepete.Repo

  import Ecto.Query
  import Petepete.Fixtures
  import Petepete.BillingScenario, only: [attempt!: 1]

  alias Petepete.{Billing, Clock, Repo}
  alias Petepete.Billing.{Bill, Session}
  alias Petepete.Ledger.{AuditLog, Txn}
  alias Petepete.Payments.PaymentAttempt

  setup %{conn: conn} do
    Clock.freeze(~U[2026-10-06 03:00:00Z])
    group = group_fixture()
    host_user = user_fixture(%{phone: valid_phone()})
    plain_user = user_fixture(%{phone: valid_phone()})
    stranger_user = user_fixture(%{phone: valid_phone()})
    host = member_fixture(group, role: "host", user: host_user)
    member_fixture(group, role: "member", user: plain_user)
    member_fixture(group_fixture(), role: "host", user: stranger_user)

    a = member_fixture(group, role: "member")
    session = session_fixture(event_fixture(group))
    for m <- [host, a], do: attendance_fixture(session, m)
    cost_item_fixture(session, amount: 100_000, paid_by: host)

    {:ok, %{bills: bills}} =
      Billing.issue(session.id, actor: host_actor(group, host), idempotency_key: "issue-1")

    %{
      group: group,
      session: session,
      bill: Enum.find(bills, &(&1.member_id == a.id)),
      host_conn: bearer_conn(conn, host_user),
      plain_conn: bearer_conn(conn, plain_user),
      stranger_conn: bearer_conn(conn, stranger_user)
    }
  end

  defp void(conn, session, key, reason) do
    conn
    |> put_req_header("idempotency-key", key)
    |> post(~p"/api/sessions/#{session.id}/void", %{reason: reason})
  end

  defp txn_count(group),
    do: Repo.aggregate(from(t in Txn, where: t.group_id == ^group.id), :count)

  defp audit_count(group),
    do:
      Repo.aggregate(
        from(a in AuditLog, where: a.group_id == ^group.id and a.action == "session.void_issue"),
        :count
      )

  test "voids the session: reversing txn, voided bills, draft session, cancelled attempts", ctx do
    attempt = attempt!(ctx.bill)

    body = void(ctx.host_conn, ctx.session, "void-1", "salah hitung") |> json_response(201)

    assert %{
             "txn_id" => txn_id,
             "replayed" => false,
             "session_id" => session_id,
             "voided_bill_ids" => voided,
             "cancelled_attempt_ids" => attempt_ids
           } = body

    assert session_id == ctx.session.id
    assert length(voided) == 2
    assert attempt_ids == [attempt.id]
    assert %Txn{kind: "session_bills_cancelled", reason: "salah hitung"} = Repo.get!(Txn, txn_id)
    assert %Session{status: "draft"} = Repo.get!(Session, ctx.session.id)
    assert Repo.all(from b in Bill, select: b.status) == ["void", "void"]
    assert Repo.get!(PaymentAttempt, attempt.id).status == "cancelled"
    assert audit_count(ctx.group) == 1
  end

  test "a first void enqueues the gateway cancellation of its attempts, a replay does not", ctx do
    attempt = attempt!(ctx.bill)

    void(ctx.host_conn, ctx.session, "void-job", "salah") |> json_response(201)

    assert_enqueued(
      worker: Petepete.Payments.CancelAttemptsJob,
      args: %{"attempt_ids" => [attempt.id]}
    )

    void(ctx.host_conn, ctx.session, "void-job", "salah") |> json_response(200)
    assert [_one] = all_enqueued(worker: Petepete.Payments.CancelAttemptsJob)
  end

  test "a void without pending attempts enqueues nothing", ctx do
    void(ctx.host_conn, ctx.session, "void-none", "salah") |> json_response(201)
    refute_enqueued(worker: Petepete.Payments.CancelAttemptsJob)
  end

  test "the reason and the key are required", ctx do
    assert %{"error" => "reason_required"} =
             ctx.host_conn
             |> put_req_header("idempotency-key", "k1")
             |> post(~p"/api/sessions/#{ctx.session.id}/void")
             |> json_response(422)

    assert %{"error" => "reason_required"} =
             void(ctx.host_conn, ctx.session, "k2", " ") |> json_response(422)

    assert %{"error" => "idempotency_key_required"} =
             post(ctx.host_conn, ~p"/api/sessions/#{ctx.session.id}/void", %{reason: "x"})
             |> json_response(422)

    assert %Session{status: "issued"} = Repo.get!(Session, ctx.session.id)
    assert txn_count(ctx.group) == 1
  end

  test "a session that is not issued is 409", ctx do
    void(ctx.host_conn, ctx.session, "k1", "salah") |> json_response(201)

    assert %{"error" => "invalid_transition", "entity" => "session", "status" => "draft"} =
             void(ctx.host_conn, ctx.session, "k2", "lagi") |> json_response(409)
  end

  test "only the host of the session's group", ctx do
    assert void(ctx.plain_conn, ctx.session, "k1", "x") |> json_response(403) == %{
             "error" => "forbidden"
           }

    assert void(ctx.stranger_conn, ctx.session, "k2", "x") |> json_response(404) == %{
             "error" => "not_found"
           }

    assert void(ctx.host_conn, %{id: 0}, "k3", "x") |> json_response(404)

    assert build_conn()
           |> put_req_header("idempotency-key", "k4")
           |> post(~p"/api/sessions/#{ctx.session.id}/void", %{reason: "x"})
           |> json_response(401)

    assert %Session{status: "issued"} = Repo.get!(Session, ctx.session.id)
    assert txn_count(ctx.group) == 1
  end
end
