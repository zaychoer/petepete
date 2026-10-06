defmodule Petepete.Fixtures do
  @moduledoc "Test fixtures. Extend by appending functions."

  alias Petepete.Accounts.User
  alias Petepete.Groups.{Group, Member, PayoutAccount}
  alias Petepete.Repo

  defp uniq, do: System.unique_integer([:positive])

  def user!(attrs \\ []) do
    Repo.insert!(struct(%User{phone: "62#{uniq()}", display_name: "User#{uniq()}"}, attrs))
  end

  def group!(attrs \\ []) do
    Repo.insert!(struct(%Group{name: "Futsal", invite_token: "inv#{uniq()}"}, attrs))
  end

  def member!(group, attrs \\ []) do
    Repo.insert!(
      struct(%Member{group_id: group.id, display_name: "M#{uniq()}", role: "member"}, attrs)
    )
  end

  def payout_account!(group, owner, attrs \\ []) do
    Repo.insert!(
      struct(
        %PayoutAccount{
          group_id: group.id,
          owner_member_id: owner.id,
          provider: "fake",
          provider_account_id: "acc#{uniq()}",
          status: "active"
        },
        attrs
      )
    )
  end
end
