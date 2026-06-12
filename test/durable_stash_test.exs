defmodule DurableStashTest do
  use ExUnit.Case
  doctest DurableStash

  test "greets the world" do
    assert DurableStash.hello() == :world
  end
end
