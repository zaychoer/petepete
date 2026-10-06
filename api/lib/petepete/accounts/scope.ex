defmodule Petepete.Accounts.Scope do
  @moduledoc """
  Who is calling: the logged-in user behind a request.

  Context functions that need authorization take a scope as first argument.
  """

  alias Petepete.Accounts.User

  @enforce_keys [:user]
  defstruct [:user]

  @type t :: %__MODULE__{user: User.t()}

  @doc "Builds the scope of `user`."
  @spec for(User.t()) :: t()
  def for(%User{} = user), do: %__MODULE__{user: user}
end
