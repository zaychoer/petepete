defmodule Petepete.Ledger do
  @moduledoc """
  A group's append-only double-entry record of money events.

  Schemas: `Petepete.Ledger.Txn` (`ledger_txns`), `Petepete.Ledger.Entry`
  (`ledger_entries`) and `Petepete.Ledger.AuditLog` (`audit_log`, host money actions).
  The database enforces zero-sum per txn (deferred constraint trigger) and rejects
  UPDATE/DELETE on txns and entries.
  """
end
