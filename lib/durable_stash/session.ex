defmodule DurableStash.Session do
  @moduledoc """
  The durable process behind one browser session.

  One `DurableStash.Session` exists per browser session; every LiveView of
  that session reads and writes through it. State is partitioned per view
  module, and the single-process actor model gives a total order over writes
  — per-key last-write-wins with no timestamps needed.

  State shape (string keys — it round-trips through JSON object storage):

      %{
        "views" => %{
          "Elixir.My.View" => %{"vsn" => 1, "data" => %{"key" => value}}
        },
        "last_seen_at" => unix_millis | nil
      }

  Each view slice carries the vsn its writer declared. A write with a
  different vsn replaces the slice wholesale instead of merging — the adapter
  only does that with a full, migrated key set, so a version bump can never
  mix old- and new-shape keys.

  Every accepted write returns `:sync`, so durability is guaranteed before a
  deploy can take the node down. Writes are rare UI state; the immediate
  object-store PUT is the point, not a cost.
  """

  use DurableServer, vsn: 1

  ## Client API — callers go through DurableServer.Supervisor.lookup/ensure_started_child
  ## to obtain the pid; these are thin call wrappers.

  @doc """
  Merges `changes` (string-keyed map) into the view's slice. Per-key LWW.

  When the stored slice carries a different `vsn`, the slice is replaced with
  `changes` wholesale (see the moduledoc).
  """
  def merge(server, view, changes, vsn \\ 1)
      when is_binary(view) and is_map(changes) and is_integer(vsn) do
    GenServer.call(server, {:merge, view, vsn, changes})
  end

  @doc "Removes `keys` from the view's data map. Unknown keys are ignored."
  def drop(server, view, keys) when is_binary(view) and is_list(keys) do
    GenServer.call(server, {:drop, view, keys})
  end

  @doc "Returns the view's data map, `%{}` when the view has never stashed."
  def get_view(server, view) when is_binary(view) do
    GenServer.call(server, {:get_view, view})
  end

  @doc """
  Returns `{:ok, %{"vsn" => vsn, "data" => data}}` or `:not_found` when the
  view has never stashed.
  """
  def fetch_view(server, view) when is_binary(view) do
    GenServer.call(server, {:fetch_view, view})
  end

  @doc "Drops the view's slice."
  def reset_view(server, view) when is_binary(view) do
    GenServer.call(server, {:reset_view, view})
  end

  ## DurableServer callbacks

  @impl true
  def dump_state(state), do: state

  @impl true
  def load_state(nil, initial_state) when is_map(initial_state) do
    Map.merge(fresh_state(), initial_state)
  end

  def load_state(1, persisted_state) when is_map(persisted_state) do
    Map.merge(fresh_state(), persisted_state)
  end

  # Unknown version: UI-grade state, discard to defaults rather than guess.
  def load_state(_old_vsn, _persisted_state), do: fresh_state()

  @impl true
  def handle_call({:merge, view, vsn, changes}, _from, state) do
    views =
      Map.update(state["views"], view, %{"vsn" => vsn, "data" => changes}, fn
        %{"vsn" => ^vsn, "data" => data} -> %{"vsn" => vsn, "data" => Map.merge(data, changes)}
        _outdated_slice -> %{"vsn" => vsn, "data" => changes}
      end)

    new_state = %{state | "views" => views, "last_seen_at" => now_ms()}
    {:reply, :ok, new_state, :sync}
  end

  def handle_call({:drop, view, keys}, _from, state) do
    case Map.fetch(state["views"], view) do
      {:ok, %{"data" => data} = slice} ->
        new_data = Map.drop(data, keys)

        if map_size(new_data) == map_size(data) do
          {:reply, :ok, state}
        else
          views = Map.put(state["views"], view, %{slice | "data" => new_data})
          new_state = %{state | "views" => views, "last_seen_at" => now_ms()}
          {:reply, :ok, new_state, :sync}
        end

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:get_view, view}, _from, state) do
    slice = Map.get(state["views"], view, %{})
    {:reply, Map.get(slice, "data", %{}), state}
  end

  def handle_call({:fetch_view, view}, _from, state) do
    case Map.fetch(state["views"], view) do
      {:ok, slice} -> {:reply, {:ok, slice}, state}
      :error -> {:reply, :not_found, state}
    end
  end

  def handle_call({:reset_view, view}, _from, state) do
    new_state = %{
      state
      | "views" => Map.delete(state["views"], view),
        "last_seen_at" => now_ms()
    }

    {:reply, :ok, new_state, :sync}
  end

  defp fresh_state, do: %{"views" => %{}, "last_seen_at" => nil}

  defp now_ms, do: System.system_time(:millisecond)
end
