defmodule Petepete.Sessions do
  @moduledoc """
  Scheduling only: events, their recurrence and creating draft sessions.

  Schema: `Petepete.Sessions.Event` (`events`). The `sessions` table itself is
  owned by Billing (`Petepete.Billing.Session`), which holds session status.
  """
end
