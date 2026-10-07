defmodule Petepete.Billing.PayPage do
  @moduledoc """
  What a payer sees on the pay page for one bill (`GET /pay/:token`): the group, the
  event, the session date and the per-item breakdown of the bill's share.

  A bill stores only `share`, `credit_applied` and `amount_due`, not its lines. The lines
  are recomputed with `Petepete.Billing.Calculation` from the session's stored cost items
  and attendance, the same inputs `Billing.issue/2` used: a session with non-void bills is
  issued and its inputs cannot be edited (a void bill belongs to a session returned to
  draft, so it shows no lines). When the recomputed share does not equal the bill's stored
  `share` (inputs no longer match the bill), `lines` is empty and `rounding` is `nil`; the
  stored `share`, `credit_applied` and `amount_due` stay authoritative.
  """

  import Ecto.Query, only: [from: 2]

  alias Petepete.Billing.{Bill, Calculation, Invoicing, Session}
  alias Petepete.Groups.Group
  alias Petepete.Repo

  @type line :: %{
          category: String.t(),
          label: String.t() | nil,
          amount: non_neg_integer()
        }

  @type t :: %{
          group_name: String.t() | nil,
          event_name: String.t(),
          session_starts_at: DateTime.t(),
          lines: [line()],
          rounding: integer() | nil
        }

  @doc "The bill with this `pay_token`, or `nil`."
  @spec bill_by_token(term()) :: Bill.t() | nil
  def bill_by_token(token) when is_binary(token) and token != "" do
    Repo.get_by(Bill, pay_token: token)
  end

  def bill_by_token(_token), do: nil

  @doc "Group, event and session date of `bill`, plus its recomputed lines (see the moduledoc)."
  @spec for_bill(Bill.t()) :: t()
  def for_bill(%Bill{} = bill) do
    {session, group_name, event_name} =
      Repo.one!(
        from s in Session,
          join: g in Group,
          on: g.id == s.group_id,
          join: e in assoc(s, :event),
          where: s.id == ^bill.session_id,
          select: {s, g.name, e.name}
      )

    {lines, rounding} = if bill.status == "void", do: {[], nil}, else: lines(session, bill)

    %{
      group_name: group_name,
      event_name: event_name,
      session_starts_at: session.starts_at,
      lines: lines,
      rounding: rounding
    }
  end

  defp lines(session, bill) do
    with {:ok, plan} <- Calculation.shares(Invoicing.load_input(session)),
         %{share: share} = member when share == bill.share <-
           Enum.find(plan.members, &(&1.member_id == bill.member_id)) do
      lines = for l <- member.lines, do: Map.take(l, [:category, :label, :amount])
      {lines, member.rounding}
    else
      _ -> {[], nil}
    end
  end
end
