defmodule Petepete.Groups do
  @moduledoc """
  Groups, their roster and their payout account, plus per-group authorization.

  Schemas: `Petepete.Groups.Group` (`groups`), `Petepete.Groups.Member`
  (`group_members`; hosts, members and guests), `Petepete.Groups.PayoutAccount`
  (`payout_accounts`).

  Roster flows: a host creates a group (`create_group/2`), shares its invite link
  (`invite_url/1`, `reset_invite/1`), people join by token (`join/3`, with or without
  an account), an app user claims a roster entry without an account and the host
  approves (`claim/2`, `approve_claim/2`, `reject_claim/2`), and the host adds guests
  (`add_guest/2`). Approving a claim only links the account to the roster entry: the
  member id stays the same, so no ledger row moves or changes.

  Authorization: a user only sees their own group's data. Non-members get
  `:not_found` (existence is never leaked); a member acting beyond their role
  gets `:forbidden`. Everything that writes sessions, costs, bills or the
  ledger is host-only.

  Accounts meet rosters here: `link_members_by_phone/1` attaches entries added by
  phone number to a login, `hosts_active_group?/1` and `anonymize_roster/1` serve
  account deletion.
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Petepete.Accounts.{Scope, User}
  alias Petepete.Billing.{Bill, Session}
  alias Petepete.Groups.{Group, Member}
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

  @doc """
  Creates a group named and templated by the host, who becomes its host member.

  `attrs` is the request body (`"name"`, `"template"`, see `Petepete.Groups.Templates`);
  the rounding unit is the schema default, Rp1.000.
  """
  @spec create_group(Scope.t(), map()) ::
          {:ok, %{group: Group.t(), host: Member.t()}} | {:error, Ecto.Changeset.t()}
  def create_group(%Scope{user: user}, attrs) when is_map(attrs) do
    Multi.new()
    |> Multi.insert(:group, Group.create_changeset(%Group{}, attrs))
    |> Multi.insert(:host, fn %{group: group} ->
      %Member{group_id: group.id, user_id: user.id, role: "host"}
      |> Member.roster_changeset(%{display_name: host_name(user), phone: user.phone})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, :group, changeset, _} -> {:error, changeset}
    end
  end

  defp host_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp host_name(_user), do: "Host"

  @doc "The web join link of the group's current invite token."
  @spec invite_url(Group.t()) :: String.t()
  def invite_url(%Group{invite_token: token}) do
    base = :petepete |> Application.fetch_env!(:web_base_url) |> String.trim_trailing("/")
    base <> "/join/" <> token
  end

  @doc "Replaces the invite token; the old link stops working. Host only."
  @spec reset_invite(Member.t()) :: {:ok, Group.t()}
  def reset_invite(%Member{role: "host", group_id: group_id}) do
    Group
    |> Repo.get!(group_id)
    |> Ecto.Changeset.change(invite_token: Group.new_invite_token())
    |> Repo.update()
  end

  @doc """
  Joins the group behind `token` as a member. `attrs` has `"display_name"` and optional `"phone"`.

  Without `scope` (web join) the new entry has no account; with it, the entry is linked
  to the caller's account and takes the account's phone. A caller already on the roster
  gets their existing entry back (`created: false`). An unknown or reset token is
  `{:error, :not_found}`.
  """
  @spec join(String.t(), map(), Scope.t() | nil) ::
          {:ok, %{group: Group.t(), member: Member.t(), created: boolean()}}
          | {:error, :not_found | Ecto.Changeset.t()}
  def join(token, attrs, scope \\ nil) when is_binary(token) and is_map(attrs) do
    case Repo.get_by(Group, invite_token: token) do
      nil -> {:error, :not_found}
      group -> join_group(group, attrs, scope)
    end
  end

  defp join_group(group, attrs, nil), do: insert_joiner(group, attrs, %Member{})

  defp join_group(group, attrs, %Scope{user: user}) do
    case Repo.get_by(Member, group_id: group.id, user_id: user.id) do
      %Member{} = member ->
        {:ok, %{group: group, member: member, created: false}}

      nil ->
        attrs = Map.put(attrs, "phone", user.phone)

        case insert_joiner(group, attrs, %Member{user_id: user.id}) do
          {:error, %Ecto.Changeset{errors: [user_id: _]}} ->
            join_group(group, attrs, %Scope{user: user})

          other ->
            other
        end
    end
  end

  defp insert_joiner(group, attrs, member) do
    %{member | group_id: group.id, role: "member"}
    |> Member.roster_changeset(Map.take(attrs, ["display_name", "phone"]))
    |> Repo.insert()
    |> case do
      {:ok, member} -> {:ok, %{group: group, member: member, created: true}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  The caller asks to be linked to roster entry `member_id`, an entry without an account.

  Sets `claim_user_id`; the host decides with `approve_claim/2` or `reject_claim/2`.
  Claiming again as the same user is a no-op.
  """
  @spec claim(Scope.t(), integer()) ::
          {:ok, Member.t()}
          | {:error, :not_found | {:conflict, :not_claimable | :already_member | :claim_pending}}
  def claim(%Scope{user: user}, member_id) when is_integer(member_id) do
    transact(fn ->
      member = lock_member(member_id) || Repo.rollback(:not_found)

      cond do
        member.user_id != nil ->
          Repo.rollback({:conflict, :not_claimable})

        member.claim_user_id not in [nil, user.id] ->
          Repo.rollback({:conflict, :claim_pending})

        Repo.exists?(
          from m in Member, where: m.group_id == ^member.group_id and m.user_id == ^user.id
        ) ->
          Repo.rollback({:conflict, :already_member})

        true ->
          member |> Ecto.Changeset.change(claim_user_id: user.id) |> Repo.update!()
      end
    end)
  end

  def claim(%Scope{}, _member_id), do: {:error, :not_found}

  @doc """
  The host links the claiming account to roster entry `member_id`.

  Only `group_members` changes: the entry keeps its id, so its ledger entries stay as they are.
  """
  @spec approve_claim(Scope.t(), integer()) ::
          {:ok, Member.t()}
          | {:error, :not_found | :forbidden | {:conflict, :no_claim | :already_member}}
  def approve_claim(%Scope{} = scope, member_id), do: decide_claim(scope, member_id, :approve)

  @doc "The host turns down the pending claim on roster entry `member_id`."
  @spec reject_claim(Scope.t(), integer()) ::
          {:ok, Member.t()} | {:error, :not_found | :forbidden | {:conflict, :no_claim}}
  def reject_claim(%Scope{} = scope, member_id), do: decide_claim(scope, member_id, :reject)

  defp decide_claim(scope, member_id, decision) do
    with group_id when is_integer(group_id) <- group_id_for(:member, member_id),
         {:ok, _host} <- authorize(scope, group_id, :host) do
      transact(fn ->
        member = lock_member(member_id) || Repo.rollback(:not_found)
        member.claim_user_id || Repo.rollback({:conflict, :no_claim})

        changes =
          case decision do
            :approve -> [user_id: member.claim_user_id, claim_user_id: nil]
            :reject -> [claim_user_id: nil]
          end

        member
        |> Ecto.Changeset.change(changes)
        |> Ecto.Changeset.unique_constraint(:user_id, name: :group_members_group_id_user_id_index)
        |> Repo.update()
        |> case do
          {:ok, member} -> member
          {:error, _changeset} -> Repo.rollback({:conflict, :already_member})
        end
      end)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_member(id), do: Repo.one(from m in Member, where: m.id == ^id, lock: "FOR UPDATE")

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Adds a guest to the host's roster. `attrs` has `"name"` and optional `"phone"`.

  The guest is a roster entry like any other (role `guest`, no account), so it is
  listed by `get_group/1` and can be picked again in later sessions. Host only.
  """
  @spec add_guest(Member.t(), map()) :: {:ok, Member.t()} | {:error, Ecto.Changeset.t()}
  def add_guest(%Member{role: "host", group_id: group_id}, attrs) when is_map(attrs) do
    %Member{group_id: group_id, role: "guest"}
    |> Member.roster_changeset(%{
      "display_name" => Map.get(attrs, "name"),
      "phone" => Map.get(attrs, "phone")
    })
    |> Repo.insert()
    |> case do
      {:ok, guest} -> {:ok, guest}
      {:error, %Ecto.Changeset{} = cs} -> {:error, rename_error(cs, :display_name, :name)}
    end
  end

  defp rename_error(%Ecto.Changeset{errors: errors} = changeset, from, to) do
    %{
      changeset
      | errors:
          Enum.map(errors, fn
            {^from, error} -> {to, error}
            other -> other
          end)
    }
  end

  @doc """
  The group the viewer (an authorized roster entry) belongs to, with its roster.

  Only a host sees phones, pending claims and the invite link.
  """
  @spec get_group(Member.t()) :: %{group: Group.t(), members: [Member.t()], viewer: Member.t()}
  def get_group(%Member{group_id: group_id} = viewer) do
    members =
      Repo.all(
        from m in Member,
          where: m.group_id == ^group_id,
          order_by: m.id,
          preload: :claim_user
      )

    %{group: Repo.get!(Group, group_id), members: members, viewer: viewer}
  end

  @doc "The caller's groups, oldest first, each with the caller's roster entry."
  @spec list_groups(Scope.t()) :: [%{group: Group.t(), member: Member.t()}]
  def list_groups(%Scope{user: %{id: user_id}}) do
    Repo.all(
      from m in Member,
        join: g in assoc(m, :group),
        where: m.user_id == ^user_id,
        order_by: g.id,
        select: %{group: g, member: m}
    )
  end

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
