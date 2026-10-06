defmodule Petepete.Groups.TemplatesTest do
  use ExUnit.Case, async: true

  alias Petepete.Groups.Templates

  test "offers the five sport templates of the spec" do
    assert Templates.names() == ["Futsal", "Badminton", "Padel", "Mini Soccer", "Acara Umum"]
  end

  test "every template has distinct default cost categories that fit a cost item" do
    for name <- Templates.names() do
      categories = Templates.cost_categories(name)

      assert categories != []
      assert categories == Enum.uniq(categories)
      assert Enum.all?(categories, &(String.length(&1) in 1..50))
    end
  end

  test "an unknown or missing template has no categories and is not valid" do
    assert Templates.cost_categories("Catur") == []
    assert Templates.cost_categories(nil) == []
    refute Templates.valid?("Catur")
    refute Templates.valid?(nil)
    assert Templates.valid?("Padel")
  end
end
