defmodule Petepete.Repo.Migrations.AllowPendingFailedWithdrawals do
  use Ecto.Migration

  # A withdrawal is committed as `pending` before the gateway is called and ends `failed`
  # when the gateway refuses it.
  def up do
    drop constraint(:withdrawals, :status_allowed)

    create constraint(:withdrawals, :status_allowed,
             check: "status IN ('pending', 'submitted', 'managed', 'failed')"
           )
  end

  def down do
    drop constraint(:withdrawals, :status_allowed)

    create constraint(:withdrawals, :status_allowed, check: "status IN ('submitted', 'managed')")
  end
end
