defmodule Petepete.BillingCostsTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures

  alias Petepete.Accounts.Scope
  alias Petepete.Billing
  alias Petepete.Billing.Session

  setup do
    a = group_fixture()
    b = group_fixture()
    {host_user, host} = host_fixture(a)
    {plain_user, plain} = plain_member_fixture(a)
    {_guest_user, guest} = guest_fixture(a)
    {other_host_user, other_host} = host_fixture(b)
    session = session_fixture(a)

    %{
      a: a,
      host: host,
      plain: plain,
      guest: guest,
      other_host: other_host,
      session: session,
      host_scope: Scope.for(host_user),
      plain_scope: Scope.for(plain_user),
      other_scope: Scope.for(other_host_user)
    }
  end

  defp cost(ctx, attrs \\ %{}) do
    {:ok, item} =
      Billing.create_cost_item(
        ctx.host_scope,
        ctx.session.id,
        Map.merge(%{"category" => "lapangan", "amount" => 350_000}, attrs)
      )

    item
  end

  defp attend(ctx, member, attended \\ true, extra \\ %{}) do
    {:ok, p} =
      Billing.set_attendance(
        ctx.host_scope,
        ctx.session.id,
        Map.merge(%{"member_id" => member.id, "attended" => attended}, extra)
      )

    p
  end

  defp ids(items), do: Enum.map(items, & &1.id)

  defp set_status(session, status),
    do: session |> Ecto.Changeset.change(status: status) |> Repo.update!()

  describe "cost items" do
    test "payer defaults to the acting host and can be any member of the group", ctx do
      item = cost(ctx)
      assert item.paid_by_member_id == ctx.host.id
      assert item.paid_by_member.display_name == ctx.host.display_name

      assert {:ok, again} =
               Billing.update_cost_item(ctx.host_scope, ctx.session.id, item.id, %{
                 "category" => "lapangan",
                 "amount" => 350_000,
                 "paid_by" => ctx.guest.id
               })

      assert again.id == item.id
      assert again.paid_by_member_id == ctx.guest.id
    end

    test "a payer outside the group is rejected", ctx do
      assert {:error, cs} =
               Billing.create_cost_item(ctx.host_scope, ctx.session.id, %{
                 "category" => "lapangan",
                 "amount" => 100,
                 "paid_by" => ctx.other_host.id
               })

      assert %{paid_by: ["must be a member of the group"]} = errors_on(cs)
    end

    test "amount must be a positive integer of rupiah", ctx do
      for bad <- [0, -1, 1000.5, 1000.0, "1000", nil, 1_000_000_000_001] do
        assert {:error, cs} =
                 Billing.create_cost_item(ctx.host_scope, ctx.session.id, %{
                   "category" => "lapangan",
                   "amount" => bad
                 })

        assert Map.has_key?(errors_on(cs), :amount), "accepted #{inspect(bad)}"
      end

      assert Billing.list_cost_items(ctx.session.id) == []
    end

    test "a category is required", ctx do
      assert {:error, cs} =
               Billing.create_cost_item(ctx.host_scope, ctx.session.id, %{
                 "category" => "  ",
                 "amount" => 100
               })

      assert %{category: ["can't be blank"]} = errors_on(cs)
    end

    test "a subset item needs at least one member, all from the group", ctx do
      attrs = %{"category" => "minum", "amount" => 60_000, "scope" => "subset"}

      for members <- [[], nil, [ctx.other_host.id], [ctx.plain.id, ctx.other_host.id], ["1"]] do
        assert {:error, cs} =
                 Billing.create_cost_item(
                   ctx.host_scope,
                   ctx.session.id,
                   Map.put(attrs, "members", members)
                 )

        assert Map.has_key?(errors_on(cs), :members), "accepted #{inspect(members)}"
      end

      assert {:ok, item} =
               Billing.create_cost_item(
                 ctx.host_scope,
                 ctx.session.id,
                 Map.put(attrs, "members", [ctx.guest.id, ctx.plain.id, ctx.plain.id])
               )

      assert item.member_ids == Enum.sort([ctx.guest.id, ctx.plain.id])
    end

    test "an unknown scope is rejected", ctx do
      assert {:error, cs} =
               Billing.create_cost_item(ctx.host_scope, ctx.session.id, %{
                 "category" => "minum",
                 "amount" => 100,
                 "scope" => "some"
               })

      assert %{scope: ["is invalid"]} = errors_on(cs)
    end

    test "update replaces the item, switching to all clears the members; failure changes nothing",
         ctx do
      item = cost(ctx, %{"scope" => "subset", "members" => [ctx.plain.id]})
      assert item.member_ids == [ctx.plain.id]

      assert {:error, _} =
               Billing.update_cost_item(ctx.host_scope, ctx.session.id, item.id, %{
                 "category" => "lapangan",
                 "amount" => 0
               })

      assert [%{amount: 350_000, member_ids: [_]}] = Billing.list_cost_items(ctx.session.id)

      assert {:ok, updated} =
               Billing.update_cost_item(ctx.host_scope, ctx.session.id, item.id, %{
                 "category" => "wasit",
                 "amount" => 100_000,
                 "scope" => "all",
                 "members" => [ctx.plain.id]
               })

      assert %{category: "wasit", amount: 100_000, scope: "all", member_ids: []} = updated
      assert Repo.aggregate(Petepete.Billing.CostItemMember, :count) == 0
    end

    test "update and delete only reach items of that session", ctx do
      other_session = session_fixture(ctx.a)

      {:ok, foreign} =
        Billing.create_cost_item(ctx.host_scope, other_session.id, %{
          "category" => "lapangan",
          "amount" => 1
        })

      assert {:error, :not_found} =
               Billing.update_cost_item(ctx.host_scope, ctx.session.id, foreign.id, %{
                 "category" => "x",
                 "amount" => 1
               })

      assert {:error, :not_found} =
               Billing.delete_cost_item(ctx.host_scope, ctx.session.id, foreign.id)

      assert {:error, :not_found} = Billing.delete_cost_item(ctx.host_scope, ctx.session.id, -1)
    end

    test "delete removes the item and its subset members", ctx do
      item = cost(ctx, %{"scope" => "subset", "members" => [ctx.plain.id]})
      assert {:ok, _} = Billing.delete_cost_item(ctx.host_scope, ctx.session.id, item.id)
      assert Billing.list_cost_items(ctx.session.id) == []
      assert Repo.aggregate(Petepete.Billing.CostItemMember, :count) == 0
    end
  end

  describe "attendance and weight" do
    test "a new participant takes the member's default weight, a toggle keeps the session weight",
         ctx do
      Repo.update!(Ecto.Changeset.change(ctx.guest, default_weight: 1200))

      assert %{attended: true, weight: 1200} = attend(ctx, ctx.guest)
      assert %{attended: true, weight: 1000} = attend(ctx, ctx.plain)
      assert %{weight: 1500} = attend(ctx, ctx.guest, true, %{"weight" => 1500})
      assert %{attended: false, weight: 1500} = attend(ctx, ctx.guest, false)

      assert [%{weight: 1000}, %{attended: false, weight: 1500}] =
               Billing.list_participants(ctx.session.id)
               |> Enum.sort_by(&(&1.member_id != ctx.plain.id))
    end

    test "weight must be a positive integer per mil", ctx do
      for bad <- [0, -1, -1000, 1.2, "1200", 100_001] do
        assert {:error, cs} =
                 Billing.set_attendance(ctx.host_scope, ctx.session.id, %{
                   "member_id" => ctx.plain.id,
                   "attended" => true,
                   "weight" => bad
                 })

        assert Map.has_key?(errors_on(cs), :weight), "accepted #{inspect(bad)}"
      end

      assert Billing.list_participants(ctx.session.id) == []
    end

    test "attended must be a boolean and the member must be on the roster", ctx do
      for bad <- [nil, "true", 1] do
        assert {:error, cs} =
                 Billing.set_attendance(ctx.host_scope, ctx.session.id, %{
                   "member_id" => ctx.plain.id,
                   "attended" => bad
                 })

        assert Map.has_key?(errors_on(cs), :attended)
      end

      assert {:error, cs} =
               Billing.set_attendance(ctx.host_scope, ctx.session.id, %{
                 "member_id" => ctx.other_host.id,
                 "attended" => true
               })

      assert %{member_id: ["must be a member of the group"]} = errors_on(cs)
    end
  end

  describe "bearers" do
    test "scope all is borne by whoever attends; a subset item only by attending members in it",
         ctx do
      all = cost(ctx)
      subset = cost(ctx, %{"scope" => "subset", "members" => [ctx.plain.id, ctx.guest.id]})
      attend(ctx, ctx.host)
      attend(ctx, ctx.plain)
      attend(ctx, ctx.guest, false)

      by_id = Map.new(Billing.list_cost_items(ctx.session.id), &{&1.id, &1.bearer_ids})
      assert by_id[all.id] == Enum.sort([ctx.host.id, ctx.plain.id])
      assert by_id[subset.id] == [ctx.plain.id]
    end

    test "cost_items_without_bearers lists items nobody attending bears", ctx do
      all = cost(ctx)
      subset = cost(ctx, %{"scope" => "subset", "members" => [ctx.guest.id]})
      assert [all.id, subset.id] == ids(Billing.cost_items_without_bearers(ctx.session.id))

      attend(ctx, ctx.host)
      assert [subset.id] == ids(Billing.cost_items_without_bearers(ctx.session))

      attend(ctx, ctx.guest, false)
      assert [subset.id] == ids(Billing.cost_items_without_bearers(ctx.session.id))

      attend(ctx, ctx.guest)
      assert [] = Billing.cost_items_without_bearers(ctx.session.id)
    end
  end

  describe "who and when" do
    defp commands(ctx, item) do
      sid = ctx.session.id

      [
        fn s ->
          Billing.create_cost_item(s, sid, %{"category" => "x", "amount" => 1})
        end,
        fn s ->
          Billing.update_cost_item(s, sid, item.id, %{"category" => "x", "amount" => 2})
        end,
        fn s -> Billing.delete_cost_item(s, sid, item.id) end,
        fn s ->
          Billing.set_attendance(s, sid, %{"member_id" => ctx.plain.id, "attended" => true})
        end
      ]
    end

    test "a plain member is forbidden, another group's host gets not_found, nothing changes",
         ctx do
      item = cost(ctx)

      for command <- commands(ctx, item) do
        assert {:error, :forbidden} = command.(ctx.plain_scope)
        assert {:error, :not_found} = command.(ctx.other_scope)
      end

      assert [%{amount: 350_000}] = Billing.list_cost_items(ctx.session.id)
      assert Billing.list_participants(ctx.session.id) == []
    end

    test "authorization is checked before the status: outsiders never learn it", ctx do
      item = cost(ctx)
      set_status(ctx.session, "issued")

      for command <- commands(ctx, item),
          do: assert({:error, :not_found} = command.(ctx.other_scope))

      for command <- commands(ctx, item),
          do: assert({:error, :forbidden} = command.(ctx.plain_scope))
    end

    test "only a draft session accepts edits, again after the bills are cancelled", ctx do
      item = cost(ctx)

      for status <- ~w(issued cancelled) do
        set_status(ctx.session, status)

        for command <- commands(ctx, item) do
          assert {:error, {:session_not_editable, ^status}} = command.(ctx.host_scope)
        end
      end

      assert [%{amount: 350_000}] = Billing.list_cost_items(ctx.session.id)

      # Billing.void_issue/2 (CALC) returns an issued session to draft.
      Session
      |> Repo.get!(ctx.session.id)
      |> Ecto.Changeset.change(status: "draft")
      |> Repo.update!()

      assert {:ok, _} = Billing.delete_cost_item(ctx.host_scope, ctx.session.id, item.id)
    end

    test "unknown sessions are not_found", ctx do
      assert {:error, :not_found} =
               Billing.create_cost_item(ctx.host_scope, -1, %{"category" => "x", "amount" => 1})

      assert {:error, :not_found} = Billing.get_session(ctx.host_scope, -1)
    end
  end

  describe "get_session/2" do
    test "returns session, derived progress, cost items and participants to any member", ctx do
      cost(ctx)
      attend(ctx, ctx.plain)

      assert {:ok, %{session: %{id: id}, progress: :draft, cost_items: [_], participants: [p]}} =
               Billing.get_session(ctx.plain_scope, ctx.session.id)

      assert id == ctx.session.id
      assert p.member.id == ctx.plain.id
      assert {:error, :not_found} = Billing.get_session(ctx.other_scope, ctx.session.id)
    end
  end
end
