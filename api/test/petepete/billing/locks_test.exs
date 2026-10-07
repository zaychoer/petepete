defmodule Petepete.Billing.LocksTest do
  # Real committed data and real connections: lock behaviour cannot be shown inside the
  # sandbox transaction. Not async, so no sandboxed test runs alongside it.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Petepete.Billing
  alias Petepete.Billing.{Bill, Session}
  alias Petepete.Groups.{Group, Member}
  alias Petepete.Repo
  alias Petepete.Sessions.Event

  import Petepete.Fixtures

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    group = group_fixture()
    event = event_fixture(group)
    session = session_fixture(event, status: "issued")
    bills = for _ <- 1..3, do: bill_fixture(session, member_fixture(group))

    on_exit(fn ->
      Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from b in Bill, where: b.session_id == ^session.id)
      Repo.delete_all(from s in Session, where: s.id == ^session.id)
      Repo.delete_all(from e in Event, where: e.id == ^event.id)
      Repo.delete_all(from m in Member, where: m.group_id == ^group.id)
      Repo.delete_all(from g in Group, where: g.id == ^group.id)
    end)

    {:ok, session: session, bills: bills}
  end

  # Runs `fun` in its own process, with its own connection and transaction.
  defp in_tx(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        Repo.transaction(fun)
      rescue
        error in Postgrex.Error -> {:error, error}
      end
    end)
  end

  defp await_all(tasks), do: Task.await_many(tasks, 15_000)

  test "locks must be taken inside a transaction" do
    assert_raise ArgumentError, fn -> Billing.lock_session(1) end
    assert_raise ArgumentError, fn -> Billing.lock_bills([1]) end
  end

  test "lock_session returns the row or :not_found", %{session: session} do
    assert {:ok, %Session{id: id}} =
             Repo.transaction(fn -> elem(Billing.lock_session(session.id), 1) end)

    assert id == session.id
    assert {:ok, {:error, :not_found}} = Repo.transaction(fn -> Billing.lock_session(-1) end)
  end

  test "lock_bills returns bills by ascending id whatever the request order", %{bills: bills} do
    ids = Enum.map(bills, & &1.id)

    {:ok, locked} = Repo.transaction(fn -> Billing.lock_bills(Enum.reverse(ids) ++ ids) end)
    assert Enum.map(locked, & &1.id) == ids
  end

  test "lock_session_and_bills locks the session and all its bills", %{
    session: session,
    bills: bills
  } do
    parent = self()

    holder =
      in_tx(fn ->
        {:ok, %Session{}, locked} = Billing.lock_session_and_bills(session.id)
        send(parent, {:locked, Enum.map(locked, & &1.id)})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:locked, ids}
    assert ids == Enum.map(bills, & &1.id)

    # nobody else can lock the session or any bill while the holder's transaction is open
    probe =
      in_tx(fn ->
        Repo.all(from s in Session, where: s.id == ^session.id, lock: "FOR UPDATE NOWAIT")
      end)

    assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} = Task.await(probe)

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder)
  end

  describe "lock order" do
    test "commands that follow session -> bills (by id) never deadlock", %{
      session: session,
      bills: bills
    } do
      ids = Enum.map(bills, & &1.id)

      # issue/void_issue-like: session then every bill; webhook/cash-like: bills only, in
      # arbitrary request order. Every worker signals once it holds its locks and keeps them
      # until released, so the rest queue behind it on real locks; the test process releases
      # the holders one by one as they report in.
      parent = self()

      tasks =
        for i <- 1..24 do
          acquire =
            if rem(i, 3) == 0 do
              fn -> {:ok, _, _} = Billing.lock_session_and_bills(session.id) end
            else
              order = if rem(i, 2) == 0, do: ids, else: Enum.reverse(ids)
              fn -> Billing.lock_bills(order) end
            end

          in_tx(fn ->
            acquire.()
            send(parent, {:holding, self()})
            receive do: (:release -> :ok)
          end)
        end

      for _ <- 1..24 do
        assert_receive {:holding, pid}, 15_000
        send(pid, :release)
      end

      assert Enum.all?(await_all(tasks), &(&1 == {:ok, :ok}))
    end

    test "control: violating the order does deadlock, and Postgres aborts one side", %{
      session: session,
      bills: [bill | _]
    } do
      parent = self()

      # A follows the documented order (session, then bill); B takes the bill first and
      # then the session. Each waits until the other holds its first lock.
      a =
        in_tx(fn ->
          {:ok, _} = Billing.lock_session(session.id)
          send(parent, {:ready, :a})
          receive do: (:go -> :ok)
          Billing.lock_bills([bill.id])
        end)

      b =
        in_tx(fn ->
          Billing.lock_bills([bill.id])
          send(parent, {:ready, :b})
          receive do: (:go -> :ok)
          Billing.lock_session(session.id)
        end)

      assert_receive {:ready, :a}, 5_000
      assert_receive {:ready, :b}, 5_000
      send(a.pid, :go)
      send(b.pid, :go)

      results = await_all([a, b])

      assert [{:error, %Postgrex.Error{postgres: %{code: :deadlock_detected}}}] =
               Enum.filter(results, &match?({:error, _}, &1))
    end
  end
end
