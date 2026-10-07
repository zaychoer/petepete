defmodule Petepete.Billing.Calculation do
  @moduledoc """
  The split of a session's costs among the people who attended: the spec's "Aturan hitung",
  steps 1-7, as pure integer arithmetic. `Billing.preview/1` and `Billing.issue/2` both
  run exactly this code over the stored rows, so a preview and the bills it becomes agree
  on every share.

  Money is whole rupiah and weights are integer per mil (1000 = 1x). There are no floats:
  a person's raw part of a cost item is the exact fraction `amount * weight / W` (`W` is
  the summed weight of the item's bearers), the fractions of all items are added exactly
  (numerator and denominator are integers), and nothing is rounded until the last step.

  ## Input

      %{
        rounding_unit: 1000,
        participants: [%{member_id: 1, display_name: "Andi", weight: 1000}],  # attended only
        items: [
          %{id: 1, category: "lapangan", label: nil, amount: 350_000,
            paid_by_member_id: 1, scope: "all" | "subset", member_ids: [..]}   # member_ids: subset only
        ]
      }

  ## Steps

  1. `participants` are the people with `attended = true` and their weights.
  2. The bearers of an item are all participants (scope `all`) or its `member_ids` that
     also attended (scope `subset`).
  3. Raw part of participant i = sum over items of `amount * w_i / W_item`, an exact fraction.
  4. `share` = raw part rounded **up** to a multiple of `rounding_unit`.
  5. `kas_remainder` = sum of shares - total cost (always >= 0).
  6. `apply_credit/2`: available credit = `max(0, balance before issue)` + the participant's
     fronted costs in this session; `credit_applied = min(share, credit)`;
     `amount_due = share - credit_applied`.
  7. Validation (`shares/1` returns `{:error, {:invalid, errors}}`): every item has at least
     one bearer and a positive amount, every weight is positive, the total cost is positive.
     Beyond the spec's list, every item must also name who fronted it (`paid_by_member_id`),
     because the ledger balances `sum(shares) = sum(fronted) + kas_remainder`; an item nobody
     fronted would be silently credited to the kas.

  A participant who bears no item has a share of 0 and gets no bill.
  """

  @type fraction :: %{numerator: non_neg_integer(), denominator: pos_integer()}

  @type line :: %{
          cost_item_id: pos_integer(),
          category: String.t(),
          label: String.t() | nil,
          fraction: fraction(),
          amount: non_neg_integer()
        }

  @type member_line :: %{
          member_id: pos_integer(),
          display_name: String.t() | nil,
          weight: pos_integer(),
          lines: [line()],
          raw_share: fraction(),
          share: non_neg_integer(),
          rounding: integer(),
          fronted: non_neg_integer()
        }

  @type error ::
          :invalid_rounding_unit
          | :total_cost_not_positive
          | {:item_without_bearers, pos_integer()}
          | {:item_without_payer, pos_integer()}
          | {:invalid_amount, pos_integer()}
          | {:invalid_weight, pos_integer()}

  @type plan :: %{
          rounding_unit: pos_integer(),
          total_cost: pos_integer(),
          total_billed: non_neg_integer(),
          kas_remainder: non_neg_integer(),
          items: [map()],
          fronted: [{pos_integer(), pos_integer()}],
          members: [member_line()]
        }

  @doc """
  Steps 1-5 and 7: validates the input and returns each participant's exact raw part and
  rounded `share`, the fronted amounts per member, the total cost, total billed and the
  `kas_remainder`. Members are ordered by id, items by id: the result is deterministic.

  `lines[].amount` is each item's part rounded to the nearest rupiah, for display only;
  `rounding` on a member is `share` minus the sum of its displayed lines, so the lines plus
  that adjustment add up to the share. The share itself always comes from the exact fraction.
  """
  @spec shares(map()) :: {:ok, plan()} | {:error, {:invalid, [error()]}}
  def shares(%{rounding_unit: unit, participants: participants, items: items}) do
    participants = Enum.sort_by(participants, & &1.member_id)
    items = Enum.sort_by(items, & &1.id)

    case validate(unit, participants, items) do
      [] -> {:ok, build(unit, participants, items)}
      errors -> {:error, {:invalid, errors}}
    end
  end

  @doc """
  Step 6. `balances` maps member id to the balance just before issuing (missing = 0).
  Adds `credit_balance` (the positive part), `credit_available`, `credit_applied` and
  `amount_due` to every member, and `credit_used` and `total_due` to the plan.
  """
  @spec apply_credit(plan(), %{optional(pos_integer()) => integer()}) :: map()
  def apply_credit(plan, balances) do
    members =
      Enum.map(plan.members, fn m ->
        credit_balance = max(0, Map.get(balances, m.member_id, 0))
        available = credit_balance + m.fronted
        applied = min(m.share, available)

        Map.merge(m, %{
          credit_balance: credit_balance,
          credit_available: available,
          credit_applied: applied,
          amount_due: m.share - applied
        })
      end)

    plan
    |> Map.put(:members, members)
    |> Map.put(:credit_used, sum(members, & &1.credit_applied))
    |> Map.put(:total_due, sum(members, & &1.amount_due))
  end

  ## Validation

  defp validate(unit, participants, items) do
    unit_errors = if is_integer(unit) and unit > 0, do: [], else: [:invalid_rounding_unit]

    weight_errors =
      for %{member_id: id, weight: w} <- participants,
          not (is_integer(w) and w > 0),
          do: {:invalid_weight, id}

    item_errors =
      Enum.flat_map(items, fn item ->
        [
          if(positive?(item.amount), do: nil, else: {:invalid_amount, item.id}),
          if(is_integer(item.paid_by_member_id), do: nil, else: {:item_without_payer, item.id}),
          if(bearers(item, participants) == [], do: {:item_without_bearers, item.id})
        ]
        |> Enum.reject(&is_nil/1)
      end)

    total_errors =
      if Enum.all?(items, &positive?(&1.amount)) and sum(items, & &1.amount) > 0,
        do: [],
        else: [:total_cost_not_positive]

    unit_errors ++ weight_errors ++ item_errors ++ total_errors
  end

  defp positive?(n), do: is_integer(n) and n > 0

  defp bearers(%{scope: "subset", member_ids: ids}, participants),
    do: Enum.filter(participants, &(&1.member_id in ids))

  defp bearers(_all, participants), do: participants

  ## Building

  defp build(unit, participants, items) do
    # item id => {bearers keyed by member id, summed weight W}
    bearing =
      Map.new(items, fn item ->
        bearers = bearers(item, participants)
        {item.id, {Map.new(bearers, &{&1.member_id, &1.weight}), sum(bearers, & &1.weight)}}
      end)

    fronted =
      items
      |> Enum.group_by(& &1.paid_by_member_id, & &1.amount)
      |> Map.new(fn {member_id, amounts} -> {member_id, Enum.sum(amounts)} end)

    members =
      Enum.map(participants, fn p ->
        lines =
          Enum.flat_map(items, fn item ->
            {weights, total_weight} = Map.fetch!(bearing, item.id)

            case Map.fetch(weights, p.member_id) do
              {:ok, weight} -> [line(item, weight, total_weight)]
              :error -> []
            end
          end)

        raw = lines |> Enum.map(& &1.fraction) |> Enum.reduce(fraction(0, 1), &add/2)
        share = round_up(raw, unit)

        %{
          member_id: p.member_id,
          display_name: Map.get(p, :display_name),
          weight: p.weight,
          lines: lines,
          raw_share: raw,
          share: share,
          rounding: share - sum(lines, & &1.amount),
          fronted: Map.get(fronted, p.member_id, 0)
        }
      end)

    total_cost = sum(items, & &1.amount)
    total_billed = sum(members, & &1.share)

    %{
      rounding_unit: unit,
      total_cost: total_cost,
      total_billed: total_billed,
      kas_remainder: total_billed - total_cost,
      items: Enum.map(items, &item_summary(&1, bearing)),
      fronted: fronted |> Enum.sort() |> Enum.to_list(),
      members: members
    }
  end

  defp item_summary(item, bearing) do
    {weights, total_weight} = Map.fetch!(bearing, item.id)

    %{
      id: item.id,
      category: item.category,
      label: item.label,
      amount: item.amount,
      paid_by_member_id: item.paid_by_member_id,
      scope: item.scope,
      bearer_ids: weights |> Map.keys() |> Enum.sort(),
      total_weight: total_weight
    }
  end

  defp line(item, weight, total_weight) do
    fraction = fraction(item.amount * weight, total_weight)

    %{
      cost_item_id: item.id,
      category: item.category,
      label: item.label,
      fraction: fraction,
      amount: nearest(fraction)
    }
  end

  ## Exact fractions

  defp fraction(numerator, denominator) do
    gcd = Integer.gcd(numerator, denominator)
    %{numerator: div(numerator, gcd), denominator: div(denominator, gcd)}
  end

  defp add(%{numerator: n1, denominator: d1}, %{numerator: n2, denominator: d2}) do
    lcm = div(d1 * d2, Integer.gcd(d1, d2))
    fraction(n1 * div(lcm, d1) + n2 * div(lcm, d2), lcm)
  end

  # Smallest multiple of `unit` that is >= numerator/denominator.
  defp round_up(%{numerator: n, denominator: d}, unit) do
    step = d * unit
    div(n + step - 1, step) * unit
  end

  defp nearest(%{numerator: n, denominator: d}), do: div(2 * n + d, 2 * d)

  defp sum(list, fun), do: Enum.reduce(list, 0, &(fun.(&1) + &2))
end
