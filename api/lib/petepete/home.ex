defmodule Petepete.Home do
  @moduledoc """
  What a member sees when opening a group (EVT-03): the next session, the kas balance and
  the bills still open. A read model assembled from Billing and the Ledger in a handful of
  queries, with no per-row lookups, so it stays one round trip however many bills there are.

  Authorization is the caller's job (`Petepete.Groups.Policy.authorize/3`, any member may read).
  """

  alias Petepete.{Billing, Ledger, Repo, Wib}
  alias Petepete.Groups.Group

  @type t :: %{
          group: %Group{},
          next_session: map() | nil,
          kas_balance: integer(),
          unpaid_bills: [map()],
          needs_review_bills: [map()]
        }

  @doc """
  The home data of `group_id` at `now`.

    * `next_session`: the earliest non-cancelled session starting today (WIB) or later, as
      `Billing.next_session/2` returns it, or `nil`;
    * `kas_balance`: the kas balance from `Ledger.balances/1`, integer rupiah;
    * `unpaid_bills` / `needs_review_bills`: `Billing.open_bills/1` split by status, oldest
      session first.
  """
  @spec for_group(pos_integer(), DateTime.t()) :: t()
  def for_group(group_id, %DateTime{} = now) do
    {unpaid, needs_review} =
      group_id |> Billing.open_bills() |> Enum.split_with(&(&1.status == "unpaid"))

    %{
      group: Repo.get!(Group, group_id),
      next_session: Billing.next_session(group_id, Wib.to_utc(Wib.date(now))),
      kas_balance: Ledger.balances(group_id).kas,
      unpaid_bills: unpaid,
      needs_review_bills: needs_review
    }
  end
end
