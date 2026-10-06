defmodule Petepete.WibTest do
  use ExUnit.Case, async: true

  alias Petepete.Wib

  test "date/1 rolls over at 17:00 UTC" do
    assert Wib.date(~U[2026-10-05 16:59:59Z]) == ~D[2026-10-05]
    assert Wib.date(~U[2026-10-05 17:00:00Z]) == ~D[2026-10-06]
  end

  test "to_utc/2 is midnight WIB by default and round-trips through date/1" do
    assert Wib.to_utc(~D[2026-10-06]) == ~U[2026-10-05 17:00:00Z]
    assert Wib.to_utc(~D[2026-10-06], ~T[23:59:00]) == ~U[2026-10-06 16:59:00Z]
    assert Wib.date(Wib.to_utc(~D[2026-10-06])) == ~D[2026-10-06]
  end
end
