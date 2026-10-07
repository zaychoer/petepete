defmodule Petepete.ContractTest do
  # Not async: the contract directory is an application env, swapped per test.
  use ExUnit.Case, async: false

  alias Petepete.Contract

  describe "mismatches/2" do
    test "the same shape with different values has no mismatch" do
      sample = %{"id" => 1, "name" => "A", "ok" => true, "tags" => ["x"], "at" => "2026-01-01"}
      actual = %{"id" => 99, "name" => "B", "ok" => false, "tags" => ["y", "z"], "at" => "nope"}

      assert Contract.mismatches(sample, actual) == []
    end

    test "an integer where the sample has a string names the JSON path" do
      assert Contract.mismatches(%{"user" => %{"id" => "7"}}, %{"user" => %{"id" => 7}}) ==
               ["$.user.id: the sample has string, the response has integer"]
    end

    test "a float and an integer are different types, in both directions" do
      assert [_] = Contract.mismatches(%{"n" => 1}, %{"n" => 1.5})
      assert [_] = Contract.mismatches(%{"n" => 1.5}, %{"n" => 1})
    end

    test "a missing key and an extra key are both reported" do
      assert Contract.mismatches(%{"a" => 1, "b" => 2}, %{"a" => 1, "c" => 3}) == [
               "$.b: missing from the response (the sample has it)",
               "$.c: not in the sample (the response has it)"
             ]
    end

    test "every response array element must match the sample's first element" do
      sample = %{"lines" => [%{"label" => "Sewa", "amount" => 1}, %{"label" => "other"}]}

      actual = %{
        "lines" => [
          %{"label" => "A", "amount" => 2},
          %{"label" => "B", "amount" => "3"},
          %{"label" => "C"}
        ]
      }

      assert Contract.mismatches(sample, actual) == [
               "$.lines[1].amount: the sample has integer, the response has string",
               "$.lines[2].amount: missing from the response (the sample has it)"
             ]
    end

    test "nested arrays are compared level by level" do
      assert Contract.mismatches(%{"grid" => [[1]]}, %{"grid" => [[2, 3], [4, "5"]]}) ==
               ["$.grid[1][1]: the sample has integer, the response has string"]
    end

    test "an array where the sample has an object is a type mismatch" do
      assert Contract.mismatches(%{"a" => %{"x" => 1}}, %{"a" => [1]}) ==
               ["$.a: the sample has object, the response has array"]
    end

    test "null on either side matches anything, including whole subtrees" do
      assert Contract.mismatches(%{"a" => nil, "b" => 1}, %{"a" => %{"deep" => [1]}, "b" => nil}) ==
               []

      assert Contract.mismatches(%{"a" => %{"x" => 1}}, %{"a" => nil}) == []
      assert Contract.mismatches(%{"a" => [nil]}, %{"a" => ["s", 2]}) == []
    end

    test "an empty sample array places no constraint, an empty response array always fits" do
      assert Contract.mismatches(%{"a" => []}, %{"a" => [1, "x", %{"k" => 1}]}) == []
      assert Contract.mismatches(%{"a" => [%{"k" => 1}]}, %{"a" => []}) == []
    end
  end

  describe "check!/3 against a contract directory" do
    setup do
      dir = Path.join(System.tmp_dir!(), "contract-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      previous = Application.fetch_env(:petepete, :contract_dir)
      Application.put_env(:petepete, :contract_dir, dir)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:petepete, :contract_dir, value)
          :error -> Application.delete_env(:petepete, :contract_dir)
        end

        File.rm_rf!(dir)
      end)

      %{dir: dir}
    end

    test "recording writes a stable sample and registers the route in the manifest", %{dir: dir} do
      body = %{
        "share" => 34_000,
        "lines" => [%{"label" => "Sewa", "amount" => 1}],
        "attempt" => nil
      }

      Contract.check!("pay_page.unpaid", body, route: "GET /api/pay/:token", record: true)

      assert File.read!(Path.join(dir, "samples/pay_page.unpaid.json")) == """
             {
               "attempt": null,
               "lines": [
                 {
                   "amount": 1,
                   "label": "Sewa"
                 }
               ],
               "share": 34000
             }
             """

      assert File.read!(Path.join(dir, "manifest.json")) == """
             {
               "errors": [],
               "routes": {
                 "GET /api/pay/:token": [
                   "pay_page.unpaid"
                 ]
               }
             }
             """
    end

    test "recording again is stable and keeps the manifest sorted without duplicates", %{dir: dir} do
      route = "GET /api/pay/:token"

      for name <- ["pay_page.void", "pay_page.paid", "pay_page.void"] do
        Contract.check!(name, %{"a" => 1}, route: route, record: true)
      end

      Contract.check!("errors/not_found", %{"error" => "not_found", "message" => "Tidak ada."},
        record: true
      )

      manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

      assert manifest == %{
               "routes" => %{route => ["pay_page.paid", "pay_page.void"]},
               "errors" => ["not_found"]
             }
    end

    test "a recorded conn registers under its method and matched route pattern", %{dir: dir} do
      conn = %Plug.Conn{
        method: "GET",
        host: "www.example.com",
        request_path: "/api/pay/some-token",
        private: %{phoenix_router: PetepeteWeb.Router},
        resp_body: ~s({"status":"unpaid"})
      }

      Contract.check!("pay_page.unpaid", conn, record: true)

      assert Contract.manifest() == %{
               "routes" => %{"GET /api/pay/:token" => ["pay_page.unpaid"]},
               "errors" => []
             }

      assert File.exists?(Path.join(dir, "samples/pay_page.unpaid.json"))
    end

    test "recording a route sample without a route is an error" do
      assert_raise ArgumentError, ~r/needs `route:/, fn ->
        Contract.check!("pay_page.unpaid", %{"a" => 1}, record: true)
      end
    end

    test "a response with the sample's shape passes, including values and atom keys" do
      Contract.check!("pay_page.unpaid", %{"share" => 1, "label" => "a"},
        route: "GET /x",
        record: true
      )

      assert :ok = Contract.check!("pay_page.unpaid", %{share: 2, label: "b"}, record: false)
    end

    test "a changed type fails with the JSON path, the sample file and the re-record hint" do
      sample = %{"share" => 34_000, "lines" => [%{"amount" => 1}]}
      Contract.check!("pay_page.unpaid", sample, route: "GET /x", record: true)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Contract.check!(
            "pay_page.unpaid",
            %{"share" => "34000", "lines" => [%{"amount" => "1"}]},
            record: false
          )
        end

      assert error.message =~ "$.share: the sample has integer, the response has string"
      assert error.message =~ "$.lines[0].amount: the sample has integer, the response has string"
      assert error.message =~ "pay_page.unpaid.json"
      assert error.message =~ "CONTRACT_RECORD=1 mix test test/petepete/contract_test.exs"
    end

    test "a name with no recorded sample fails and says how to record it" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          Contract.check!("pay_page.unpaid", %{"a" => 1}, record: false)
        end

      assert error.message =~ "No recorded sample"
      assert error.message =~ "CONTRACT_RECORD=1"
    end

    test "an error response without a message cannot be checked or recorded" do
      for record <- [true, false] do
        assert_raise ExUnit.AssertionError, ~r/non-empty "message"/, fn ->
          Contract.check!("errors/still_host", %{"error" => "still_host"}, record: record)
        end
      end
    end

    test "an error response whose code differs from the sample name is rejected" do
      assert_raise ExUnit.AssertionError, ~r/"error": "still_host"/, fn ->
        Contract.check!("errors/still_host", %{"error" => "other", "message" => "x"},
          record: true
        )
      end
    end

    test "sample names must be <resource>.<variant> or errors/<code>" do
      for name <- ["pay_page", "Pay.page", "../x.y", "errors/", "a.b.c"] do
        assert_raise ArgumentError, ~r/sample name/, fn ->
          Contract.check!(name, %{}, route: "GET /x", record: true)
        end
      end
    end
  end

  describe "audit/4" do
    setup do
      dir = Path.join(System.tmp_dir!(), "contract-audit-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "samples/errors"))
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    defp write!(dir, path, term) do
      path = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, if(is_binary(term), do: term, else: Jason.encode!(term)))
    end

    defp valid_dir(dir) do
      write!(dir, "manifest.json", %{
        "routes" => %{"GET /api/a" => ["a.one"], "POST /api/b" => ["b.created"]},
        "errors" => ["nope"]
      })

      write!(dir, "samples/a.one.json", %{"x" => 1})
      write!(dir, "samples/b.created.json", %{"x" => 1})
      write!(dir, "samples/errors/nope.json", %{"error" => "nope", "message" => "Gagal."})
    end

    test "a fully recorded contract has no problems", %{dir: dir} do
      valid_dir(dir)
      assert Contract.audit(["GET /api/a", "POST /api/b"], [], dir, %{}) == []
    end

    test "an empty contract directory is fine while every required route is pending", %{dir: dir} do
      assert Contract.audit(["GET /api/a"], ["GET /api/a"], dir, %{}) == []
    end

    test "a required route neither recorded nor pending fails", %{dir: dir} do
      valid_dir(dir)
      assert [problem] = Contract.audit(["GET /api/a", "POST /api/b", "GET /api/c"], [], dir, %{})
      assert problem =~ "GET /api/c is a client route with no recorded sample"
    end

    test "a pending route that is now recorded, or is not a client route, fails", %{dir: dir} do
      valid_dir(dir)

      assert [recorded, unknown] =
               Contract.audit(
                 ["GET /api/a", "POST /api/b"],
                 ["GET /api/a", "GET /api/zzz"],
                 dir,
                 %{}
               )

      assert recorded =~ "GET /api/a, which now has samples"
      assert unknown =~ "GET /api/zzz, which is not a client route"
    end

    test "a manifest route that is not a client route fails", %{dir: dir} do
      valid_dir(dir)
      assert [problem] = Contract.audit(["GET /api/a"], [], dir, %{})
      assert problem =~ "manifest lists POST /api/b, which is not a client route"
    end

    test "a manifest entry whose file is missing fails", %{dir: dir} do
      valid_dir(dir)
      File.rm!(Path.join(dir, "samples/b.created.json"))
      assert [problem] = Contract.audit(["GET /api/a", "POST /api/b"], [], dir, %{})
      assert problem =~ "manifest lists b.created but"
      assert problem =~ "b.created.json is missing"
    end

    test "an error code listed without its file fails", %{dir: dir} do
      valid_dir(dir)
      File.rm!(Path.join(dir, "samples/errors/nope.json"))
      assert [problem] = Contract.audit(["GET /api/a", "POST /api/b"], [], dir, %{})
      assert problem =~ "manifest lists errors/nope but"
    end

    test "a sample file the manifest does not list is an orphan", %{dir: dir} do
      valid_dir(dir)
      write!(dir, "samples/stray.one.json", %{"x" => 1})
      write!(dir, "samples/errors/stray.json", %{"error" => "stray", "message" => "x"})

      assert [one, two] = Contract.audit(["GET /api/a", "POST /api/b"], [], dir, %{})
      assert one =~ "samples/errors/stray.json is not in the manifest"
      assert two =~ "samples/stray.one.json is not in the manifest"
    end

    test "an error sample without a message fails", %{dir: dir} do
      valid_dir(dir)
      write!(dir, "samples/errors/nope.json", %{"error" => "nope"})
      assert [problem] = Contract.audit(["GET /api/a", "POST /api/b"], [], dir, %{})
      assert problem =~ ~s(errors/nope.json must have "error": "nope" and a non-empty "message")
    end

    test "a sample that is not JSON fails", %{dir: dir} do
      valid_dir(dir)
      write!(dir, "samples/a.one.json", "{oops")
      assert [problem] = Contract.audit(["GET /api/a", "POST /api/b"], [], dir, %{})
      assert problem =~ "a.one.json is not valid JSON"
    end

    test "a sample with an empty array anywhere in its shape fails", %{dir: dir} do
      valid_dir(dir)
      write!(dir, "samples/a.one.json", %{"x" => 1, "lines" => [%{"tags" => []}], "none" => []})

      assert [tags, none] = Contract.audit(["GET /api/a", "POST /api/b"], [], dir, %{})
      assert tags =~ "a.one.json: $.lines[].tags is an empty array"
      assert none =~ "a.one.json: $.none is an empty array"
    end

    test "an empty array is fine where the allowed list names its path", %{dir: dir} do
      valid_dir(dir)
      write!(dir, "samples/a.one.json", %{"x" => 1, "lines" => [%{"tags" => []}], "none" => []})
      allowed = %{"a.one" => ["$.lines[].tags", "$.none"]}

      assert Contract.audit(["GET /api/a", "POST /api/b"], [], dir, allowed) == []
    end

    test "an empty array after the first element does not matter", %{dir: dir} do
      valid_dir(dir)
      write!(dir, "samples/a.one.json", %{"rows" => [%{"t" => [1]}, %{"t" => []}]})
      assert Contract.audit(["GET /api/a", "POST /api/b"], [], dir, %{}) == []
    end

    test "an allowed-empty entry that is no longer empty or no longer a sample fails", %{dir: dir} do
      valid_dir(dir)
      allowed = %{"a.one" => ["$.x"], "gone.sample" => ["$.y"]}

      assert [full, gone] = Contract.audit(["GET /api/a", "POST /api/b"], [], dir, allowed)
      assert full =~ "@allowed_empty lists $.x of a.one, which is not an empty array"
      assert gone =~ "@allowed_empty lists gone.sample, which is not a recorded sample"
    end

    test "a malformed manifest fails", %{dir: dir} do
      write!(dir, "manifest.json", ~s({"routes": []}))
      assert [problem] = Contract.audit([], [], dir, %{})
      assert problem =~ "manifest.json must be"
    end
  end

  describe "unexercised/2" do
    @manifest %{
      "routes" => %{"GET /api/a" => ["a.one", "a.two"], "POST /api/b" => ["b.created"]},
      "errors" => ["nope"]
    }

    test "lists the manifest samples no test compared, sorted" do
      assert Contract.unexercised(@manifest, ["a.one", "errors/nope"]) == ["a.two", "b.created"]
    end

    test "is empty when every sample was compared" do
      all = ["a.one", "a.two", "b.created", "errors/nope", "stray.extra"]
      assert Contract.unexercised(@manifest, all) == []
    end
  end
end
