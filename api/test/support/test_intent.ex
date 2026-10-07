defmodule Petepete.TestIntent do
  @moduledoc """
  Test-only in-memory intent module implementing `OutboundIntent`.

  Uses an Agent to store intent rows as maps. Tests call `start/1` in setup
  and interact through the behaviour callbacks. Allows configuring request
  outcomes and stuck/recover behaviour.
  """
  @behaviour Petepete.Payments.OutboundIntent

  use Ecto.Schema

  # A minimal schema backed by the `payment_attempts` table so IntentRunner's
  # Repo operations (increment_retry_count) work against a real table.
  schema "payment_attempts" do
    belongs_to :bill, Petepete.Billing.Bill
    field :external_id, :string
    field :status, :string, default: "pending"
    field :retry_count, :integer, default: 0
    field :provider_ref, :string
    field :seq, :integer
    field :provider, :string
    field :method, :string
    field :amount_due, :integer
    field :fee, :integer
    field :gross_amount, :integer
    field :paid_amount, :integer
    field :action, :map
    field :expires_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc "Start the agent. `opts`: `:request_result`, `:recover_action`, `:stuck_rows`."
  def start(opts \\ []) do
    {:ok, pid} = Agent.start_link(fn -> %{opts: opts, rows: %{}} end, name: __MODULE__)
    pid
  end

  def stop do
    if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
  end

  def configure(new_opts) do
    Agent.update(__MODULE__, fn state ->
      %{state | opts: Keyword.merge(state.opts, new_opts)}
    end)
  end

  def get_row(id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.rows, id) end)
  end

  # -- OutboundIntent callbacks --

  @impl true
  def kind, do: "test_intent"

  @impl true
  def prepare(%{ref: ref} = args) do
    bill_id = Map.get(args, :bill_id, 1)

    # Check for existing row with this ref (replay)
    existing =
      Agent.get(__MODULE__, fn state ->
        Enum.find_value(state.rows, fn {_id, row} ->
          if row.external_id == ref, do: row
        end)
      end)

    case existing do
      nil ->
        # Insert a real row into payment_attempts so Repo operations work
        row =
          %__MODULE__{}
          |> Ecto.Changeset.change(%{
            external_id: ref,
            status: "pending",
            retry_count: 0,
            bill_id: bill_id,
            seq: System.unique_integer([:positive]),
            provider: "fake",
            method: "qris",
            amount_due: 100,
            fee: 0,
            gross_amount: 100
          })
          |> Petepete.Repo.insert!()

        Agent.update(__MODULE__, fn state ->
          %{state | rows: Map.put(state.rows, row.id, row)}
        end)

        {:ok, row, ref}

      row ->
        {:ok, row, ref}
    end
  end

  @impl true
  def request(_row, _reference) do
    opts = Agent.get(__MODULE__, fn state -> state.opts end)

    case Keyword.get(opts, :request_result, {:ok, %{provider_ref: "test-ref-123"}}) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def settle(row, result) do
    # Map to statuses valid for the payment_attempts check constraint:
    # 'pending', 'paid', 'expired', 'failed', 'cancelled'
    {new_status, changes} =
      case result do
        {:ok, data} ->
          {"paid", Map.merge(%{provider_ref: data[:provider_ref]}, data)}

        {:error, :max_retries_exceeded} ->
          {"failed", %{}}

        {:error, :needs_review} ->
          # Use "expired" to represent needs_review within payment_attempts constraints
          {"expired", %{}}

        {:error, :stuck_failed} ->
          {"failed", %{}}

        {:error, _reason} ->
          {"failed", %{}}
      end

    # Only keep keys that are actual schema fields
    safe_changes =
      changes
      |> Map.take([:provider_ref])
      |> Map.put(:status, new_status)

    updated =
      row.__struct__
      |> Petepete.Repo.get!(row.id)
      |> Ecto.Changeset.change(safe_changes)
      |> Petepete.Repo.update!()

    Agent.update(__MODULE__, fn state ->
      %{state | rows: Map.put(state.rows, updated.id, updated)}
    end)

    {:ok, updated}
  end

  @impl true
  def stuck(_threshold) do
    Agent.get(__MODULE__, fn state ->
      Keyword.get(state.opts, :stuck_rows, [])
    end)
  end

  @impl true
  def recover(_row) do
    opts = Agent.get(__MODULE__, fn state -> state.opts end)
    Keyword.get(opts, :recover_action, :redrive)
  end

  @doc "Derive reference from row for redrive."
  def reference_from_row(row), do: row.external_id
end
