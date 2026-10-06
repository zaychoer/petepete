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

  Accounts meet rosters here: `link_members_by_phone/1` attaches entries added by
  phone number to a login, `hosts_active_group?/1` and `anonymize_roster/1` serve
  account deletion.
  """
  import Ecto.Query

  alias Petepete.Accounts.{Scope, User}
  alias Petepete.Billing.{Bill, Session}
  alias Petepete.Groups.Member
  alias Petepete.Ledger.Txn
  alias Petepete.Repo

  @former_member_label "Mantan anggota"

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

  @doc "The display name that replaces a deleted account's name on rosters, ledger and history."
  @spec former_member_label() :: String.t()
  def former_member_label, do: @former_member_label

  @doc """
  Links roster entries added by phone number to the account owning that number.

  Every `group_members` row without an account whose `phone` normalises to the user's
  phone gets `user_id` set, at most one row per group and never in a group where the
  user already has a row (unique `(group_id, user_id)`). A row another account has
  claimed (`claim_user_id` set to someone else) is never taken. Idempotent. Returns
  the number of rows linked.

  Must run inside the caller's transaction (it locks the rows it links), so a login
  commits its tokens and its links together.
  """
  @spec link_members_by_phone(User.t()) :: non_neg_integer()
  def link_members_by_phone(%User{id: user_id, phone: "62" <> national}) do
    taken = from(m in Member, where: m.user_id == ^user_id, select: m.group_id)
    suffix = "%" <> national

    # The SQL filter is only a cheap digits-suffix prefilter; normalize_phone/1 decides.
    candidates =
      Repo.all(
        from m in Member,
          where: is_nil(m.user_id) and not is_nil(m.phone),
          where: is_nil(m.claim_user_id) or m.claim_user_id == ^user_id,
          where: like(fragment("regexp_replace(?, '[^0-9]', '', 'g')", m.phone), ^suffix),
          where: m.group_id not in subquery(taken),
          order_by: [asc: m.group_id, asc: m.id],
          lock: "FOR UPDATE"
      )

    candidates
    |> Enum.filter(&(Petepete.Accounts.normalize_phone(&1.phone) == {:ok, "62" <> national}))
    |> Enum.uniq_by(& &1.group_id)
    |> Enum.map(& &1.id)
    |> case do
      [] ->
        0

      ids ->
        {count, _} =
          Repo.update_all(from(m in Member, where: m.id in ^ids), set: [user_id: user_id])

        count
    end
  end

  @doc """
  Whether the user hosts a group that is still active.

  A group is active when it has any session that is not cancelled, or any roster
  entry besides the host's own. A group with only its host and no live sessions is
  empty and may be left behind.
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

  @doc """
  Anonymises every roster entry of the user: name becomes `former_member_label/0`,
  phone is dropped, and claims by the user are withdrawn. The rows stay (ledger
  entries point at them), and so does their `user_id` link to the anonymised account.
  """
  @spec anonymize_roster(integer()) :: :ok
  def anonymize_roster(user_id) do
    now = Petepete.Clock.now()

    Repo.update_all(from(m in Member, where: m.user_id == ^user_id),
      set: [display_name: @former_member_label, phone: nil, updated_at: now]
    )

    Repo.update_all(from(m in Member, where: m.claim_user_id == ^user_id),
      set: [claim_user_id: nil, updated_at: now]
    )

    :ok
  end
end
