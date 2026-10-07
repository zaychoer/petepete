defmodule Petepete.Accounts do
  @moduledoc """
  Logins: users, OTP challenges and refresh tokens.

  Schemas: `Petepete.Accounts.User` (`users`), `Petepete.Accounts.OtpChallenge`
  (`otp_challenges`), `Petepete.Accounts.RefreshToken` (`refresh_tokens`).

  ## Login

  `request_otp/2` sends a 6-digit code valid for 5 minutes, at most 5 requests per
  phone and 20 per IP per hour. `verify_otp/2` accepts the latest code of a phone
  at most 5 times wrong, then the code is void; a right code is single use. A
  verified login finds or creates the `User` and returns a short-lived signed
  access token plus a rotating refresh token.

  Phones are normalised to 62… format. The code and the phone are stored only as
  HMACs (key: `otp_hmac_key`); the plaintext code exists only in the message to the
  `Petepete.Accounts.OtpSender`. Phones are never logged.

  ## Tokens

  The access token is a signed `{user id, expiry}` (15 minutes); it is not stored,
  so logout takes effect when it expires. Refresh tokens are random, stored as
  SHA-256, valid for 30 days and replaced by a new token of the same family on every
  use. Presenting a token that was already used or revoked revokes its whole family.

  ## Profile and roster links

  A new user has an empty `display_name`; `update_profile/2` sets it (the app asks on
  first login). A verified login and every profile update call
  `Petepete.Groups.link_members_by_phone/1`, so guests and members a host added by
  number become the user's own roster entries, in the same transaction.

  ## Account deletion (UU PDP)

  `delete_account/1` anonymises instead of deleting rows, because ledger entries
  must stay intact (append-only) and keep pointing at the member:

  * `users.phone` becomes the unique placeholder `deleted:<id>` (never a valid phone),
    `display_name` becomes "Mantan anggota" and `deleted_at` is set;
  * the user's roster entries are anonymised (`Petepete.Groups.anonymize_roster/1`);
  * all refresh tokens are revoked and the phone's OTP challenges are deleted;
    access tokens of a deleted user are rejected by `authenticate_access_token/1`.

  It is refused with `{:error, :still_host}` while the user hosts an active group
  (see `Petepete.Groups.Policy.hosts_active_group?/1`: any non-cancelled session, or any
  roster entry besides the host). The same phone can log in again afterwards and
  gets a fresh user.
  """

  import Ecto.Query

  alias Petepete.Accounts.{OtpChallenge, OtpSender, RefreshToken, Scope, User}
  alias Petepete.{Clock, Groups, Repo}

  require Logger

  @code_ttl 5 * 60
  @max_wrong_attempts 5
  @phone_limit 5
  @ip_limit 20
  @rate_window 60 * 60
  @access_ttl 15 * 60
  @refresh_ttl 30 * 24 * 60 * 60
  @access_salt "petepete access token"

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_in: pos_integer()
        }

  @doc """
  Normalises an Indonesian mobile number to 62… format.

  Accepts `08xx`, `+62 8xx` and `628xx`, with spaces, dashes, dots or parentheses.

      iex> Petepete.Accounts.normalize_phone("0812-3456-7890")
      {:ok, "6281234567890"}
      iex> Petepete.Accounts.normalize_phone("+62 812 3456 7890")
      {:ok, "6281234567890"}
      iex> Petepete.Accounts.normalize_phone("12345")
      {:error, :invalid_phone}
  """
  @spec normalize_phone(term()) :: {:ok, String.t()} | {:error, :invalid_phone}
  def normalize_phone(raw) when is_binary(raw) do
    digits = String.replace(raw, ~r/[\s\-\.\(\)]/, "")

    normalized =
      case digits do
        "+" <> rest -> rest
        "0" <> rest -> "62" <> rest
        other -> other
      end

    if normalized =~ ~r/\A628\d{7,11}\z/, do: {:ok, normalized}, else: {:error, :invalid_phone}
  end

  def normalize_phone(_), do: {:error, :invalid_phone}

  @doc """
  Sends a fresh OTP code to `raw_phone`; `ip` is the caller's address for rate limiting.

  Returns `{:error, :invalid_phone | :rate_limited | :delivery_failed}`. A failed
  delivery does not count toward the limits. Earlier codes of the phone stop working
  when a newer one is issued.
  """
  @spec request_otp(term(), String.t()) ::
          :ok | {:error, :invalid_phone | :rate_limited | :delivery_failed}
  def request_otp(raw_phone, ip) when is_binary(ip) do
    with {:ok, phone} <- normalize_phone(raw_phone) do
      now = Clock.now()
      code = generate_code()
      phone_hash = hash_phone(phone)

      case insert_challenge(phone_hash, hash_code(phone_hash, code), ip, now) do
        {:ok, challenge} -> deliver_otp(challenge, phone, code)
        {:error, :rate_limited} = error -> error
      end
    end
  end

  defp insert_challenge(phone_hash, code_hash, ip, now) do
    since = DateTime.add(now, -@rate_window, :second)

    Repo.transaction(fn ->
      lock_rate_limits(phone_hash, ip)

      phone_count =
        Repo.aggregate(
          from(c in OtpChallenge, where: c.phone_hash == ^phone_hash and c.inserted_at > ^since),
          :count
        )

      ip_count =
        Repo.aggregate(
          from(c in OtpChallenge, where: c.ip == ^ip and c.inserted_at > ^since),
          :count
        )

      if phone_count >= @phone_limit or ip_count >= @ip_limit, do: Repo.rollback(:rate_limited)

      Repo.insert!(%OtpChallenge{
        phone_hash: phone_hash,
        code_hash: code_hash,
        ip: ip,
        attempts: 0,
        expires_at: DateTime.add(now, @code_ttl, :second),
        inserted_at: now
      })
    end)
  end

  # Serialises concurrent requests for the same phone or IP so the counts above
  # cannot be raced past. Locks are taken in a fixed order to avoid deadlocks.
  defp lock_rate_limits(phone_hash, ip) do
    for key <- Enum.sort([lock_key("phone", phone_hash), lock_key("ip", ip)]) do
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
    end
  end

  defp lock_key(kind, value) do
    <<key::signed-64, _::binary>> = :crypto.hash(:sha256, [kind, ?:, value])
    key
  end

  defp deliver_otp(challenge, phone, code) do
    case OtpSender.deliver(phone, code) do
      :ok ->
        :ok

      {:error, _reason} ->
        Repo.delete!(challenge)
        Logger.error("OTP delivery failed")
        {:error, :delivery_failed}
    end
  end

  @doc """
  Checks `code` against the latest code of `raw_phone` and logs the user in.

  Returns `{:ok, user, tokens, new_user?}`. Every failure is `{:error, :invalid_code}`
  (wrong, expired, used, burnt, or never requested) so callers cannot tell them apart.
  """
  @spec verify_otp(term(), term()) ::
          {:ok, User.t(), tokens(), boolean()} | {:error, :invalid_code}
  def verify_otp(raw_phone, code) do
    with {:ok, phone} <- normalize_phone(raw_phone),
         true <- is_binary(code) and code =~ ~r/\A\d{6}\z/ do
      now = Clock.now()
      phone_hash = hash_phone(phone)

      {:ok, result} =
        Repo.transaction(fn -> verify_in_transaction(phone, phone_hash, code, now) end)

      result
    else
      _ -> {:error, :invalid_code}
    end
  end

  # Failed checks return normally so the attempt counter commits.
  defp verify_in_transaction(phone, phone_hash, code, now) do
    challenge =
      Repo.one(
        from c in OtpChallenge,
          where: c.phone_hash == ^phone_hash,
          order_by: [desc: c.id],
          limit: 1,
          lock: "FOR UPDATE"
      )

    cond do
      is_nil(challenge) ->
        {:error, :invalid_code}

      DateTime.compare(challenge.expires_at, now) != :gt or
          challenge.attempts >= @max_wrong_attempts ->
        {:error, :invalid_code}

      not Plug.Crypto.secure_compare(challenge.code_hash, hash_code(phone_hash, code)) ->
        Repo.update_all(from(c in OtpChallenge, where: c.id == ^challenge.id),
          inc: [attempts: 1]
        )

        {:error, :invalid_code}

      true ->
        Repo.update_all(from(c in OtpChallenge, where: c.id == ^challenge.id),
          set: [expires_at: now]
        )

        {user, new_user?} = find_or_create_user(phone, now)
        Groups.link_members_by_phone(user)
        {:ok, user, issue_tokens(user, Ecto.UUID.generate(), now), new_user?}
    end
  end

  # A new user has no display name yet: the app asks for it on first login.
  defp find_or_create_user(phone, now) do
    inserted =
      Repo.insert!(%User{phone: phone, display_name: "", inserted_at: now, updated_at: now},
        on_conflict: :nothing,
        conflict_target: :phone
      )

    {Repo.get_by!(User, phone: phone), not is_nil(inserted.id)}
  end

  @max_name_length 50

  @doc """
  Sets the user's display name (trimmed, 1 to #{@max_name_length} characters) and links
  roster entries added by this phone number.

  Returns `{:error, :invalid_display_name}` for a blank, too long or non-string name.
  """
  @spec update_profile(Scope.t(), term()) :: {:ok, User.t()} | {:error, :invalid_display_name}
  def update_profile(%Scope{user: %User{} = user}, display_name) when is_binary(display_name) do
    name = String.trim(display_name)

    if name == "" or String.length(name) > @max_name_length do
      {:error, :invalid_display_name}
    else
      Repo.transaction(fn ->
        updated =
          user
          |> Ecto.Changeset.change(display_name: name, updated_at: Clock.now())
          |> Repo.update!()

        Groups.link_members_by_phone(updated)
        updated
      end)
    end
  end

  def update_profile(%Scope{}, _display_name), do: {:error, :invalid_display_name}

  @doc """
  Anonymises the caller's account. See the moduledoc, "Account deletion".

  Returns `{:error, :still_host}` while the user hosts an active group.
  """
  @spec delete_account(Scope.t()) :: :ok | {:error, :still_host | :unauthenticated}
  def delete_account(%Scope{user: %User{id: user_id}}) do
    now = Clock.now()

    result =
      Repo.transaction(fn ->
        with %User{deleted_at: nil} = user <-
               Repo.one(from u in User, where: u.id == ^user_id, lock: "FOR UPDATE"),
             false <- Groups.Policy.hosts_active_group?(user_id) do
          phone_hash = hash_phone(user.phone)
          Repo.delete_all(from c in OtpChallenge, where: c.phone_hash == ^phone_hash)

          Repo.update_all(
            from(t in RefreshToken, where: t.user_id == ^user_id and is_nil(t.revoked_at)),
            set: [revoked_at: now]
          )

          Groups.anonymize_roster(user_id)

          user
          |> Ecto.Changeset.change(
            phone: "deleted:#{user_id}",
            display_name: Groups.former_member_label(),
            deleted_at: now,
            updated_at: now
          )
          |> Repo.update!()
        else
          true -> Repo.rollback(:still_host)
          _ -> Repo.rollback(:unauthenticated)
        end
      end)

    with {:ok, _user} <- result, do: :ok
  end

  @doc """
  Exchanges a refresh token for a new access + refresh token pair.

  The presented token is revoked. Presenting a token that is already revoked
  revokes its whole family (a stolen copy was used, or the client lost the reply).
  """
  @spec refresh(term()) :: {:ok, tokens()} | {:error, :invalid_token}
  def refresh(token) when is_binary(token) do
    now = Clock.now()

    {:ok, result} =
      Repo.transaction(fn ->
        with %RefreshToken{} = stored <- lock_refresh_token(token),
             :ok <- check_refresh_token(stored, now),
             %User{deleted_at: nil} = user <- Repo.get(User, stored.user_id) do
          stored |> revoke_changeset(now) |> Repo.update!()
          {:ok, issue_tokens(user, stored.family_id, now)}
        else
          _ -> {:error, :invalid_token}
        end
      end)

    result
  end

  def refresh(_), do: {:error, :invalid_token}

  defp lock_refresh_token(token) do
    hash = hash_token(token)

    Repo.one(from t in RefreshToken, where: t.token_hash == ^hash, lock: "FOR UPDATE")
  end

  defp check_refresh_token(%RefreshToken{revoked_at: nil} = stored, now) do
    if DateTime.compare(stored.expires_at, now) == :gt, do: :ok, else: :expired
  end

  defp check_refresh_token(%RefreshToken{} = stored, now) do
    revoke_family(stored.family_id, now)
    :reused
  end

  @doc "Revokes the whole family of `token`. Always `:ok`, also for unknown tokens."
  @spec logout(term()) :: :ok
  def logout(token) when is_binary(token) do
    case Repo.one(from t in RefreshToken, where: t.token_hash == ^hash_token(token)) do
      nil -> :ok
      stored -> revoke_family(stored.family_id, Clock.now())
    end
  end

  def logout(_), do: :ok

  @doc """
  Resolves a bearer access token to the caller's scope.

  Fails for bad signatures, expired tokens and deleted users.
  """
  @spec authenticate_access_token(term()) :: {:ok, Scope.t()} | {:error, :unauthenticated}
  def authenticate_access_token(token) when is_binary(token) do
    with {:ok, %{"uid" => user_id, "exp" => exp}} <-
           Phoenix.Token.verify(token_secret(), @access_salt, token, max_age: :infinity),
         true <- exp > DateTime.to_unix(Clock.now()),
         %User{deleted_at: nil} = user <- Repo.get(User, user_id) do
      {:ok, Scope.for(user)}
    else
      _ -> {:error, :unauthenticated}
    end
  end

  def authenticate_access_token(_), do: {:error, :unauthenticated}

  defp issue_tokens(%User{} = user, family_id, now) do
    refresh_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Repo.insert!(%RefreshToken{
      user_id: user.id,
      family_id: family_id,
      token_hash: hash_token(refresh_token),
      expires_at: DateTime.add(now, @refresh_ttl, :second),
      inserted_at: now
    })

    access_token =
      Phoenix.Token.sign(
        token_secret(),
        @access_salt,
        %{"uid" => user.id, "exp" => DateTime.to_unix(now) + @access_ttl}
      )

    %{access_token: access_token, refresh_token: refresh_token, expires_in: @access_ttl}
  end

  defp revoke_changeset(%RefreshToken{} = token, now),
    do: Ecto.Changeset.change(token, revoked_at: now)

  defp revoke_family(family_id, now) do
    Repo.update_all(
      from(t in RefreshToken, where: t.family_id == ^family_id and is_nil(t.revoked_at)),
      set: [revoked_at: now]
    )

    :ok
  end

  # Uniform over 000000..999999: draws above the largest multiple of 10^6 are rejected.
  defp generate_code do
    <<n::32>> = :crypto.strong_rand_bytes(4)

    if n < 4_294_000_000 do
      n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    else
      generate_code()
    end
  end

  defp hash_phone(phone), do: hmac(["phone:", phone])

  # Bound to the phone hash so a code cannot be replayed against another phone's row.
  defp hash_code(phone_hash, code), do: hmac(["code:", phone_hash, ?:, code])

  defp hmac(data), do: :crypto.mac(:hmac, :sha256, config!(:otp_hmac_key), data)

  # Refresh tokens carry 256 random bits, so a plain digest is enough.
  defp hash_token(token), do: :crypto.hash(:sha256, token)

  defp token_secret,
    do:
      :petepete
      |> Application.fetch_env!(PetepeteWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

  defp config!(key), do: :petepete |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(key)
end
