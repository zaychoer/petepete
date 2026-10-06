defmodule PetepeteWeb.SessionJSON do
  @moduledoc """
  JSON for sessions, cost items and participants.

  A cost item shows its payer (`paid_by`, `paid_by_name`), the members a subset item is
  limited to (`members`) and who actually bears it (`bearer_ids`: attending members in
  scope). Money is integer rupiah, weights integer per mil.
  """

  alias Petepete.Billing.{CostItem, Participant}

  def show(%{
        detail: %{session: session, progress: progress, cost_items: items, participants: parts}
      }) do
    %{
      session: %{
        id: session.id,
        event_id: session.event_id,
        group_id: session.group_id,
        starts_at: session.starts_at,
        status: session.status,
        progress: progress
      },
      cost_items: Enum.map(items, &cost_item_data/1),
      participants: Enum.map(parts, &participant_data/1)
    }
  end

  def cost_item(%{cost_item: item}), do: %{cost_item: cost_item_data(item)}

  def participant(%{participant: participant}), do: %{participant: participant_data(participant)}

  defp cost_item_data(%CostItem{} = item) do
    %{
      id: item.id,
      session_id: item.session_id,
      category: item.category,
      label: item.label,
      amount: item.amount,
      paid_by: item.paid_by_member_id,
      paid_by_name: item.paid_by_member && item.paid_by_member.display_name,
      scope: item.scope,
      members: item.member_ids,
      bearer_ids: item.bearer_ids
    }
  end

  defp participant_data(%Participant{} = participant) do
    %{
      member_id: participant.member_id,
      display_name: participant.member.display_name,
      role: participant.member.role,
      attended: participant.attended,
      weight: participant.weight
    }
  end
end
