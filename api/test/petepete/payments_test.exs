defmodule Petepete.PaymentsTest do
  # Not async: some tests swap global application config.
  use Petepete.DataCase, async: false

  import Petepete.Fixtures

  alias Petepete.Groups.PayoutAccount
  alias Petepete.Ledger.AuditLog
  alias Petepete.Payments
  alias Petepete.Payments.Gateway.Fake

  @bank %{
    bank_name: "BCA",
    account_number: "1234 5678 9012",
    account_holder_name: "Budi Santoso"
  }

  defp put_env!(key, value) do
    old = Application.fetch_env!(:petepete, key)
    Application.put_env(:petepete, key, value)
    on_exit(fn -> Application.put_env(:petepete, key, old) end)
  end

  defp put_fake!(key, value) do
    put_env!(Fake, Keyword.put(Application.fetch_env!(:petepete, Fake), key, value))
  end

  describe "fee_for/2" do
    test "the host nets exactly amount_due for every method and amount" do
      for method <- ["qris", "va", "ewallet"],
          amount_due <- [1, 500, 4_999, 15_000, 45_000, 1_234_567] do
        assert {:ok, fee} = Payments.fee_for(method, amount_due)
        assert fee >= 0
        gross = amount_due + fee
        assert {:ok, provider_fee} = Fake.provider_fee(method, gross)
        assert gross - provider_fee == amount_due, "#{method} #{amount_due}"
      end
    end

    test "a flat-fee method adds the flat fee, a percentage one grosses up" do
      assert {:ok, 4_440} = Payments.fee_for("va", 45_000)
      # 0.78%: grossing up 45_000 must cost more than 0.78% of 45_000 (351)
      assert {:ok, fee} = Payments.fee_for("qris", 45_000)
      assert fee > 351
    end

    test "rejects unknown methods and non-positive amounts" do
      assert {:error, :unsupported_method} = Payments.fee_for("cheque", 45_000)
      assert {:error, :invalid_amount} = Payments.fee_for("qris", 0)
      assert {:error, :invalid_amount} = Payments.fee_for("qris", -1_000)
    end
  end

  describe "register_payout_account/4" do
    setup do
      group = group_fixture()
      {_user, host} = host_fixture(group)
      {:ok, group: group, host: host, actor: host_actor(group, host)}
    end

    test "records a pending_kyc account with only the last four digits", %{
      group: g,
      host: h,
      actor: actor
    } do
      assert {:ok, %{payout_account: %PayoutAccount{} = account, replayed: false}} =
               Payments.register_payout_account(actor, g.id, "k1", @bank)

      assert account.group_id == g.id
      assert account.owner_member_id == h.id
      assert account.provider == "fake"
      assert account.provider_account_id == "fake-acct-g#{g.id}-m#{h.id}"
      assert account.status == "pending_kyc"
      assert account.bank_name == "BCA"
      assert account.account_last4 == "9012"
      assert Repo.get!(PayoutAccount, account.id) == account

      assert [%{action: "payout_account.register", subject_id: id, actor_user_id: user_id}] =
               Repo.all(AuditLog)

      assert id == account.id and user_id == actor.user_id
    end

    test "a repeated key returns the first account without a gateway call or audit row", %{
      group: g,
      actor: actor
    } do
      put_fake!(:notify, self())

      {:ok, %{payout_account: first, replayed: false}} =
        Payments.register_payout_account(actor, g.id, "same", @bank)

      assert_received {:fake_gateway, :register_payout_account, _}

      assert {:ok, %{payout_account: again, replayed: true}} =
               Payments.register_payout_account(actor, g.id, "same", @bank)

      assert again.id == first.id
      refute_received {:fake_gateway, :register_payout_account, _}
      assert Repo.aggregate(PayoutAccount, :count) == 1
      assert Repo.aggregate(AuditLog, :count) == 1
    end

    test "becomes active once the gateway reports KYC done", %{group: g, actor: actor} do
      {:ok, %{payout_account: account}} =
        Payments.register_payout_account(actor, g.id, "k1", @bank)

      assert {:ok, %{status: "active"}} = Payments.refresh_payout_account(account)
      assert Repo.get!(PayoutAccount, account.id).status == "active"
    end

    test "stays pending_kyc while the gateway says so", %{group: g, actor: actor} do
      put_fake!(:kyc_status, :pending_kyc)

      {:ok, %{payout_account: account}} =
        Payments.register_payout_account(actor, g.id, "k1", @bank)

      assert {:ok, %{status: "pending_kyc"}} = Payments.refresh_payout_account(account)
    end

    test "is active immediately when the gateway needs no KYC", %{group: g, actor: actor} do
      put_fake!(:register_status, :active)

      assert {:ok, %{payout_account: %{status: "active"}}} =
               Payments.register_payout_account(actor, g.id, "k1", @bank)
    end

    test "rejects incomplete or malformed bank details and creates nothing", %{
      group: g,
      actor: actor
    } do
      assert {:error, changeset} =
               Payments.register_payout_account(actor, g.id, "k1", %{
                 bank_name: "BCA",
                 account_number: "12ab"
               })

      errors = errors_on(changeset)
      assert errors.account_holder_name == ["can't be blank"]
      assert errors.account_number == ["must be digits only"]
      assert Repo.aggregate(PayoutAccount, :count) == 0
      assert Repo.aggregate(AuditLog, :count) == 0
    end
  end

  describe "adapter selection by config" do
    defmodule OtherGateway do
      @moduledoc false
      @behaviour Petepete.Payments.Gateway

      def provider, do: "other"
      def create_payment(_), do: {:error, :not_used}
      def verify_webhook(_, _), do: {:error, :invalid_signature}
      def normalize_webhook(_), do: {:error, :malformed_payload}
      def fee_for("qris", amount), do: {:ok, div(amount, 100)}
      def fee_for(_, _), do: {:error, :unsupported_method}
      def cancel_payment(_), do: {:error, :unsupported}

      def register_payout_account(%{owner_member_id: id}) do
        case Process.get(:other_register) do
          nil -> {:ok, %{provider_account_id: "other-#{id}", status: :active}}
          error -> error
        end
      end

      def payout_account_status(_), do: {:ok, :active}
      def balance(_), do: {:ok, 0}
      def withdraw(_, _, _), do: {:managed, "https://dashboard.example.test"}
    end

    test "fee_for/2 and registration go through whichever adapter is configured" do
      put_env!(:gateway, OtherGateway)
      group = group_fixture()
      {_user, host} = host_fixture(group)
      actor = host_actor(group, host)

      assert Payments.gateway() == OtherGateway
      assert {:ok, 450} = Payments.fee_for("qris", 45_000)
      assert {:error, :unsupported_method} = Payments.fee_for("va", 45_000)

      assert {:ok, %{payout_account: account}} =
               Payments.register_payout_account(actor, group.id, "k1", @bank)

      assert %{provider: "other", provider_account_id: id, status: "active"} = account
      assert id == "other-#{host.id}"
    end

    test "a gateway failure creates no payout account" do
      put_env!(:gateway, OtherGateway)
      Process.put(:other_register, {:error, :provider_down})
      group = group_fixture()
      {_user, host} = host_fixture(group)

      assert {:error, :provider_down} =
               Payments.register_payout_account(host_actor(group, host), group.id, "k1", @bank)

      assert Repo.aggregate(PayoutAccount, :count) == 0
      assert Repo.aggregate(AuditLog, :count) == 0
    end
  end
end
