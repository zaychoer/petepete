defmodule PetepeteWeb.LedgerErrorTest do
  use PetepeteWeb.ConnCase, async: true

  alias Petepete.Contract
  alias PetepeteWeb.LedgerError

  # Reached only through the cash cancel route (Billing), whose test lives with the bills.
  test "undo_window_expired says why in the sample", %{conn: conn} do
    conn = LedgerError.render(conn, :undo_window_expired)

    Contract.check!("errors/undo_window_expired", conn)
    assert %{"message" => "Batas waktu pembatalan 24 jam" <> _} = json_response(conn, 422)
  end

  test "an atom without text still answers with a message", %{conn: conn} do
    assert %{"error" => "something_new", "message" => message} =
             conn |> LedgerError.render(:something_new) |> json_response(422)

    assert message != ""
  end
end
