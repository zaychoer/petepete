defmodule Petepete.SingleCallerTest do
  @moduledoc """
  ADR-0003 as greppable facts about `lib/`: the audit row has one writer, host identity has
  one constructor, and contexts do not authorize.
  """
  use ExUnit.Case, async: true

  # Source lines of `lib/` without comment-only lines: `{file, line_number, text}`.
  defp lib_lines(glob \\ "lib/**/*.ex") do
    for file <- Path.wildcard(glob),
        {text, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        not String.starts_with?(String.trim_leading(text), "#"),
        do: {file, n, text}
  end

  defp matching(lines, regex), do: for({f, n, t} <- lines, t =~ regex, do: "#{f}:#{n}: #{t}")

  test "Audit.record is called only by Petepete.HostAction and defined in Petepete.Ledger.Audit" do
    lines = lib_lines()
    in_file = fn matches, file -> Enum.filter(matches, &String.starts_with?(&1, file <> ":")) end

    calls = matching(lines, ~r/\bAudit\.record\(|import\s+Petepete\.Ledger\.Audit\b/)
    assert [_one] = in_file.(calls, "lib/petepete/host_action.ex")
    assert calls -- in_file.(calls, "lib/petepete/host_action.ex") == []

    defs = matching(lines, ~r/^\s*def\s+record\(/)
    assert [_one] = in_file.(defs, "lib/petepete/ledger/audit.ex")
  end

  test "no {:host, _} actor tuples" do
    assert lib_lines() |> matching(~r/\{:host,/) == []
  end

  # Contexts under lib/petepete receive an Actor the HTTP edge built; only
  # `Petepete.Groups.Policy` authorizes (it defines `authorize/3` and `authorize_actor/3`).
  # Each allowlisted file is justified here.
  # The web edge (`lib/petepete_web/plugs`) is where authorization belongs and is not scanned.
  @authorize_allowlist %{
    "lib/petepete/groups/policy.ex" => "defines authorize/3 and authorize_actor/3",
    "lib/petepete/groups.ex" => "delegates to Policy.authorize/3 in decide_claim"
  }

  test "contexts do not call Groups.authorize" do
    offenders =
      "lib/petepete/**/*.ex"
      |> lib_lines()
      |> Enum.reject(fn {file, _, _} -> Map.has_key?(@authorize_allowlist, file) end)
      |> matching(~r/\bauthorize(_actor)?\(/)

    assert offenders == [],
           "Authorize at the web edge (plugs) and pass an Actor: #{inspect(offenders)}"
  end
end
