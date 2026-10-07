defmodule Petepete.Billing.Editing do
  @moduledoc """
  The common prefix of every host command that edits a draft session (costs and
  attendance): one transaction that locks the session row first, authorizes the caller as
  the host of the session's group, and only then checks the session is still a draft.

  Authorizing before the status check means a non-member learns nothing about the
  session, not even its status.
  """

  alias Petepete.Accounts.Scope
  alias Petepete.Billing
  alias Petepete.Billing.Locks
  alias Petepete.Groups
  alias Petepete.Repo

  @doc """
  Runs `fun.(session, host_member)` inside a transaction with the session locked.
  `fun` returns `{:ok, value}` or `{:error, reason}`; an error rolls everything back.
  Returns `{:error, :not_found | :forbidden | {:session_not_editable, status}}` before
  `fun` runs when the prefix fails.
  """
  @spec run(Scope.t(), integer(), (struct(), struct() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def run(%Scope{} = scope, session_id, fun) when is_function(fun, 2) do
    Repo.transaction(fn ->
      with {:ok, session} <- lock(session_id),
           {:ok, host} <- Groups.authorize(scope, session.group_id, :host),
           :ok <- Billing.ensure_editable(session),
           {:ok, value} <- fun.(session, host) do
        value
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock(session_id) when is_integer(session_id), do: Locks.lock_session(session_id)
  defp lock(_), do: {:error, :not_found}
end
