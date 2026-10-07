defmodule Petepete.Fixtures do
  @moduledoc """
  Test fixtures built by direct Repo inserts of the schemas (no business logic).

  One attrs-based family: every `*_fixture` takes its parent record(s) and an `attrs`
  keyword list or map. Unknown attrs are struct fields of the inserted schema, so they
  override the defaults. Exceptions are noted per function (`member_fixture/2` accepts
  `:role` and `:user`).

    * `user_fixture/1`, `group_fixture/1`
    * `member_fixture/2`, `event_fixture/2`, `payout_account_fixture/3`
    * `session_fixture/2` takes the event (the group is derived from it);
      `group_event_session_fixture/1` builds all three and returns `{group, event, session}`
    * `bill_fixture/3`, `attendance_fixture/3`, `cost_item_fixture/2`
    * `host_fixture/1`, `plain_member_fixture/1`, `guest_fixture/1`: `{user, member}` helpers
    * `host_actor/2`: the host `Petepete.Actor` for a host member (production code gets it
      from `Groups.authorize_actor/3`)
    * `bearer_login/1`, `bearer_conn/2`, `valid_phone/0`: HTTP login helpers
  """
  alias Petepete.Accounts.User
  alias Petepete.Actor
  alias Petepete.Billing.{Bill, Session}
  alias Petepete.Groups.{Group, Member, PayoutAccount}
  alias Petepete.Repo
  alias Petepete.Sessions.Event

  def uniq, do: System.unique_integer([:positive])

  def user_fixture(attrs \\ []) do
    n = uniq()
    Repo.insert!(struct!(%User{phone: "62812#{n}", display_name: "User #{n}"}, attrs))
  end

  def group_fixture(attrs \\ []) do
    n = uniq()
    Repo.insert!(struct!(%Group{name: "Group #{n}", invite_token: "inv-#{n}"}, attrs))
  end

  @doc """
  A roster entry. `:role` (`"host" | "member" | "guest"`, default `"member"`) and `:user`
  (a `User`, links the account) are special; any other attr is a `Member` field.
  """
  def member_fixture(group, attrs \\ []) do
    {role, attrs} = attrs |> Map.new() |> Map.pop(:role, "member")
    {user, attrs} = Map.pop(attrs, :user)

    Repo.insert!(
      struct!(
        %Member{
          group_id: group.id,
          user_id: user && user.id,
          role: role,
          display_name: "Member #{uniq()}"
        },
        attrs
      )
    )
  end

  @doc "Returns `{user, member}` with role host in `group`."
  def host_fixture(group), do: user_member(group, "host")
  @doc "Returns `{user, member}` with role member in `group`."
  def plain_member_fixture(group), do: user_member(group, "member")
  @doc "Returns `{user, member}` with role guest in `group`."
  def guest_fixture(group), do: user_member(group, "guest")

  @doc """
  The host `Petepete.Actor` of `host_member` in `group`, without going through
  `Groups.authorize_actor/3`. Raises unless `host_member` is a linked host of `group`.
  """
  def host_actor(%Group{id: group_id}, %Member{
        id: member_id,
        group_id: group_id,
        role: "host",
        user_id: user_id
      })
      when is_integer(user_id),
      do: %Actor{type: :host, user_id: user_id, member_id: member_id}

  defp user_member(group, role) do
    user = user_fixture()
    {user, member_fixture(group, role: role, user: user)}
  end

  def event_fixture(group, attrs \\ []) do
    Repo.insert!(
      struct!(
        %Event{
          group_id: group.id,
          name: "Event #{uniq()}",
          type: "one_off",
          starts_at: ~U[2026-10-08 12:00:00Z]
        },
        attrs
      )
    )
  end

  @doc "A session of `event` (its group is `event.group_id`)."
  def session_fixture(event, attrs \\ []) do
    Repo.insert!(
      struct!(
        %Session{
          event_id: event.id,
          group_id: event.group_id,
          starts_at: ~U[2026-10-08 12:00:00Z]
        },
        attrs
      )
    )
  end

  @doc "A group with an event and a session (`attrs` go to the session): `{group, event, session}`."
  def group_event_session_fixture(attrs \\ []) do
    group = group_fixture()
    event = event_fixture(group)
    {group, event, session_fixture(event, attrs)}
  end

  def bill_fixture(session, member, attrs \\ []) do
    Repo.insert!(
      struct!(
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

  def payout_account_fixture(group, owner, attrs \\ []) do
    Repo.insert!(
      struct!(
        %PayoutAccount{
          group_id: group.id,
          owner_member_id: owner.id,
          provider: "fake",
          provider_account_id: "acc#{uniq()}",
          idempotency_key: "pa-#{uniq()}",
          status: "active"
        },
        attrs
      )
    )
  end

  @doc """
  Logs a fresh user in through the OTP endpoints (fake sender) and returns
  `{conn_with_bearer_token, user}`. Uses a fresh client IP so the per-IP OTP limit never trips.
  """
  def bearer_login(conn) do
    import ExUnit.Assertions
    import Phoenix.ConnTest
    import Plug.Conn

    n = uniq()

    phone =
      "628" <> (n |> rem(1_000_000_000) |> Integer.to_string() |> String.pad_leading(9, "0"))

    ip = {10, 8, rem(n, 250), rem(div(n, 250), 250)}
    endpoint = PetepeteWeb.Endpoint

    assert %{"ok" => true} =
             conn
             |> Map.put(:remote_ip, ip)
             |> dispatch(endpoint, :post, "/api/auth/otp", %{phone: phone})
             |> json_response(200)

    assert_received {:otp_sent, _, code}

    assert %{"access_token" => token, "user" => %{"id" => user_id}} =
             conn
             |> Map.put(:remote_ip, ip)
             |> dispatch(endpoint, :post, "/api/auth/verify", %{phone: phone, code: code})
             |> json_response(200)

    user =
      Repo.get!(User, user_id)
      |> Ecto.Changeset.change(display_name: "Tester #{n}")
      |> Repo.update!()

    {put_req_header(conn, "authorization", "Bearer " <> token), user}
  end

  @doc "Marks `member` as attended (default) or absent at `session`, with `weight` per mil (default 1000)."
  def attendance_fixture(session, member, attrs \\ []) do
    Repo.insert!(
      struct(
        %Petepete.Billing.Participant{
          session_id: session.id,
          member_id: member.id,
          attended: true,
          weight: 1000
        },
        attrs
      )
    )
  end

  @doc """
  A cost item of `session`. `attrs`: `:amount` (required), `:paid_by` (member, required),
  `:category`, `:label`; `:members` (list of members) makes it a subset item.
  """
  def cost_item_fixture(session, attrs) do
    attrs = Map.new(attrs)
    members = Map.get(attrs, :members)

    item =
      Repo.insert!(%Petepete.Billing.CostItem{
        session_id: session.id,
        category: Map.get(attrs, :category, "lapangan"),
        label: Map.get(attrs, :label),
        amount: Map.fetch!(attrs, :amount),
        paid_by_member_id: Map.fetch!(attrs, :paid_by).id,
        scope: if(members, do: "subset", else: "all")
      })

    for member <- members || [] do
      Repo.insert!(%Petepete.Billing.CostItemMember{cost_item_id: item.id, member_id: member.id})
    end

    item
  end

  @doc "A phone number that passes `Accounts.normalize_phone/1`, unique per call."
  def valid_phone do
    "628" <> (uniq() |> rem(1_000_000_000) |> Integer.to_string() |> String.pad_leading(9, "0"))
  end

  @doc """
  `conn` carrying a valid access token for `user`, obtained through the real OTP login
  (`user.phone` must be a `valid_phone/0`). The fake OTP sender messages the caller.
  """
  def bearer_conn(conn, user) do
    endpoint = PetepeteWeb.Endpoint

    Phoenix.ConnTest.dispatch(conn, endpoint, :post, "/api/auth/otp", %{phone: user.phone})
    code = receive do: ({:otp_sent, _phone, code} -> code)

    %{"access_token" => token} =
      conn
      |> Phoenix.ConnTest.dispatch(endpoint, :post, "/api/auth/verify", %{
        phone: user.phone,
        code: code
      })
      |> Phoenix.ConnTest.json_response(200)

    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
  end
end
