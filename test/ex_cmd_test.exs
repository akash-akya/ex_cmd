defmodule ExCmdTest do
  use ExUnit.Case

  test "stream" do
    str = "hello"

    output =
      Stream.map(1..1000, fn _ -> str end)
      |> ExCmd.stream("cat")
      |> Enum.into("")

    assert IO.iodata_length(output) == 1000 * String.length(str)
  end
end
