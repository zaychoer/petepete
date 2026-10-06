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

  test "an atom without text raises, so a code cannot ship without a message", %{conn: conn} do
    assert_raise KeyError, fn -> LedgerError.render(conn, :something_new) end
  end
end
