defmodule Petepete.HostAction do
  @moduledoc """
  The one wrapper every host action that changes money runs through (ADR-0003).

      HostAction.run(actor, group_id, "settlement.record", fn ->
        with {:ok, %{txn: txn, replayed: replayed} = result} <- Ledger.record(actor, event) do
          {:ok, result, %{subject: {"txn", txn.id}, metadata: %{...}, replayed: replayed}}
        end
      end)

  `run/4` owns the database transaction, so `fun` (and the `Ledger.record/2` calls inside it,
  ADR-0002) commit or roll back together with the `audit_log` row:

    * `fun` returns `{:ok, result, %{subject: {type, id}, metadata: map, replayed: boolean}}`:
      the audit row is written with `actor.user_id`, `group_id`, `action`, `subject` and
      `metadata` unless `replayed` is `true` (an idempotent replay did nothing new), and
      `run/4` returns `{:ok, result}`.
    * `fun` returns `{:error, reason}`: the transaction rolls back (nothing is audited) and
      `run/4` returns `{:error, reason}`.
    * `fun` raises: the transaction rolls back and the exception propagates.

  Authorization happened at the HTTP edge: only a host `Petepete.Actor` (from
  `Petepete.Groups.Policy.authorize_actor/3`) is accepted; any other Actor is a
  `FunctionClauseError`. The wrapper does not own the idempotency key: callers put it on
  their own Ledger event, and `PetepeteWeb.Plugs.IdempotencyKey` makes it mandatory on every
  host money route. `metadata` is plain JSON data and never holds phone numbers.

  This is the only caller of `Petepete.Ledger.Audit.record/5`.
  """
  alias Petepete.Actor
  alias Petepete.Ledger.Audit
  alias Petepete.Repo

  @type subject :: {String.t(), pos_integer()}
  @type audit :: %{subject: subject(), metadata: map(), replayed: boolean()}

  @spec run(Actor.t(), pos_integer(), String.t(), (-> {:ok, result, audit()} | {:error, term()})) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def run(%Actor{type: :host, user_id: user_id}, group_id, action, fun)
      when is_integer(user_id) and is_integer(group_id) and is_binary(action) and
             is_function(fun, 0) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result, %{subject: subject, metadata: metadata, replayed: replayed}}
        when is_boolean(replayed) ->
          unless replayed do
            Audit.record(group_id, user_id, action, subject, metadata)
          end

          result

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end
end
