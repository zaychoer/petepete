defmodule Petepete.Contract do
  @moduledoc """
  The wire contract (ADR-0004): one recorded, committed JSON response per client-facing
  route variant and per error code, kept in `contract/` at the repository root. Controller
  tests call `check!/3` on the response they already assert on; the app and the web client
  load the same files for their fakes.

  ## Names

    * Route samples: `"<resource>.<variant>"`, e.g. `"pay_page.unpaid"`, stored in
      `contract/samples/<name>.json` and listed under their route in `contract/manifest.json`.
    * Error samples: `"errors/<code>"`, e.g. `"errors/not_found"`, stored in
      `contract/samples/errors/<code>.json` and listed in the manifest's `errors`. The body
      must carry `"error"` (equal to `<code>`) and a non-empty `"message"`.

  ## Shape rules (`mismatches/2`)

    * Objects: the same key set.
    * Scalars: the same JSON type (`integer`, `float`, `string`, `boolean`). A float and an
      integer are different types; values, ids, timestamps and tokens are free.
    * `null` on either side matches anything (nullable or unknown), including whole subtrees.
    * Arrays: every response element must match the shape of the sample's first element; an
      empty sample array places no constraint, so record samples with non-empty arrays.

  ## Vacuous samples

  `audit/4` rejects a committed sample with an empty array anywhere in its shape-relevant
  tree (object values and the first element of arrays), because an empty sample array
  constrains nothing. A legitimately always-empty array is listed in `@allowed_empty` below
  with the reason.

  ## Every sample is exercised

  `check!/3` records the names it compared (`exercised/0`). When the whole suite runs
  (`mix test` without file, line or tag filters, and so `mix precommit`; the `test` alias in
  `mix.exs` sets `PETEPETE_FULL_SUITE=1`) `install_exercise_check/0`'s `ExUnit.after_suite`
  hook fails the run, listing every manifest sample no test checked. It skips when any test
  was filtered, failed or skipped.

  ## Recording

  With `CONTRACT_RECORD=1` (or `record: true`), `check!/3` rewrites the sample (sorted keys,
  two-space indent, trailing newline) and registers it in the manifest instead of comparing.
  The directory is `contract/` unless the `:contract_dir` app env of `:petepete` says
  otherwise (unit tests point it at a temp dir).
  """

  @default_dir Path.expand("../../../contract", __DIR__)

  @exercised :petepete_contract_exercised

  # Arrays that are legitimately always empty in their variant. Keys are sample names, values
  # the `$.path` of the array (`[]` stands for the first element of an array). Every entry
  # needs the reason that the array's element shape is recorded by another sample.
  @allowed_empty %{
    # `can_pay` is false, so `methods` is empty; `pay_page.unpaid` records the element shape.
    "pay_page.needs_review" => ["$.methods"],
    "pay_page.paid" => ["$.methods"],
    # A group with nothing open; `group_home.with_session` records both bill lists.
    "group_home.quiet" => ["$.needs_review_bills", "$.unpaid_bills"]
  }

  @route_name ~r/\A[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*\z/
  @error_name ~r{\Aerrors/[a-z][a-z0-9_]*\z}

  @type problem :: String.t()

  @doc "The contract directory (`:contract_dir` app env, else the repository's `contract/`)."
  @spec dir() :: Path.t()
  def dir, do: Application.get_env(:petepete, :contract_dir, @default_dir)

  @doc "Whether `CONTRACT_RECORD=1` is set."
  @spec record?() :: boolean()
  def record?, do: System.get_env("CONTRACT_RECORD") == "1"

  @doc """
  Checks `response` (a `Plug.Conn` after a request, or a decoded JSON term) against the sample
  `name`, or records it when recording.

  Options:

    * `:route` - the manifest route key (`"GET /api/pay/:token"`) a recorded route sample is
      registered under. Derived from a conn's method and matched route pattern; required when
      recording a non-conn response. Ignored for error samples.
    * `:record` - overrides `CONTRACT_RECORD`.

  Raises `ExUnit.AssertionError` listing the JSON path of every mismatch.
  """
  @spec check!(String.t(), Plug.Conn.t() | term(), keyword()) :: :ok
  def check!(name, response, opts \\ []) when is_binary(name) do
    kind = kind!(name)
    body = body(response)
    if kind == :error, do: assert_error_body!(name, body)

    if Keyword.get(opts, :record, record?()) do
      record!(name, kind, body, route(kind, response, opts))
    else
      compare!(name, body)
    end

    track(name)
    :ok
  end

  @doc """
  Creates the table that remembers which samples `check!/3` compared and, when
  `PETEPETE_FULL_SUITE=1` (set by the `test` alias for a run without file/line/tag filters),
  installs the `ExUnit.after_suite` hook that fails the run on unexercised samples. Call it
  once from `test_helper.exs`.
  """
  @spec install_exercise_check() :: :ok
  def install_exercise_check do
    :ets.new(@exercised, [:named_table, :public, :set])

    if System.get_env("PETEPETE_FULL_SUITE") == "1" do
      ExUnit.after_suite(fn results -> verify_exercised(results) end)
    end

    :ok
  end

  @doc "The sample names `check!/3` compared so far in this run (default contract dir only)."
  @spec exercised() :: [String.t()]
  def exercised do
    if :ets.whereis(@exercised) == :undefined,
      do: [],
      else: :ets.select(@exercised, [{{:"$1"}, [], [:"$1"]}])
  end

  @doc "The manifest sample names (`\"pay_page.unpaid\"`, `\"errors/not_found\"`) not in `exercised`."
  @spec unexercised(%{String.t() => term()}, [String.t()]) :: [String.t()]
  def unexercised(%{"routes" => routes, "errors" => errors}, exercised) do
    declared =
      Enum.flat_map(routes, fn {_route, names} -> names end) ++
        Enum.map(errors, &("errors/" <> &1))

    declared |> Enum.reject(&(&1 in exercised)) |> Enum.sort()
  end

  defp track(name) do
    if dir() == @default_dir and :ets.whereis(@exercised) != :undefined,
      do: :ets.insert(@exercised, {name})
  end

  defp verify_exercised(%{total: total, failures: failures, skipped: skipped, excluded: excluded}) do
    cond do
      failures > 0 or skipped > 0 or excluded > 0 or total == 0 ->
        :ok

      true ->
        case unexercised(manifest(), exercised()) do
          [] ->
            :ok

          names ->
            IO.puts(:stderr, """

            #{length(names)} contract sample(s) were never checked by a test in this full run:

            #{Enum.map_join(names, "\n", &("  " <> &1))}

            Every sample in contract/manifest.json must be compared by a controller test
            (Contract.check!/3). Add the test, or delete the sample and its manifest entry.
            """)

            System.at_exit(fn _ -> exit({:shutdown, 1}) end)
        end
    end
  end

  @doc """
  The mismatches between `sample` and `actual` (both decoded JSON) as
  `"$.path: reason"` strings; `[]` when `actual` has the sample's shape.
  """
  @spec mismatches(term(), term()) :: [problem()]
  def mismatches(sample, actual), do: sample |> walk(actual, "$", []) |> Enum.reverse()

  @doc "The decoded manifest (`%{\"routes\" => %{}, \"errors\" => []}` when none is recorded yet)."
  @spec manifest() :: %{String.t() => term()}
  def manifest, do: read_manifest(dir())

  @doc "The decoded sample `name` (`\"pay_page.unpaid\"` or `\"errors/not_found\"`)."
  @spec sample!(String.t()) :: term()
  def sample!(name), do: name |> sample_path(dir()) |> File.read!() |> Jason.decode!()

  @doc """
  Coverage problems of the contract directory: `required` are the route keys that must have
  samples, `pending` those still allowed not to. Checks that every required route is recorded
  or pending, nothing pending is recorded or unknown, the manifest lists only required routes
  with existing files, no sample file is missing from the manifest, and every error sample has
  a `message`, and no sample has an empty array outside `allowed_empty` (default: the table
  in this module).
  """
  @spec audit([String.t()], [String.t()], Path.t(), %{String.t() => [String.t()]}) :: [problem()]
  def audit(required, pending, dir \\ dir(), allowed_empty \\ @allowed_empty) do
    case read_manifest_checked(dir) do
      {:ok, %{"routes" => routes, "errors" => errors}} ->
        audit_manifest(required, pending, routes, errors, dir, allowed_empty)

      {:error, problem} ->
        [problem]
    end
  end

  ## Compare

  defp compare!(name, body) do
    path = sample_path(name, dir())

    sample =
      case File.read(path) do
        {:ok, json} ->
          Jason.decode!(json)

        {:error, reason} ->
          fail!("""
          No recorded sample for #{inspect(name)} (#{reason}): #{shown(path, dir())}.
          Record it with `#{record_command()}`.
          """)
      end

    case mismatches(sample, body) do
      [] ->
        :ok

      problems ->
        fail!("""
        The response no longer has the shape of #{shown(path, dir())} (#{inspect(name)}):

        #{Enum.map_join(problems, "\n", &("  " <> &1))}

        If the change is intended, re-record with `#{record_command()}`
        and update the app and web clients in the same change.
        """)
    end
  end

  defp walk(nil, _actual, _path, acc), do: acc
  defp walk(_sample, nil, _path, acc), do: acc

  defp walk(sample, actual, path, acc) when is_map(sample) and is_map(actual) do
    sample_keys = sample |> Map.keys() |> Enum.sort()
    actual_keys = actual |> Map.keys() |> Enum.sort()

    acc =
      Enum.reduce(sample_keys -- actual_keys, acc, fn key, acc ->
        ["#{path}.#{key}: missing from the response (the sample has it)" | acc]
      end)

    acc =
      Enum.reduce(actual_keys -- sample_keys, acc, fn key, acc ->
        ["#{path}.#{key}: not in the sample (the response has it)" | acc]
      end)

    sample_keys
    |> Enum.filter(&Map.has_key?(actual, &1))
    |> Enum.reduce(acc, fn key, acc -> walk(sample[key], actual[key], "#{path}.#{key}", acc) end)
  end

  defp walk([], actual, _path, acc) when is_list(actual), do: acc

  defp walk([first | _], actual, path, acc) when is_list(actual) do
    actual
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {element, index}, acc ->
      walk(first, element, "#{path}[#{index}]", acc)
    end)
  end

  defp walk(sample, actual, path, acc) do
    if json_type(sample) == json_type(actual) do
      acc
    else
      [
        "#{path}: the sample has #{json_type(sample)}, the response has #{json_type(actual)}"
        | acc
      ]
    end
  end

  defp json_type(value) when is_integer(value), do: "integer"
  defp json_type(value) when is_float(value), do: "float"
  defp json_type(value) when is_binary(value), do: "string"
  defp json_type(value) when is_boolean(value), do: "boolean"
  defp json_type(value) when is_list(value), do: "array"
  defp json_type(value) when is_map(value), do: "object"

  ## Record

  defp record!(name, kind, body, route) do
    dir = dir()
    write_if_changed!(sample_path(name, dir), encode(body))

    :global.trans({__MODULE__, :manifest}, fn ->
      manifest = read_manifest(dir)

      updated =
        case kind do
          :error ->
            code = String.replace_prefix(name, "errors/", "")
            Map.update!(manifest, "errors", &Enum.sort(Enum.uniq([code | &1])))

          :route ->
            Map.update!(manifest, "routes", fn routes ->
              Map.update(routes, route, [name], &Enum.sort(Enum.uniq([name | &1])))
            end)
        end

      write_if_changed!(manifest_path(dir), encode(updated))
    end)

    :ok
  end

  defp route(:error, _response, _opts), do: nil

  defp route(:route, response, opts) do
    case {Keyword.get(opts, :route), response} do
      {route, _} when is_binary(route) ->
        route

      {nil, %Plug.Conn{private: %{phoenix_router: router}} = conn} ->
        case Phoenix.Router.route_info(router, conn.method, conn.request_path, conn.host) do
          %{route: pattern} -> conn.method <> " " <> pattern
          :error -> raise ArgumentError, "no route matches #{conn.method} #{conn.request_path}"
        end

      _ ->
        raise ArgumentError,
              "recording a route sample needs `route: \"GET /api/...\"` unless a conn is given"
    end
  end

  defp write_if_changed!(path, content) do
    if File.read(path) != {:ok, content} do
      File.mkdir_p!(Path.dirname(path))
      tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"
      File.write!(tmp, content)
      File.rename!(tmp, path)
    end
  end

  # Sorted keys and pretty printing, so a re-record only changes what changed.
  defp encode(term), do: Jason.encode!(sort_keys(term), pretty: true) <> "\n"

  defp sort_keys(map) when is_map(map) do
    map
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> {key, sort_keys(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(value), do: value

  ## Names, paths, input

  defp kind!(name) do
    cond do
      Regex.match?(@error_name, name) ->
        :error

      Regex.match?(@route_name, name) ->
        :route

      true ->
        raise ArgumentError,
              "sample name #{inspect(name)} must be \"<resource>.<variant>\" or \"errors/<code>\" (lowercase, digits, underscores)"
    end
  end

  defp sample_path(name, dir), do: Path.join([dir, "samples", name <> ".json"])
  defp manifest_path(dir), do: Path.join(dir, "manifest.json")

  # Whatever the caller has (a conn, a map with atom keys or structs) goes through JSON, so
  # the comparison sees exactly what a client would.
  defp body(%Plug.Conn{resp_body: resp_body}), do: Jason.decode!(IO.iodata_to_binary(resp_body))
  defp body(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp assert_error_body!(name, body) do
    code = String.replace_prefix(name, "errors/", "")

    case body do
      %{"error" => ^code, "message" => message} when is_binary(message) and message != "" ->
        :ok

      _ ->
        fail!(
          "An error response must be an object with \"error\": #{inspect(code)} and a " <>
            "non-empty \"message\" (#{inspect(name)}); got #{inspect(body)}"
        )
    end
  end

  defp fail!(message), do: raise(ExUnit.AssertionError, message: message)

  defp record_command do
    file =
      with {:current_stacktrace, stacktrace} <- Process.info(self(), :current_stacktrace),
           {_, _, _, location} <-
             Enum.find(stacktrace, fn {_, _, _, location} ->
               String.ends_with?(to_string(location[:file]), "_test.exs")
             end) do
        location |> Keyword.fetch!(:file) |> to_string() |> Path.relative_to_cwd()
      else
        _ -> "<test file>"
      end

    "CONTRACT_RECORD=1 mix test #{file}"
  end

  # `contract/samples/x.json`: relative to the directory that holds the contract directory.
  defp shown(path, dir), do: Path.relative_to(path, Path.dirname(dir))

  ## Audit

  defp read_manifest(dir) do
    case read_manifest_checked(dir) do
      {:ok, manifest} -> manifest
      {:error, problem} -> raise problem
    end
  end

  defp read_manifest_checked(dir) do
    case File.read(manifest_path(dir)) do
      {:error, :enoent} ->
        {:ok, %{"routes" => %{}, "errors" => []}}

      {:error, reason} ->
        {:error, "contract/manifest.json cannot be read: #{reason}"}

      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"routes" => routes, "errors" => errors} = manifest}
          when is_map(routes) and is_list(errors) ->
            {:ok, manifest}

          _ ->
            {:error,
             ~s(contract/manifest.json must be {"routes": {route: [names]}, "errors": [codes]})}
        end
    end
  end

  defp audit_manifest(required, pending, routes, errors, dir, allowed_empty) do
    recorded = for {route, names} <- routes, names != [], do: route

    declared =
      Enum.flat_map(routes, fn {_route, names} -> names end) ++
        Enum.map(errors, &("errors/" <> &1))

    unrecorded =
      for route <- required -- recorded, route not in pending do
        "#{route} is a client route with no recorded sample: record one with Contract.check! " <>
          "(CONTRACT_RECORD=1) or list it in @pending_samples"
      end

    stale_pending =
      for route <- pending do
        cond do
          route not in required -> "@pending_samples lists #{route}, which is not a client route"
          route in recorded -> "@pending_samples lists #{route}, which now has samples: remove it"
          true -> nil
        end
      end

    not_client =
      for route <- Map.keys(routes), route not in required do
        "manifest lists #{route}, which is not a client route"
      end

    missing_files =
      for name <- declared, not File.regular?(sample_path(name, dir)) do
        "manifest lists #{name} but #{shown(sample_path(name, dir), dir)} is missing"
      end

    orphans =
      for file <- sample_files(dir), file not in declared do
        "#{shown(sample_path(file, dir), dir)} is not in the manifest: record it through Contract.check! or delete it"
      end

    unreadable_or_no_message =
      declared
      |> Enum.filter(&File.regular?(sample_path(&1, dir)))
      |> Enum.flat_map(&sample_problems(&1, dir))

    vacuous = vacuous_problems(declared, dir, allowed_empty)

    unrecorded ++
      Enum.reject(stale_pending, &is_nil/1) ++
      not_client ++ missing_files ++ orphans ++ unreadable_or_no_message ++ vacuous
  end

  defp vacuous_problems(declared, dir, allowed_empty) do
    samples =
      for name <- declared,
          File.regular?(sample_path(name, dir)),
          {:ok, body} <- [sample_path(name, dir) |> File.read!() |> Jason.decode()],
          do: {name, body}

    unlisted =
      for {name, body} <- samples,
          path <- empty_arrays(body, "$") -- Map.get(allowed_empty, name, []) do
        "#{shown(sample_path(name, dir), dir)}: #{path} is an empty array, so its element " <>
          "shape is not recorded. Record the sample with elements, or list the path in " <>
          "@allowed_empty of #{inspect(__MODULE__)} with the reason"
      end

    stale =
      for {name, paths} <- allowed_empty, path <- paths do
        case List.keyfind(samples, name, 0) do
          nil ->
            "@allowed_empty lists #{name}, which is not a recorded sample"

          {_, body} ->
            if path in empty_arrays(body, "$"),
              do: nil,
              else:
                "@allowed_empty lists #{path} of #{name}, which is not an empty array: remove it"
        end
      end

    unlisted ++ Enum.reject(stale, &is_nil/1)
  end

  # Paths of the empty arrays that matter for the shape: object values and the first element
  # of each array (`[]` in the path).
  defp empty_arrays(map, path) when is_map(map),
    do: map |> Enum.sort() |> Enum.flat_map(fn {k, v} -> empty_arrays(v, "#{path}.#{k}") end)

  defp empty_arrays([], path), do: [path]
  defp empty_arrays([first | _], path), do: empty_arrays(first, path <> "[]")
  defp empty_arrays(_scalar, _path), do: []

  defp sample_files(dir) do
    root = Path.join(dir, "samples")

    root
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.relative_to(root) |> String.replace_suffix(".json", "")))
    |> Enum.sort()
  end

  defp sample_problems(name, dir) do
    path = shown(sample_path(name, dir), dir)

    case sample_path(name, dir) |> File.read!() |> Jason.decode() do
      {:error, _} ->
        ["#{path} is not valid JSON"]

      {:ok, body} ->
        if String.starts_with?(name, "errors/") do
          code = String.replace_prefix(name, "errors/", "")

          case body do
            %{"error" => ^code, "message" => message} when is_binary(message) and message != "" ->
              []

            _ ->
              ["#{path} must have \"error\": #{inspect(code)} and a non-empty \"message\""]
          end
        else
          []
        end
    end
  end
end
