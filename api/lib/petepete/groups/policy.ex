defmodule Petepete.Groups.Policy do
  @moduledoc "Access policy for groups (ADR-0003). The single authority on who may act and as which Actor."

  import Ecto.Query

  alias Petepete.Accounts.Scope
  alias Petepete.Actor
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

  @doc """
  Authorizes the caller as host of `group_id` and returns the host `Petepete.Actor` that
  contexts take for host actions. The only constructor of a host Actor in production code.

  Non-members get `{:error, :not_found}`, non-host members `{:error, :forbidden}`.
  """
  @spec authorize_actor(Scope.t(), integer() | nil, :host) ::
          {:ok, Actor.t()} | {:error, :not_found | :forbidden}
  def authorize_actor(%Scope{} = scope, group_id, :host) do
    with {:ok, %Member{} = member} <- authorize(scope, group_id, :host) do
      {:ok, %Actor{type: :host, user_id: member.user_id, member_id: member.id}}
    end
  end

  @doc """
  Returns the `group_id` that owns the given resource, or `nil` if not found.
  """
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

  @doc """
  True when the user hosts at least one group that has a non-cancelled session or
  a second member.
  """
  @spec hosts_active_group?(integer()) :: boolean()
  def hosts_active_group?(user_id) do
    Repo.exists?(
      from h in Member,
        as: :h,
        where: h.user_id == ^user_id and h.role == "host",
        where:
          exists(
            from s in Session,
              where: s.group_id == parent_as(:h).group_id and s.status != "cancelled"
          ) or
            exists(
              from m in Member,
                where: m.group_id == parent_as(:h).group_id and m.id != parent_as(:h).id
            )
    )
  end

  defp group_of(schema, id) when is_integer(id),
    do: Repo.one(from r in schema, where: r.id == ^id, select: r.group_id)

  defp group_of(_schema, _id), do: nil
end
