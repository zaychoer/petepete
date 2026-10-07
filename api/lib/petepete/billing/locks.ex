defmodule Petepete.Billing.Locks do
  @moduledoc """
  Row locks for Billing commands, in the spec's fixed order: the session row, then the
  bill rows ordered by id, then (always last) the Ledger group lock taken by
  `Ledger.record/2` itself.

  Commands that change a session's money state (`issue`, `void_issue`, cost and
  attendance edits) lock the session; `mark_paid_cash`, `cancel_cash` and gateway
  payments lock only their bill(s) and never the session row. A command that needs both
  MUST take the session first, which `lock_session_and_bills/1` does.

  All functions must run inside the caller's transaction (the lock is released at its
  end) and raise otherwise.
  """

  import Ecto.Query, only: [from: 2]

  alias Petepete.Billing.{Bill, Session}
  alias Petepete.Repo

  @doc "`SELECT ... FOR UPDATE` on one session row."
  @spec lock_session(pos_integer()) :: {:ok, %Session{}} | {:error, :not_found}
  def lock_session(session_id) when is_integer(session_id) do
    ensure_in_transaction!()

    case Repo.one(from s in Session, where: s.id == ^session_id, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  `SELECT ... FOR UPDATE` on the given bills, acquired in ascending id order whatever
  the order of `bill_ids`. Returns the bills in that order; unknown ids are absent.
  """
  @spec lock_bills([pos_integer()]) :: [%Bill{}]
  def lock_bills(bill_ids) when is_list(bill_ids) do
    ensure_in_transaction!()

    Repo.all(
      from b in Bill, where: b.id in ^Enum.uniq(bill_ids), order_by: b.id, lock: "FOR UPDATE"
    )
  end

  @doc """
  Locks the session, then every bill of that session (void ones included) by id.
  This is the lock prefix of `issue` and `void_issue`.
  """
  @spec lock_session_and_bills(pos_integer()) ::
          {:ok, %Session{}, [%Bill{}]} | {:error, :not_found}
  def lock_session_and_bills(session_id) do
    with {:ok, session} <- lock_session(session_id) do
      bill_ids = Repo.all(from b in Bill, where: b.session_id == ^session.id, select: b.id)
      {:ok, session, lock_bills(bill_ids)}
    end
  end

  defp ensure_in_transaction! do
    Repo.in_transaction?() ||
      raise ArgumentError, "Billing locks must be taken inside the caller's transaction"
  end
end
