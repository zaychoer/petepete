defmodule Petepete.Billing.CalculationTest do
  use ExUnit.Case, async: true

  alias Petepete.Billing.Calculation

  # Members 1..10 attended; 1..6 drink. Member 1 is the host.
  defp people(ids, weight \\ 1000),
    do: for(id <- ids, do: %{member_id: id, display_name: "M#{id}", weight: weight})

  defp item(id, amount, paid_by, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        category: "biaya #{id}",
        label: nil,
        amount: amount,
        paid_by_member_id: paid_by,
        scope: "all",
        member_ids: []
      },
      extra
    )
  end

  defp input(participants, items, unit \\ 1000),
    do: %{rounding_unit: unit, participants: participants, items: items}

  defp shares!(input) do
    assert {:ok, plan} = Calculation.shares(input)
    plan
  end

  defp share_of(plan, member_id), do: Enum.find(plan.members, &(&1.member_id == member_id)).share

  defp subset_example do
    input(
      people(1..10),
      [
        item(1, 350_000, 1),
        item(2, 100_000, 1),
        item(3, 60_000, 1, %{scope: "subset", member_ids: Enum.to_list(1..6)})
      ]
    )
  end

  describe "spec examples" do
    test "subset item: non-drinkers pay Rp45.000, drinkers Rp55.000, total Rp510.000, no kas" do
      plan = shares!(subset_example())

      for id <- 1..6, do: assert(share_of(plan, id) == 55_000)
      for id <- 7..10, do: assert(share_of(plan, id) == 45_000)
      assert plan.total_cost == 510_000
      assert plan.total_billed == 510_000
      assert plan.kas_remainder == 0
    end

    test "rounding: 3 attendees, Rp100.000, unit Rp1.000 -> Rp34.000 each, Rp2.000 to kas" do
      plan = shares!(input(people(1..3), [item(1, 100_000, 1)]))

      assert Enum.map(plan.members, & &1.share) == [34_000, 34_000, 34_000]
      assert plan.total_billed == 102_000
      assert plan.kas_remainder == 2_000
    end

    test "weights: a 1200 guest pays Rp60.000, members Rp50.000, no remainder" do
      guest = %{member_id: 4, display_name: "Tamu", weight: 1200}
      plan = shares!(input(people(1..3) ++ [guest], [item(1, 210_000, 1)]))

      assert Enum.map(plan.members, & &1.share) == [50_000, 50_000, 50_000, 60_000]
      assert plan.kas_remainder == 0
    end

    test "fronted credit: the host who fronted the court owes Rp0 and ends Rp305.000 up" do
      host_pays_court = %{subset_example() | items: fronted_by(10)}
      plan = host_pays_court |> shares!() |> Calculation.apply_credit(%{})
      host = Enum.find(plan.members, &(&1.member_id == 10))
      assert host.share == 45_000
      assert host.fronted == 350_000
      assert host.credit_applied == 45_000
      assert host.amount_due == 0
      # ledger effect: -share + fronted
      assert host.fronted - host.share == 305_000
    end
  end

  defp fronted_by(member_id) do
    [
      item(1, 350_000, member_id),
      item(2, 100_000, 1),
      item(3, 60_000, 1, %{scope: "subset", member_ids: Enum.to_list(1..6)})
    ]
  end

  describe "exact fractions" do
    test "parts of different items add up before rounding up" do
      # 1/3 of Rp1.000 twice is 666,67 per head: one round-up to Rp1.000, not two to Rp2.000.
      plan = shares!(input(people(1..3), [item(1, 1_000, 1), item(2, 1_000, 1)]))

      assert Enum.map(plan.members, & &1.share) == [1_000, 1_000, 1_000]
      assert plan.kas_remainder == 1_000

      assert hd(plan.members).raw_share == %{numerator: 2_000, denominator: 3}
    end

    test "unit Rp500 rounds to the next Rp500" do
      plan = shares!(input(people(1..3), [item(1, 100_000, 1)], 500))

      assert Enum.map(plan.members, & &1.share) == [33_500, 33_500, 33_500]
      assert plan.kas_remainder == 500
    end

    test "an exact share is not rounded up" do
      plan = shares!(input(people(1..4), [item(1, 100_000, 1)]))
      assert Enum.map(plan.members, & &1.share) == [25_000, 25_000, 25_000, 25_000]
      assert plan.kas_remainder == 0
    end

    test "every share is the smallest unit multiple >= the exact part, and kas is never negative" do
      :rand.seed(:exsss, {1, 2, 3})

      for _ <- 1..200 do
        ids = Enum.to_list(1..Enum.random(1..9))

        weights =
          for id <- ids, do: %{member_id: id, display_name: nil, weight: Enum.random(1..40) * 50}

        unit = Enum.random([500, 1000])

        items =
          for k <- 1..Enum.random(1..4) do
            subset = Enum.take_random(ids, Enum.random(1..length(ids)))

            item(k, Enum.random(1..500) * 1000 + Enum.random(0..999), 1, %{
              scope: "subset",
              member_ids: subset
            })
          end

        case Calculation.shares(input(weights, items, unit)) do
          {:ok, plan} ->
            assert plan.kas_remainder >= 0

            for m <- plan.members do
              %{numerator: n, denominator: d} = m.raw_share
              assert rem(m.share, unit) == 0
              assert m.share * d >= n
              assert (m.share - unit) * d < n or m.share == 0
            end

          {:error, {:invalid, _}} ->
            :ok
        end
      end
    end
  end

  describe "subset items" do
    test "absent members of a subset do not bear the item or its weight" do
      # Drinks for members 1..6, but 5 and 6 did not come: only 1..4 split Rp60.000.
      attended = people(1..4) ++ people(7..10)

      plan =
        shares!(
          input(attended, [item(1, 60_000, 1, %{scope: "subset", member_ids: Enum.to_list(1..6)})])
        )

      for id <- 1..4, do: assert(share_of(plan, id) == 15_000)
      for id <- 7..10, do: assert(share_of(plan, id) == 0)
      assert hd(plan.items).bearer_ids == [1, 2, 3, 4]
    end

    test "a subset item weighs only its own bearers" do
      participants = [
        %{member_id: 1, display_name: nil, weight: 1000},
        %{member_id: 2, display_name: nil, weight: 2000},
        %{member_id: 3, display_name: nil, weight: 7000}
      ]

      plan =
        shares!(input(participants, [item(1, 30_000, 1, %{scope: "subset", member_ids: [1, 2]})]))

      assert Enum.map(plan.members, & &1.share) == [10_000, 20_000, 0]
    end

    test "a participant who bears nothing has a share of 0" do
      plan =
        shares!(input(people(1..2), [item(1, 10_000, 1, %{scope: "subset", member_ids: [1]})]))

      assert share_of(plan, 2) == 0
      assert plan.total_billed == 10_000
    end

    test "per-item lines add up to the share with the rounding adjustment" do
      plan = shares!(subset_example())

      for m <- plan.members do
        assert Enum.sum(Enum.map(m.lines, & &1.amount)) + m.rounding == m.share
      end

      drinker = Enum.find(plan.members, &(&1.member_id == 1))
      assert Enum.map(drinker.lines, & &1.cost_item_id) == [1, 2, 3]
    end
  end

  describe "credit" do
    setup do
      # Fronted by a member who did not attend, so only the balances count as credit.
      %{plan: shares!(input(people(1..2), [item(1, 100_000, 99)]))}
    end

    test "a positive balance reduces the bill; a debt does not", %{plan: plan} do
      result = Calculation.apply_credit(plan, %{1 => 20_000, 2 => -30_000})
      [a, b] = result.members

      assert {a.share, a.credit_applied, a.amount_due} == {50_000, 20_000, 30_000}
      assert b.credit_balance == 0
      assert {b.share, b.credit_applied, b.amount_due} == {50_000, 0, 50_000}
      assert result.credit_used == 20_000
      assert result.total_due == 80_000
    end

    test "credit larger than the share is used only up to the share", %{plan: plan} do
      [a, _] = Calculation.apply_credit(plan, %{1 => 90_000}).members

      assert {a.credit_applied, a.amount_due} == {50_000, 0}
    end

    test "balance and fronted amount both count as credit" do
      plan = shares!(input(people(1..2), [item(1, 100_000, 1), item(2, 20_000, 1)]))
      [a, _] = Calculation.apply_credit(plan, %{1 => 5_000}).members

      assert a.credit_available == 125_000
      assert a.credit_applied == a.share
    end
  end

  describe "validation" do
    test "an item nobody bears blocks the bill" do
      assert {:error, {:invalid, [{:item_without_bearers, 3}]}} =
               Calculation.shares(
                 input(people(1..2), [
                   item(1, 10_000, 1),
                   item(3, 5_000, 1, %{scope: "subset", member_ids: [8, 9]})
                 ])
               )
    end

    test "no attendees leaves every item without bearers" do
      assert {:error, {:invalid, errors}} = Calculation.shares(input([], [item(1, 10_000, 1)]))
      assert {:item_without_bearers, 1} in errors
    end

    test "a session without cost items has no positive total" do
      assert {:error, {:invalid, [:total_cost_not_positive]}} =
               Calculation.shares(input(people(1..2), []))
    end

    test "a zero weight and a zero amount are rejected" do
      participants = [%{member_id: 1, display_name: nil, weight: 0}]

      assert {:error, {:invalid, errors}} =
               Calculation.shares(input(participants, [item(1, 0, 1)]))

      assert {:invalid_weight, 1} in errors
      assert {:invalid_amount, 1} in errors
      assert :total_cost_not_positive in errors
    end

    test "an item nobody fronted is rejected" do
      assert {:error, {:invalid, [{:item_without_payer, 1}]}} =
               Calculation.shares(input(people(1..2), [item(1, 10_000, nil)]))
    end
  end

  describe "determinism" do
    test "input order does not change the result" do
      reference = shares!(subset_example())

      shuffled =
        subset_example()
        |> Map.update!(:participants, &Enum.reverse/1)
        |> Map.update!(:items, &Enum.reverse/1)
        |> shares!()

      assert shuffled == reference

      assert Calculation.apply_credit(shuffled, %{3 => 1_000}) ==
               Calculation.apply_credit(reference, %{3 => 1_000})
    end

    test "fronted amounts are summed per member" do
      plan =
        shares!(input(people(1..2), [item(1, 10_000, 2), item(2, 4_000, 2), item(3, 6_000, 1)]))

      assert plan.fronted == [{1, 6_000}, {2, 14_000}]
    end
  end

  test "the module does no floating-point arithmetic" do
    source = File.read!(Calculation.module_info(:compile)[:source] |> to_string())

    refute source =~ ~r/Float|:math|\bround\(|\bceil\(|\bfloor\(|\btrunc\(|\d\.\d/
  end
end
