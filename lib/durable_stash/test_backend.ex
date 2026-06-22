defmodule DurableStash.TestBackend do
  @moduledoc """
  In-memory `DurableServer.StorageBackend` for dev and test.

  Drop-in compatible with `DurableServer.Backends.ObjectStore`, including its
  JSON round-trip: stored bodies are encoded with `JSON.encode!/1`, so state
  comes back with string keys exactly as it would from S3. Etag CAS
  (`try_claim/3`, `put_object/4` with `:etag`, `update_object/4`) is
  implemented faithfully — DurableServer's locking depends on it.

  Storage lives in a named `Agent`, so it survives DurableServer supervisor
  restarts (the deploy-simulation scenario). Start it explicitly:

      # test
      start_supervised!({DurableStash.TestBackend, name: MyBackend})

      # dev supervision tree
      children = [
        {DurableStash.TestBackend, name: MyBackend},
        {DurableServer.Supervisor,
         name: MySupervisor, prefix: "dev/", backend: {DurableStash.TestBackend, name: MyBackend}}
      ]

  If the named agent is not running when `init_backend/1` is called, it is
  started unlinked as a convenience for one-off scripts.
  """

  @behaviour DurableServer.StorageBackend

  alias DurableServer.Meta
  alias DurableServer.StoredState

  @default_name __MODULE__

  ## Process lifecycle

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, @default_name),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    Agent.start_link(fn -> empty_store() end, name: name)
  end

  @doc "Drops every stored object. Useful between tests sharing a named backend."
  def reset(name \\ @default_name) do
    Agent.update(name, fn _store -> empty_store() end)
  end

  @doc "Returns the raw stored objects (`%{key => %{body: encoded, etag: etag}}`)."
  def dump(name \\ @default_name) do
    Agent.get(name, fn %{objects: objects} -> objects end)
  end

  ## StorageBackend callbacks

  @impl true
  def init_backend(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, @default_name)
    ensure_agent_started(name)

    {:ok,
     %{
       state: name,
       defaults: %{
         heartbeat_tracking_mode: :poll,
         discovery_interval_ms: 60_000,
         heartbeat_interval_ms: 10_000,
         heartbeat_reconcile_interval_ms: 10_000
       },
       features: %{
         heartbeat_subscribe?: false
       }
     }}
  end

  def init_backend(opts) when is_map(opts), do: opts |> Map.to_list() |> init_backend()

  @impl true
  def ensure_ready(name) do
    if Process.whereis(name) do
      :ok
    else
      {:error, {:test_backend_not_started, name}}
    end
  end

  @impl true
  def get_object(name, key, _opts) do
    case Agent.get(name, fn %{objects: objects} -> Map.fetch(objects, key) end) do
      {:ok, %{body: encoded, etag: etag}} ->
        case decode_body(encoded) do
          {:ok, body} -> {:ok, %{body: body, etag: etag}}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @impl true
  def list_all_objects_stream(name, prefix, _opts) do
    name
    |> Agent.get(fn %{objects: objects} -> objects end)
    |> Enum.filter(fn {key, _object} -> String.starts_with?(key, prefix) end)
    |> Enum.sort_by(fn {key, _object} -> key end)
    |> Enum.map(fn {key, %{etag: etag}} -> %{key: key, etag: etag} end)
  end

  @impl true
  def put_object(name, key, data, opts) do
    with {:ok, encoded} <- encode_body(data) do
      expected_etag = Keyword.get(opts, :etag)

      result =
        Agent.get_and_update(name, fn %{objects: objects} = store ->
          case Map.fetch(objects, key) do
            :error when is_binary(expected_etag) ->
              {{:error, :conflict}, store}

            {:ok, %{etag: current_etag}}
            when is_binary(expected_etag) and current_etag != expected_etag ->
              {{:error, :conflict}, store}

            _existing_or_unconditional ->
              etag = new_etag()

              {{:ok, etag}, %{store | objects: Map.put(objects, key, %{body: encoded, etag: etag})}}
          end
        end)

      case result do
        {:ok, etag} -> {:ok, %{body: data, etag: etag}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def delete_object(name, key) do
    Agent.get_and_update(name, fn %{objects: objects} = store ->
      if Map.has_key?(objects, key) do
        {:ok, %{store | objects: Map.delete(objects, key)}}
      else
        {{:error, :not_found}, store}
      end
    end)
  end

  @impl true
  def try_claim(name, key, body) do
    with {:ok, encoded} <- encode_body(body) do
      Agent.get_and_update(name, fn %{objects: objects} = store ->
        if Map.has_key?(objects, key) do
          {{:error, :already_claimed}, store}
        else
          etag = new_etag()

          {{:ok, {:claimed, etag}}, %{store | objects: Map.put(objects, key, %{body: encoded, etag: etag})}}
        end
      end)
    end
  end

  @impl true
  def update_object(name, key, update_fn, opts) when is_function(update_fn, 1) do
    max_retries = Keyword.get(opts, :max_retries, 5)
    do_update_object(name, key, update_fn, 0, max_retries)
  end

  @impl true
  def encode(_name, data), do: encode_body(data)

  @impl true
  def decode(_name, data), do: decode_body(data)

  ## Internals

  defp do_update_object(_name, _key, _update_fn, attempt, max_retries) when attempt > max_retries do
    {:error, :max_retries_exceeded}
  end

  defp do_update_object(name, key, update_fn, attempt, max_retries) do
    with {:ok, %{body: body, etag: etag}} <- get_object(name, key, []),
         {:ok, new_body} <- update_fn.(%{body: body, etag: etag}) do
      case put_object(name, key, new_body, etag: etag) do
        {:ok, updated_object} ->
          {:ok, updated_object}

        {:error, :conflict} ->
          do_update_object(name, key, update_fn, attempt + 1, max_retries)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_agent_started(name) do
    case Agent.start(fn -> empty_store() end, name: name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp empty_store, do: %{objects: %{}}

  defp new_etag do
    [:positive, :monotonic]
    |> :erlang.unique_integer()
    |> Integer.to_string()
  end

  # Encoding mirrors DurableServer.Backends.ObjectStore exactly so that state
  # round-trips the same way it would through S3 (JSON, string keys).

  defp encode_body(%StoredState{meta: %Meta{}} = data) do
    {:ok, JSON.encode!(StoredState.to_object_store_term(data))}
  rescue
    error in [ArgumentError, RuntimeError, Protocol.UndefinedError] -> {:error, error}
  end

  defp encode_body(data) do
    {:ok, JSON.encode!(data)}
  rescue
    error in [ArgumentError, RuntimeError, Protocol.UndefinedError] -> {:error, error}
  end

  defp decode_body(encoded) when is_binary(encoded) do
    data = JSON.decode!(encoded)

    case StoredState.from_object_store_term(data) do
      {:ok, body} -> {:ok, body}
      :not_stored_state -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  catch
    kind, reason ->
      {:error, {kind, reason, encoded}}
  end

  defp decode_body(other), do: {:error, {:error, {:unexpected_encoded_value, other}, other}}
end
