defmodule ExCmdTest do
  use ExUnit.Case

  test "stream" do
    str = "hello"

    output =
      ExCmd.stream!(~w(cat), input: Stream.map(1..1000, fn _ -> str end))
      |> Enum.into("")

    assert IO.iodata_length(output) == 1000 * String.length(str)
  end

  test "stream without stdin" do
    proc_stream = ExCmd.stream!(~w(echo hello))
    output = proc_stream |> Enum.to_list()
    assert output == ["hello\n"]
  end
end
