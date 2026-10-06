defmodule Petepete.Fixtures do
  @moduledoc "Test fixtures built by direct Repo inserts of the schemas. Parallel tickets append new functions at the end."
  alias Petepete.Accounts.User
  alias Petepete.Billing.{Bill, Session}
  alias Petepete.Groups.{Group, Member, PayoutAccount}
  alias Petepete.Repo
  alias Petepete.Sessions.Event

  def uniq, do: System.unique_integer([:positive])

  def user_fixture(attrs \\ %{}) do
    n = uniq()

    Repo.insert!(
      struct!(User, Map.merge(%{phone: "62812#{n}", display_name: "User #{n}"}, Map.new(attrs)))
    )
  end

  def group_fixture(attrs \\ %{}) do
    n = uniq()

    Repo.insert!(
      struct!(Group, Map.merge(%{name: "Group #{n}", invite_token: "inv-#{n}"}, Map.new(attrs)))
    )
  end

  @doc "A roster entry. `role` is `\"host\" | \"member\" | \"guest\"`; `user` links an account (optional)."
  def member_fixture(group, role, user \\ nil) do
    Repo.insert!(%Member{
      group_id: group.id,
      user_id: user && user.id,
      role: role,
      display_name: "Member #{uniq()}"
    })
  end

  @doc "Returns `{user, member}` with `role` host/member/guest in `group`."
  def host_fixture(group), do: user_member(group, "host")
  def plain_member_fixture(group), do: user_member(group, "member")
  def guest_fixture(group), do: user_member(group, "guest")

  defp user_member(group, role) do
    user = user_fixture()
    {user, member_fixture(group, role, user)}
  end

  def event_fixture(group, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        Event,
        Map.merge(%{group_id: group.id, name: "Event #{uniq()}", type: "one_off"}, Map.new(attrs))
      )
    )
  end

  def session_fixture(group, attrs \\ %{}) do
    attrs = Map.new(attrs)
    event = Map.get_lazy(attrs, :event, fn -> event_fixture(group) end)

    Repo.insert!(
      struct!(
        Session,
        Map.merge(
          %{
            group_id: group.id,
            event_id: event.id,
            starts_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          Map.delete(attrs, :event)
        )
      )
    )
  end

  def bill_fixture(session, member, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        Bill,
        Map.merge(
          %{
            session_id: session.id,
            member_id: member.id,
            share: 10_000,
            amount_due: 10_000,
            pay_token: "pay-#{uniq()}",
            token_expires_at:
              DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)
          },
          Map.new(attrs)
        )
      )
    )
  end

  def group!(attrs \\ []) do
    Repo.insert!(struct(%Group{name: "Futsal", invite_token: "inv#{uniq()}"}, attrs))
  end

  def member!(group, attrs \\ []) do
    Repo.insert!(
      struct(%Member{group_id: group.id, display_name: "M#{uniq()}", role: "member"}, attrs)
    )
  end

  def event!(group, attrs \\ []) do
    Repo.insert!(
      struct(
        %Event{
          group_id: group.id,
          name: "Futsal Kamis",
          type: "one_off",
          starts_at: ~U[2026-10-08 12:00:00Z]
        },
        attrs
      )
    )
  end

  def session!(event, attrs \\ []) do
    Repo.insert!(
      struct(
        %Session{
          event_id: event.id,
          group_id: event.group_id,
          starts_at: ~U[2026-10-08 12:00:00Z]
        },
        attrs
      )
    )
  end

  def bill!(session, member, attrs \\ []) do
    Repo.insert!(
      struct(
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

  @doc "A draft session with its event and group, plus the members passed in `:members` names."
  def session_with_group!(attrs \\ []) do
    group = group!()
    event = event!(group)
    {group, event, session!(event, attrs)}
  end

  def user!(attrs \\ []) do
    Repo.insert!(struct(%User{phone: "62#{uniq()}", display_name: "User#{uniq()}"}, attrs))
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
