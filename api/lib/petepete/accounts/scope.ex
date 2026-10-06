defmodule Petepete.Accounts.Scope do
  @moduledoc "The authenticated caller of a request: the logged-in user."
  alias Petepete.Accounts.User

  defstruct user: nil

  @type t :: %__MODULE__{user: User.t()}

  @spec for(User.t()) :: t()
  def for(%User{} = user), do: %__MODULE__{user: user}
end
