defmodule Petepete.Groups do
  @moduledoc """
  Groups, their roster and their payout account, plus per-group authorization.

  Schemas: `Petepete.Groups.Group` (`groups`), `Petepete.Groups.Member`
  (`group_members`; hosts, members and guests), `Petepete.Groups.PayoutAccount`
  (`payout_accounts`).

  Authorization: a user only sees their own group's data. Non-members get
  `:not_found` (existence is never leaked); a member acting beyond their role
  gets `:forbidden`. Everything that writes sessions, costs, bills or the
  ledger is host-only.
  """
  import Ecto.Query

  alias Petepete.Accounts.Scope
  alias Petepete.Billing.{Bill, Session}
  alias Petepete.Groups.Member
  alias Petepete.Ledger.Txn
  alias Petepete.Repo

  @type role :: :member | :host
  @type resource :: :session | :bill | :txn | :member

  @doc """
  Resolves the caller's roster entry in `group_id` and checks it satisfies `role`.

  `:member` accepts any roster entry linked to the caller's account (host,
  member or guest); `:host` requires the host role.
  """
  @spec authorize(Scope.t(), integer() | nil, role()) ::
          {:ok, Member.t()} | {:error, :not_found | :forbidden}
  def authorize(%Scope{user: %{id: user_id}}, group_id, role)
      when is_integer(group_id) and role in [:member, :host] do
    member =
      Repo.one(
        from m in Member,
          where: m.group_id == ^group_id and m.user_id == ^user_id,
          order_by: [asc: fragment("CASE ? WHEN 'host' THEN 0 ELSE 1 END", m.role), asc: m.id],
          limit: 1
      )

    case {member, role} do
      {nil, _} -> {:error, :not_found}
      {%Member{role: "host"} = m, _} -> {:ok, m}
      {m, :member} -> {:ok, m}
      {_, :host} -> {:error, :forbidden}
    end
  end

  def authorize(%Scope{}, _group_id, role) when role in [:member, :host],
    do: {:error, :not_found}

  @doc "The id of the group owning the resource, or `nil` if it does not exist."
  @spec group_id_for(resource(), integer()) :: integer() | nil
  def group_id_for(:session, id), do: group_of(Session, id)
  def group_id_for(:txn, id), do: group_of(Txn, id)
  def group_id_for(:member, id), do: group_of(Member, id)

  def group_id_for(:bill, id) do
    Repo.one(
      from b in Bill,
        join: s in Session,
        on: s.id == b.session_id,
        where: b.id == ^id,
        select: s.group_id
    )
  end

  defp group_of(schema, id) when is_integer(id),
    do: Repo.one(from r in schema, where: r.id == ^id, select: r.group_id)

  defp group_of(_schema, _id), do: nil

  @doc "Restricts a query over a table with a `group_id` column (sessions, events, members, txns…) to one group."
  @spec scope_to_group(Ecto.Queryable.t(), integer()) :: Ecto.Query.t()
  def scope_to_group(queryable, group_id), do: where(queryable, [r], r.group_id == ^group_id)

  @doc "Restricts a bills query to bills of sessions in one group."
  @spec bills_in_group(Ecto.Queryable.t(), integer()) :: Ecto.Query.t()
  def bills_in_group(queryable, group_id) do
    from b in queryable,
      join: s in Session,
      on: s.id == b.session_id,
      where: s.group_id == ^group_id
  end
end
