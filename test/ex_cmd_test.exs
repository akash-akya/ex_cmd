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

  test "stream without stdin" do
    proc_stream = ExCmd.stream!("echo", ["hello"], %{no_stdin: true})
    output = proc_stream |> Enum.to_list()
    assert output == ["hello\n"]
  end
end
