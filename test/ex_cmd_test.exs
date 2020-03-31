defmodule ExCmdTest do
  use ExUnit.Case

  test "stream" do
    str = "hello"

    proc_stream = ExCmd.stream!("cat")

    Task.async(fn ->
      Stream.map(1..1000, fn _ -> str end)
      |> Enum.into(proc_stream)
    end)

    output =
      proc_stream
      |> Enum.into("")

    assert IO.iodata_length(output) == 1000 * String.length(str)
  end
end
