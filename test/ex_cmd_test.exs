defmodule ExCmdTest do
  use ExUnit.Case
  doctest ExCmd

  test "greets the world" do
    assert ExCmd.hello() == :world
  end
end
