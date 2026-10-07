defmodule PetepeteWeb.LedgerController do
  @moduledoc """
  Kas & riwayat: balances and history (any member of the group), plus the host-only
  money entries `settlements`, `kas-spends` and `correction`.

  Writes need `Idempotency-Key`, post through `Petepete.Ledger.HostActions` and answer
  `{txn_id, replayed}` (201 when new, 200 for a replay of the same request).
  """
  use PetepeteWeb, :controller

  alias Petepete.{Ledger, Repo}
  alias Petepete.Groups.Member
  alias Petepete.Ledger.{Description, HostActions}
  alias PetepeteWeb.LedgerError
  alias PetepeteWeb.Plugs.{GroupAccess, IdempotencyKey, TxnAccess}

  import Ecto.Query, only: [from: 2]

  plug GroupAccess, [role: :host] when action in [:settlement, :kas_spend]
  plug GroupAccess, [role: :member] when action in [:balances, :txns]
  plug TxnAccess, [role: :host] when action == :correction
  plug IdempotencyKey when action in [:settlement, :kas_spend, :correction]

  def settlement(conn, params) do
    with {:ok, p} <-
           parse(params, %{
             "from_member_id" => {:payer_member_id, :id},
             "to_member_id" => {:payee_member_id, :id},
             "amount" => {:amount, :int},
             "note" => {:note, :opt_string}
           }) do
      conn.assigns.actor
      |> HostActions.record_settlement(conn.assigns.group_id, conn.assigns.idempotency_key, p)
      |> respond(conn)
    else
      {:error, details} -> LedgerError.render_invalid(conn, details)
    end
  end

  def kas_spend(conn, params) do
    with {:ok, p} <-
           parse(params, %{
             "member_id" => {:member_id, :id},
             "amount" => {:amount, :int},
             "note" => {:note, :opt_string}
           }) do
      conn.assigns.actor
      |> HostActions.record_kas_spend(conn.assigns.group_id, conn.assigns.idempotency_key, p)
      |> respond(conn)
    else
      {:error, details} -> LedgerError.render_invalid(conn, details)
    end
  end

  def correction(conn, params) do
    with {:ok, p} <- parse(params, %{"reason" => {:reason, :opt_string}}) do
      conn.assigns.actor
      |> HostActions.correct(
        conn.assigns.group_id,
        conn.assigns.idempotency_key,
        conn.assigns.txn_id,
        p[:reason]
      )
      |> respond(conn)
    else
      {:error, details} -> LedgerError.render_invalid(conn, details)
    end
  end

  def balances(conn, _params) do
    group_id = conn.assigns.group_id
    balances = Ledger.balances(group_id)
    names = names(group_id)

    json(conn, %{
      kas: balances.kas,
      members:
        balances.members
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {id, balance} ->
          %{member_id: id, display_name: Map.get(names, id), balance: balance}
        end)
    })
  end

  def txns(conn, params) do
    group_id = conn.assigns.group_id

    with {:ok, opts} <- member_filter(params) do
      names = names(group_id)
      txns = Ledger.txns(group_id, opts)
      json(conn, %{txns: Enum.map(txns, &txn_json(&1, names, txns))})
    else
      {:error, details} -> LedgerError.render_invalid(conn, details)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp respond({:ok, %{txn: txn, replayed: replayed}}, conn) do
    conn
    |> put_status(if replayed, do: 200, else: 201)
    |> json(%{txn_id: txn.id, replayed: replayed})
  end

  defp respond({:error, reason}, conn), do: LedgerError.render(conn, reason)

  defp names(group_id) do
    from(m in Member, where: m.group_id == ^group_id, select: {m.id, m.display_name})
    |> Repo.all()
    |> Map.new()
  end

  defp member_filter(%{"member_id" => raw}) do
    case Integer.parse(to_string(raw)) do
      {id, ""} -> {:ok, [member_id: id]}
      _ -> {:error, %{"member_id" => "harus angka"}}
    end
  end

  defp member_filter(_), do: {:ok, []}

  defp txn_json(txn, names, all) do
    %{
      id: txn.id,
      kind: txn.kind,
      description: Description.of(txn, names, all),
      reason: txn.reason,
      reverses_txn_id: txn.reverses_txn_id,
      actor_type: txn.actor_type,
      inserted_at: txn.inserted_at,
      entries:
        Enum.map(txn.entries, fn e ->
          %{
            account_type: e.account_type,
            member_id: e.member_id,
            display_name: e.member_id && Map.get(names, e.member_id),
            amount: e.amount
          }
        end)
    }
  end

  # Strict body parsing: integers must be JSON integers, never numeric strings or floats.
  defp parse(params, spec) do
    {ok, errors} =
      Enum.reduce(spec, {%{}, %{}}, fn {field, {key, type}}, {ok, errors} ->
        case cast(type, Map.get(params, field)) do
          {:ok, nil} -> {ok, errors}
          {:ok, value} -> {Map.put(ok, key, value), errors}
          :error -> {ok, Map.put(errors, field, "tidak valid")}
        end
      end)

    required = for {field, {key, type}} <- spec, type in [:id, :int], do: {field, key}

    errors =
      Enum.reduce(required, errors, fn {field, key}, errs ->
        if Map.has_key?(ok, key), do: errs, else: Map.put_new(errs, field, "wajib diisi")
      end)

    if errors == %{}, do: {:ok, ok}, else: {:error, errors}
  end

  defp cast(_type, nil), do: {:ok, nil}
  defp cast(type, v) when type in [:id, :int] and is_integer(v), do: {:ok, v}
  defp cast(:opt_string, v) when is_binary(v), do: {:ok, v}
  defp cast(_, _), do: :error
end
