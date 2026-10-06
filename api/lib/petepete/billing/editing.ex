defmodule Petepete.Billing.Editing do
  @moduledoc """
  The common prefix of every host command that edits a draft session (costs and
  attendance): one transaction that locks the session row first and only then checks the
  session is still a draft.

  The caller is a host `Petepete.Actor`: the HTTP edge (`PetepeteWeb.Plugs.SessionAccess`
  with `role: :host`) already authorized it as host of the session's group, so nothing is
  checked here (ADR-0003). These are host writes that do not change money: no audit row.
  """

  alias Petepete.Actor
  alias Petepete.Billing
  alias Petepete.Billing.Locks
  alias Petepete.Repo

  @doc """
  Runs `fun.(session, actor)` inside a transaction with the session locked.
  `fun` returns `{:ok, value}` or `{:error, reason}`; an error rolls everything back.
  Returns `{:error, :not_found | {:session_not_editable, status}}` before `fun` runs when
  the prefix fails.
  """
  @spec run(Actor.t(), integer(), (struct(), Actor.t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def run(%Actor{type: :host} = actor, session_id, fun) when is_function(fun, 2) do
    Repo.transaction(fn ->
      with {:ok, session} <- lock(session_id),
           :ok <- Billing.ensure_editable(session),
           {:ok, value} <- fun.(session, actor) do
        value
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock(session_id) when is_integer(session_id), do: Locks.lock_session(session_id)
  defp lock(_), do: {:error, :not_found}
end
