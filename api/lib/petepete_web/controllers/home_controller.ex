defmodule PetepeteWeb.HomeController do
  @moduledoc "The group home (`GET /api/groups/:group_id/home`), readable by any member."
  use PetepeteWeb, :controller

  alias Petepete.{Clock, Home}
  alias PetepeteWeb.Labels

  plug PetepeteWeb.Plugs.GroupAccess, role: :member

  def show(conn, _params) do
    member = conn.assigns.member
    home = Home.for_group(member.group_id, Clock.now())

    json(conn, %{
      group: %{id: home.group.id, name: home.group.name},
      role: member.role,
      role_label: Labels.role(member.role),
      next_session: next_session_json(home.next_session),
      kas_balance: home.kas_balance,
      unpaid_bills: Enum.map(home.unpaid_bills, &bill_json/1),
      needs_review_bills: Enum.map(home.needs_review_bills, &bill_json/1)
    })
  end

  defp bill_json(bill), do: Map.put(bill, :status_label, Labels.bill(bill.status))

  defp next_session_json(nil), do: nil

  defp next_session_json(card) do
    %{
      id: card.session.id,
      event_id: card.session.event_id,
      event_name: card.event_name,
      starts_at: card.session.starts_at,
      status: card.session.status,
      status_label: Labels.session(card.progress),
      progress: card.progress,
      cost_total: card.cost_total,
      attended_count: card.attended_count
    }
  end
end
