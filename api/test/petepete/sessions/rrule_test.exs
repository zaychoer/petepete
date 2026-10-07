defmodule Petepete.Sessions.RRuleTest do
  use ExUnit.Case, async: true

  alias Petepete.Sessions.RRule

  doctest RRule

  describe "parse/1" do
    test "reads weekly days and the WIB time of day, in canonical form" do
      assert {:ok, rule} = RRule.parse("freq=weekly;byday=sa, th ,TH;BYHOUR=19;BYMINUTE=30")
      assert rule.days == [4, 6]
      assert rule.time == ~T[19:30:00]
      assert RRule.to_string(rule) == "FREQ=WEEKLY;BYDAY=TH,SA;BYHOUR=19;BYMINUTE=30"
    end

    test "a rule without a time parses but has no time of day" do
      assert {:ok, %RRule{days: [4], time: nil}} = RRule.parse("FREQ=WEEKLY;BYDAY=TH")
    end

    test "BYHOUR alone means minute 0" do
      assert {:ok, %RRule{time: ~T[06:00:00]}} = RRule.parse("FREQ=WEEKLY;BYDAY=MO;BYHOUR=6")
    end

    test "anything outside the weekly subset is rejected naming the offender" do
      for {rrule, fragment} <- [
            {"FREQ=DAILY;BYDAY=TH", "FREQ=DAILY"},
            {"FREQ=WEEKLY;INTERVAL=2;BYDAY=TH", "INTERVAL"},
            {"FREQ=WEEKLY;BYDAY=TH;COUNT=5", "COUNT"},
            {"FREQ=WEEKLY;BYDAY=TH;UNTIL=20261231T000000Z", "UNTIL"},
            {"FREQ=MONTHLY;BYMONTHDAY=1", "BYMONTHDAY"},
            {"FREQ=WEEKLY;BYDAY=1TH", "1TH"},
            {"FREQ=WEEKLY;BYDAY=XX", "XX"},
            {"FREQ=WEEKLY", "BYDAY"},
            {"BYDAY=TH", "FREQ=WEEKLY"},
            {"FREQ=WEEKLY;BYDAY=TH;BYHOUR=24", "BYHOUR"},
            {"FREQ=WEEKLY;BYDAY=TH;BYMINUTE=30", "BYHOUR"},
            {"FREQ=WEEKLY;BYDAY=TH;BYDAY=FR", "repeats"},
            {"", "empty"}
          ] do
        assert {:error, message} = RRule.parse(rrule)
        assert message =~ fragment, "#{inspect(rrule)} gave #{inspect(message)}"
      end

      assert {:error, _} = RRule.parse(nil)
    end
  end

  describe "put_time/2" do
    test "adds HH:MM to a rule without time and refuses a second time" do
      {:ok, rule} = RRule.parse("FREQ=WEEKLY;BYDAY=TH")

      assert {:ok, %RRule{time: ~T[19:00:00]}} = RRule.put_time(rule, "19:00")
      assert {:error, "time must" <> _} = RRule.put_time(rule, "25:00")
      assert {:error, "time must" <> _} = RRule.put_time(rule, "7pm")

      {:ok, timed} = RRule.put_time(rule, "19:00")
      assert {:error, "time conflicts" <> _} = RRule.put_time(timed, "20:00")
    end
  end

  describe "occurrence_on/2" do
    setup do
      {:ok, rule} = RRule.parse("FREQ=WEEKLY;BYDAY=TH,FR;BYHOUR=19;BYMINUTE=0")
      {:ok, early} = RRule.parse("FREQ=WEEKLY;BYDAY=FR;BYHOUR=6;BYMINUTE=30")
      %{rule: rule, early: early}
    end

    test "is the WIB wall time converted to UTC, only on the rule's weekdays", %{rule: rule} do
      # 2026-10-08 is a Thursday.
      assert RRule.occurrence_on(rule, ~D[2026-10-08]) == ~U[2026-10-08 12:00:00Z]
      assert RRule.occurrence_on(rule, ~D[2026-10-09]) == ~U[2026-10-09 12:00:00Z]
      assert RRule.occurrence_on(rule, ~D[2026-10-10]) == nil
    end

    test "a morning WIB time falls on the previous UTC date", %{early: early} do
      # Friday 06:30 WIB is Thursday 23:30 UTC.
      assert RRule.occurrence_on(early, ~D[2026-10-09]) == ~U[2026-10-08 23:30:00Z]
    end
  end
end
