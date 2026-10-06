defmodule Petepete.Fixtures do
  @moduledoc """
  Test fixtures. Parallel tickets append new functions at the end of this module.
  """

  alias Petepete.Billing.{Bill, Session}
  alias Petepete.Groups.{Group, Member}
  alias Petepete.Repo
  alias Petepete.Sessions.Event

  def uniq, do: System.unique_integer([:positive])

  def group!(attrs \\ []) do
    Repo.insert!(struct(%Group{name: "Futsal", invite_token: "inv#{uniq()}"}, attrs))
  end

  def member!(group, attrs \\ []) do
    Repo.insert!(
      struct(%Member{group_id: group.id, display_name: "M#{uniq()}", role: "member"}, attrs)
    )
  end

  def event!(group, attrs \\ []) do
    Repo.insert!(
      struct(
        %Event{
          group_id: group.id,
          name: "Futsal Kamis",
          type: "one_off",
          starts_at: ~U[2026-10-08 12:00:00Z]
        },
        attrs
      )
    )
  end

  def session!(event, attrs \\ []) do
    Repo.insert!(
      struct(
        %Session{
          event_id: event.id,
          group_id: event.group_id,
          starts_at: ~U[2026-10-08 12:00:00Z]
        },
        attrs
      )
    )
  end

  def bill!(session, member, attrs \\ []) do
    Repo.insert!(
      struct(
        %Bill{
          session_id: session.id,
          member_id: member.id,
          share: 20_000,
          amount_due: 20_000,
          pay_token: "tok#{uniq()}",
          token_expires_at: ~U[2026-11-08 12:00:00Z]
        },
        attrs
      )
    )
  end

  @doc "A draft session with its event and group, plus the members passed in `:members` names."
  def session_with_group!(attrs \\ []) do
    group = group!()
    event = event!(group)
    {group, event, session!(event, attrs)}
  end
end
