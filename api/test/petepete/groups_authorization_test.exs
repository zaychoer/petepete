defmodule Petepete.GroupsAuthorizationTest do
  use Petepete.DataCase, async: true

  import Petepete.Fixtures

  alias Petepete.Accounts.Scope
  alias Petepete.Groups
  alias Petepete.Groups.Policy, as: GroupsPolicy
  alias Petepete.Ledger.Txn

  setup do
    a = group_fixture()
    b = group_fixture()
    {host_a, host_a_member} = host_fixture(a)
    {plain_a, plain_a_member} = plain_member_fixture(a)
    {guest_a, _} = guest_fixture(a)
    {host_b, host_b_member} = host_fixture(b)
    session_b = session_fixture(event_fixture(b))
    bill_b = bill_fixture(session_b, host_b_member)

    txn_b =
      Repo.insert!(%Txn{
        group_id: b.id,
        kind: "gateway_payment_received",
        actor_type: "gateway",
        idempotency_key: "fnd03-#{System.unique_integer([:positive])}"
      })

    %{
      a: a,
      b: b,
      host_a: Scope.for(host_a),
      host_a_member: host_a_member,
      plain_a: Scope.for(plain_a),
      plain_a_member: plain_a_member,
      guest_a: Scope.for(guest_a),
      host_b: Scope.for(host_b),
      session_b: session_b,
      bill_b: bill_b,
      txn_b: txn_b,
      host_b_member: host_b_member
    }
  end

  test "member of group A gets :not_found for group B resources of every kind", ctx do
    for {kind, id} <- [
          session: ctx.session_b.id,
          bill: ctx.bill_b.id,
          txn: ctx.txn_b.id,
          member: ctx.host_b_member.id
        ] do
      group_id = GroupsPolicy.group_id_for(kind, id)
      assert group_id == ctx.b.id
      assert GroupsPolicy.authorize(ctx.plain_a, group_id, :member) == {:error, :not_found}
      assert GroupsPolicy.authorize(ctx.host_a, group_id, :member) == {:error, :not_found}
      assert GroupsPolicy.authorize(ctx.host_a, group_id, :host) == {:error, :not_found}
    end
  end

  test "group_id_for is nil for unknown ids" do
    for kind <- [:session, :bill, :txn, :member],
        do: assert(GroupsPolicy.group_id_for(kind, -1) == nil)
  end

  test "plain member can read but gets :forbidden for host actions", ctx do
    assert {:ok, m} = GroupsPolicy.authorize(ctx.plain_a, ctx.a.id, :member)
    assert m.id == ctx.plain_a_member.id
    assert GroupsPolicy.authorize(ctx.plain_a, ctx.a.id, :host) == {:error, :forbidden}
    assert {:ok, _} = GroupsPolicy.authorize(ctx.guest_a, ctx.a.id, :member)
    assert GroupsPolicy.authorize(ctx.guest_a, ctx.a.id, :host) == {:error, :forbidden}
  end

  test "host of A is host of A only", ctx do
    assert {:ok, m} = GroupsPolicy.authorize(ctx.host_a, ctx.a.id, :host)
    assert m.id == ctx.host_a_member.id
    assert GroupsPolicy.authorize(ctx.host_a, ctx.b.id, :host) == {:error, :not_found}
    assert {:ok, _} = GroupsPolicy.authorize(ctx.host_b, ctx.b.id, :host)
    assert GroupsPolicy.authorize(ctx.host_b, ctx.a.id, :host) == {:error, :not_found}
  end

  test "authorize_actor builds a host Actor for the host of that group only", ctx do
    assert {:ok, actor} = GroupsPolicy.authorize_actor(ctx.host_a, ctx.a.id, :host)

    assert actor == %Petepete.Actor{
             type: :host,
             user_id: ctx.host_a_member.user_id,
             member_id: ctx.host_a_member.id
           }

    assert GroupsPolicy.authorize_actor(ctx.host_a, ctx.b.id, :host) == {:error, :not_found}
    assert GroupsPolicy.authorize_actor(ctx.host_a, nil, :host) == {:error, :not_found}
    assert GroupsPolicy.authorize_actor(ctx.plain_a, ctx.a.id, :host) == {:error, :forbidden}
    assert GroupsPolicy.authorize_actor(ctx.guest_a, ctx.a.id, :host) == {:error, :forbidden}
    assert GroupsPolicy.authorize_actor(ctx.host_b, ctx.a.id, :host) == {:error, :not_found}
  end

  test "scope helpers restrict queries to one group", ctx do
    session_a = session_fixture(event_fixture(ctx.a))
    bill_a = bill_fixture(session_a, ctx.host_a_member)

    ids =
      Petepete.Billing.Session
      |> Groups.scope_to_group(ctx.a.id)
      |> Repo.all()
      |> Enum.map(& &1.id)

    assert ids == [session_a.id]

    bills = Petepete.Billing.Bill |> Groups.bills_in_group(ctx.b.id) |> Repo.all()
    assert Enum.map(bills, & &1.id) == [ctx.bill_b.id]
    refute bill_a.id in Enum.map(bills, & &1.id)
  end
end
