defmodule Petepete.Fixtures do
  @moduledoc "Test fixtures built by direct Repo inserts of the schemas."
  alias Petepete.Accounts.User
  alias Petepete.Billing.{Bill, Session}
  alias Petepete.Groups.{Group, Member}
  alias Petepete.Repo
  alias Petepete.Sessions.Event

  defp uniq, do: System.unique_integer([:positive])

  def user_fixture(attrs \\ %{}) do
    n = uniq()

    Repo.insert!(
      struct!(User, Map.merge(%{phone: "62812#{n}", display_name: "User #{n}"}, Map.new(attrs)))
    )
  end

  def group_fixture(attrs \\ %{}) do
    n = uniq()

    Repo.insert!(
      struct!(Group, Map.merge(%{name: "Group #{n}", invite_token: "inv-#{n}"}, Map.new(attrs)))
    )
  end

  @doc "A roster entry. `role` is `\"host\" | \"member\" | \"guest\"`; `user` links an account (optional)."
  def member_fixture(group, role, user \\ nil) do
    Repo.insert!(%Member{
      group_id: group.id,
      user_id: user && user.id,
      role: role,
      display_name: "Member #{uniq()}"
    })
  end

  @doc "Returns `{user, member}` with `role` host/member/guest in `group`."
  def host_fixture(group), do: user_member(group, "host")
  def plain_member_fixture(group), do: user_member(group, "member")
  def guest_fixture(group), do: user_member(group, "guest")

  defp user_member(group, role) do
    user = user_fixture()
    {user, member_fixture(group, role, user)}
  end

  def event_fixture(group, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        Event,
        Map.merge(%{group_id: group.id, name: "Event #{uniq()}", type: "one_off"}, Map.new(attrs))
      )
    )
  end

  def session_fixture(group, attrs \\ %{}) do
    attrs = Map.new(attrs)
    event = Map.get_lazy(attrs, :event, fn -> event_fixture(group) end)

    Repo.insert!(
      struct!(
        Session,
        Map.merge(
          %{
            group_id: group.id,
            event_id: event.id,
            starts_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          Map.delete(attrs, :event)
        )
      )
    )
  end

  def bill_fixture(session, member, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        Bill,
        Map.merge(
          %{
            session_id: session.id,
            member_id: member.id,
            share: 10_000,
            amount_due: 10_000,
            pay_token: "pay-#{uniq()}",
            token_expires_at:
              DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)
          },
          Map.new(attrs)
        )
      )
    )
  end
end
