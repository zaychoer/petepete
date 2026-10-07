defmodule Petepete.Ledger.Audit do
  @moduledoc """
  The low-level writer of `audit_log` rows: one per host action that changes money.

  Only `Petepete.HostAction.run/4` may call `record/5` (ADR-0003; a test greps `lib/` for
  other callers). HostAction runs it inside the money change's transaction and skips it for
  an idempotent replay, so the row commits and rolls back together with the action.
  Everything else goes through `HostAction.run/4`; never call this directly.

  Metadata is plain JSON data (ids, rupiah, reason); never put phone numbers in it.
  """
  alias Petepete.Ledger.AuditLog
  alias Petepete.Repo

  @doc """
  Inserts the audit row and returns it. `subject` is `{type, id}`, e.g. `{"txn", 12}`.
  Raises outside a transaction.
  """
  @spec record(pos_integer(), pos_integer(), String.t(), {String.t(), pos_integer()}, map()) ::
          AuditLog.t()
  def record(group_id, actor_user_id, action, {subject_type, subject_id}, metadata \\ %{})
      when is_integer(group_id) and is_integer(actor_user_id) and is_binary(action) and
             is_binary(subject_type) and is_integer(subject_id) and is_map(metadata) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "Audit.record/5 must run inside the money change's transaction"
    end

    Repo.insert!(%AuditLog{
      group_id: group_id,
      actor_user_id: actor_user_id,
      action: action,
      subject_type: subject_type,
      subject_id: subject_id,
      metadata: metadata
    })
  end
end
