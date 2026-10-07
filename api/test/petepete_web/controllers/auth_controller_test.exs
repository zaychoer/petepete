defmodule PetepeteWeb.AuthControllerTest do
  use PetepeteWeb.ConnCase, async: true

  import Ecto.Query

  alias Petepete.{Clock, Repo}
  alias Petepete.Accounts.{OtpChallenge, RefreshToken, User}

  @t0 ~U[2026-10-06 03:00:00Z]

  setup do
    Clock.freeze(@t0)
    :ok
  end

  describe "phone numbers" do
    test "08xx, +62 and 62 inputs log in as the same user", %{conn: conn} do
      phone = unique_phone()

      ids =
        for input <- [
              "0" <> String.replace_prefix(phone, "62", ""),
              "+" <> phone,
              phone
            ] do
          %{"user" => %{"id" => id}} = login(conn, input)
          id
        end

      assert [id] = Enum.uniq(ids)
      assert Repo.get!(User, id).phone == phone
    end

    test "malformed numbers are rejected without sending", %{conn: conn} do
      for bad <- ["12345", "0212345678", "abc", "", "+1 202 555 0100"] do
        conn = post(conn, ~p"/api/auth/otp", %{phone: bad})
        assert json_response(conn, 422) == %{"error" => "invalid_phone"}
      end

      conn = post(conn, ~p"/api/auth/otp", %{})
      assert json_response(conn, 422) == %{"error" => "invalid_phone"}
      refute_received {:otp_sent, _, _}
    end
  end

  describe "OTP" do
    test "a code has 6 digits and is stored only as a hash", %{conn: conn} do
      phone = unique_phone()
      code = request_otp(conn, phone)

      assert code =~ ~r/\A\d{6}\z/
      challenge = Repo.one!(from c in OtpChallenge, order_by: [desc: c.id], limit: 1)
      refute challenge.code_hash == code
      refute :binary.match(challenge.code_hash <> challenge.phone_hash, [code, phone]) != :nomatch
    end

    test "first login creates the user, later logins find it", %{conn: conn} do
      phone = unique_phone()

      assert %{"new_user" => true, "user" => %{"id" => id, "display_name" => ""}} =
               login(conn, phone)

      assert %{"new_user" => false, "user" => %{"id" => ^id}} = login(conn, phone)
    end

    test "valid just under 5 minutes, void after", %{conn: conn} do
      phone = unique_phone()
      code = request_otp(conn, phone)
      Clock.advance(299)
      assert %{"access_token" => _} = verify(conn, phone, code) |> json_response(200)

      code = request_otp(conn, phone)
      Clock.advance(300)
      assert verify(conn, phone, code) |> json_response(401) == %{"error" => "invalid_code"}
    end

    test "a code works once", %{conn: conn} do
      phone = unique_phone()
      code = request_otp(conn, phone)

      assert verify(conn, phone, code).status == 200
      assert verify(conn, phone, code).status == 401
    end

    test "5 wrong attempts burn the code, even for the right code afterwards", %{conn: conn} do
      phone = unique_phone()
      code = request_otp(conn, phone)
      wrong = wrong_code(code)

      for _ <- 1..5, do: assert(verify(conn, phone, wrong).status == 401)
      assert verify(conn, phone, code).status == 401
    end

    test "4 wrong attempts leave the code usable", %{conn: conn} do
      phone = unique_phone()
      code = request_otp(conn, phone)

      for _ <- 1..4, do: assert(verify(conn, phone, wrong_code(code)).status == 401)
      assert verify(conn, phone, code).status == 200
    end

    test "a newer code replaces the older one", %{conn: conn} do
      phone = unique_phone()
      old = request_otp(conn, phone)
      new = request_otp(conn, phone)
      assert old != new

      assert verify(conn, phone, old).status == 401
      assert verify(conn, phone, new).status == 200
    end

    test "a code for one phone does not work for another", %{conn: conn} do
      code = request_otp(conn, unique_phone())
      assert verify(conn, unique_phone(), code).status == 401
    end

    test "non-6-digit codes and missing params are rejected", %{conn: conn} do
      phone = unique_phone()
      request_otp(conn, phone)

      for bad <- ["12345", "1234567", "abcdef", nil, 123_456] do
        assert verify(conn, phone, bad).status == 401
      end

      conn = post(conn, ~p"/api/auth/verify", %{phone: phone})
      assert json_response(conn, 401) == %{"error" => "invalid_code"}
    end
  end

  describe "rate limits" do
    test "at most 5 requests per phone per hour", %{conn: conn} do
      phone = unique_phone()
      for i <- 1..5, do: request_otp(conn, phone, {10, 1, 0, i})

      conn = %{conn | remote_ip: {10, 1, 0, 6}}

      assert post(conn, ~p"/api/auth/otp", %{phone: phone}) |> json_response(429) ==
               %{"error" => "rate_limited"}

      refute_received {:otp_sent, _, _}

      # other phones are unaffected; the window slides
      request_otp(conn, unique_phone())
      Clock.advance(3601)
      request_otp(conn, phone)
    end

    test "at most 20 requests per IP per hour", %{conn: conn} do
      ip = {10, 2, 0, 1}
      for _ <- 1..20, do: request_otp(conn, unique_phone(), ip)

      limited = %{conn | remote_ip: ip}

      assert post(limited, ~p"/api/auth/otp", %{phone: unique_phone()}) |> json_response(429) ==
               %{"error" => "rate_limited"}

      request_otp(conn, unique_phone(), {10, 2, 0, 2})
      Clock.advance(3601)
      request_otp(conn, unique_phone(), ip)
    end
  end

  describe "refresh and logout" do
    test "refresh rotates: the old token dies, the new one works", %{conn: conn} do
      %{"refresh_token" => first} = login(conn, unique_phone())

      assert %{"access_token" => access, "refresh_token" => second} =
               refresh(conn, first) |> json_response(200)

      assert second != first
      assert is_binary(access)
      assert refresh(conn, first).status == 401
      assert refresh(conn, second).status == 401
    end

    test "reusing a rotated token revokes the whole family", %{conn: conn} do
      %{"refresh_token" => first} = login(conn, unique_phone())
      %{"refresh_token" => second} = refresh(conn, first) |> json_response(200)
      %{"refresh_token" => third} = refresh(conn, second) |> json_response(200)

      assert refresh(conn, first).status == 401
      assert refresh(conn, third).status == 401
    end

    test "other logins of the same user are not revoked by a reuse", %{conn: conn} do
      phone = unique_phone()
      %{"refresh_token" => phone_a} = login(conn, phone)
      %{"refresh_token" => phone_b} = login(conn, phone)
      %{"refresh_token" => rotated} = refresh(conn, phone_a) |> json_response(200)

      assert refresh(conn, phone_a).status == 401
      assert refresh(conn, rotated).status == 401
      assert refresh(conn, phone_b).status == 200
    end

    test "an expired refresh token is rejected", %{conn: conn} do
      %{"refresh_token" => token} = login(conn, unique_phone())
      Clock.advance(30 * 24 * 60 * 60)
      assert refresh(conn, token) |> json_response(401) == %{"error" => "invalid_token"}
    end

    test "refresh tokens are stored hashed", %{conn: conn} do
      %{"refresh_token" => token} = login(conn, unique_phone())
      stored = Repo.one!(from t in RefreshToken, order_by: [desc: t.id], limit: 1)
      refute stored.token_hash == token
    end

    test "unknown tokens and missing params are rejected", %{conn: conn} do
      assert refresh(conn, "nope").status == 401

      assert post(conn, ~p"/api/auth/refresh", %{}) |> json_response(401) ==
               %{"error" => "invalid_token"}
    end

    test "logout revokes the refresh token and its family", %{conn: conn} do
      %{"refresh_token" => first} = login(conn, unique_phone())
      %{"refresh_token" => second} = refresh(conn, first) |> json_response(200)

      assert post(conn, ~p"/api/auth/logout", %{refresh_token: second}) |> json_response(200) ==
               %{"ok" => true}

      assert refresh(conn, second).status == 401
    end

    test "logout with an unknown token still succeeds", %{conn: conn} do
      assert post(conn, ~p"/api/auth/logout", %{refresh_token: "nope"}).status == 200
      assert post(conn, ~p"/api/auth/logout", %{}).status == 200
    end
  end

  defp unique_phone,
    do:
      "628" <>
        (System.unique_integer([:positive])
         |> rem(1_000_000_000)
         |> Integer.to_string()
         |> String.pad_leading(9, "0"))

  defp request_otp(conn, phone, ip \\ {10, 0, 0, 1}) do
    conn = %{conn | remote_ip: ip}
    assert post(conn, ~p"/api/auth/otp", %{phone: phone}) |> json_response(200) == %{"ok" => true}
    assert_received {:otp_sent, _normalized, code}
    code
  end

  defp verify(conn, phone, code),
    do: post(conn, ~p"/api/auth/verify", %{phone: phone, code: code})

  defp login(conn, phone) do
    # a fresh IP per login keeps these helpers clear of the per-IP limit
    ip =
      {10, 9, rem(System.unique_integer([:positive]), 250),
       rem(System.unique_integer([:positive]), 250)}

    code = request_otp(conn, phone, ip)
    verify(conn, phone, code) |> json_response(200)
  end

  defp refresh(conn, token), do: post(conn, ~p"/api/auth/refresh", %{refresh_token: token})

  defp wrong_code(code), do: if(code == "000000", do: "000001", else: "000000")
end
