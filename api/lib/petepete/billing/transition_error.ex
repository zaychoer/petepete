defmodule Petepete.Billing.TransitionError do
  @moduledoc """
  Returned (as `{:error, %TransitionError{}}`) when a session or bill status change
  is not in the spec's state diagram, or is attempted by a command that does not own it.

  `from` is `nil` for creation. `trigger` is the Billing command that tried the change.
  """
  defexception [:entity, :from, :to, :trigger]

  @type t :: %__MODULE__{
          entity: :session | :bill,
          from: String.t() | nil,
          to: String.t(),
          trigger: atom()
        }

  @impl true
  def message(%{entity: entity, from: from, to: to, trigger: trigger}) do
    "#{entity} transition #{inspect(from)} -> #{inspect(to)} by #{inspect(trigger)} is not allowed"
  end
end
