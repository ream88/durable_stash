defmodule DurableStash.TestBackendTest do
  use ExUnit.Case, async: true

  alias DurableStash.TestBackend

  setup do
    backend = :"test_backend_#{System.unique_integer([:positive])}"
    start_supervised!({TestBackend, name: backend})
    %{backend: backend}
  end

  describe "get_object/3" do
    test "returns :not_found for missing keys", %{backend: backend} do
      assert TestBackend.get_object(backend, "missing", []) == {:error, :not_found}
    end

    test "round-trips through JSON: atom keys come back as strings", %{backend: backend} do
      assert {:ok, %{etag: etag}} =
               TestBackend.put_object(backend, "key", %{count: 1, nested: %{flag: true}}, [])

      assert is_binary(etag)

      assert {:ok, %{body: body, etag: ^etag}} = TestBackend.get_object(backend, "key", [])
      assert body == %{"count" => 1, "nested" => %{"flag" => true}}
    end
  end

  describe "put_object/4 etag CAS" do
    test "with an etag on a missing object returns :conflict", %{backend: backend} do
      assert TestBackend.put_object(backend, "key", %{}, etag: "1") == {:error, :conflict}
    end

    test "with a stale etag returns :conflict", %{backend: backend} do
      {:ok, %{etag: first_etag}} = TestBackend.put_object(backend, "key", %{"value" => 1}, [])
      {:ok, %{etag: second_etag}} = TestBackend.put_object(backend, "key", %{"value" => 2}, [])
      assert first_etag != second_etag

      assert TestBackend.put_object(backend, "key", %{"value" => 3}, etag: first_etag) ==
               {:error, :conflict}

      assert {:ok, _object} =
               TestBackend.put_object(backend, "key", %{"value" => 3}, etag: second_etag)
    end

    test "unconditional put overwrites and rotates the etag", %{backend: backend} do
      {:ok, %{etag: first_etag}} = TestBackend.put_object(backend, "key", %{"value" => 1}, [])
      {:ok, %{etag: second_etag}} = TestBackend.put_object(backend, "key", %{"value" => 2}, [])
      assert first_etag != second_etag

      assert {:ok, %{body: %{"value" => 2}}} = TestBackend.get_object(backend, "key", [])
    end
  end

  describe "try_claim/3" do
    test "claims a fresh key, rejects a second claim", %{backend: backend} do
      assert {:ok, {:claimed, etag}} = TestBackend.try_claim(backend, "key", %{"owner" => "a"})
      assert is_binary(etag)

      assert TestBackend.try_claim(backend, "key", %{"owner" => "b"}) ==
               {:error, :already_claimed}

      assert {:ok, %{body: %{"owner" => "a"}}} = TestBackend.get_object(backend, "key", [])
    end
  end

  describe "delete_object/2" do
    test "deletes existing keys, errors on missing ones", %{backend: backend} do
      {:ok, _object} = TestBackend.put_object(backend, "key", %{}, [])

      assert TestBackend.delete_object(backend, "key") == :ok
      assert TestBackend.get_object(backend, "key", []) == {:error, :not_found}
      assert TestBackend.delete_object(backend, "key") == {:error, :not_found}
    end
  end

  describe "update_object/4" do
    test "applies the function to the decoded body", %{backend: backend} do
      {:ok, _object} = TestBackend.put_object(backend, "counter", %{"count" => 1}, [])

      update_fn = fn %{body: %{"count" => count}} -> {:ok, %{"count" => count + 1}} end

      assert {:ok, %{body: %{"count" => 2}}} =
               TestBackend.update_object(backend, "counter", update_fn, [])

      assert {:ok, %{body: %{"count" => 2}}} = TestBackend.get_object(backend, "counter", [])
    end

    test "returns :not_found for missing keys", %{backend: backend} do
      update_fn = fn _object -> {:ok, %{}} end
      assert TestBackend.update_object(backend, "missing", update_fn, []) == {:error, :not_found}
    end

    test "aborts when the function returns an error", %{backend: backend} do
      {:ok, _object} = TestBackend.put_object(backend, "key", %{"value" => 1}, [])

      update_fn = fn _object -> {:error, :nope} end
      assert TestBackend.update_object(backend, "key", update_fn, []) == {:error, :nope}

      assert {:ok, %{body: %{"value" => 1}}} = TestBackend.get_object(backend, "key", [])
    end

    test "concurrent increments do not lose updates", %{backend: backend} do
      {:ok, _object} = TestBackend.put_object(backend, "counter", %{"count" => 0}, [])

      increment = fn %{body: %{"count" => count}} -> {:ok, %{"count" => count + 1}} end

      tasks =
        for _index <- 1..25 do
          Task.async(fn ->
            TestBackend.update_object(backend, "counter", increment, max_retries: 1000)
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &match?({:ok, _object}, &1))

      assert {:ok, %{body: %{"count" => 25}}} = TestBackend.get_object(backend, "counter", [])
    end
  end

  describe "list_all_objects_stream/3" do
    test "lists keys under a prefix with etags", %{backend: backend} do
      {:ok, %{etag: etag_a}} = TestBackend.put_object(backend, "app/a", %{}, [])
      {:ok, %{etag: etag_b}} = TestBackend.put_object(backend, "app/b", %{}, [])
      {:ok, _object} = TestBackend.put_object(backend, "other/c", %{}, [])

      listed = Enum.to_list(TestBackend.list_all_objects_stream(backend, "app/", []))

      assert listed == [
               %{key: "app/a", etag: etag_a},
               %{key: "app/b", etag: etag_b}
             ]
    end
  end
end
