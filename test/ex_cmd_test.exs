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
    [output] = proc_stream |> Enum.to_list()
    assert String.trim(output) == "hello"
  end

  test "when command fail with non-zero exit status" do
    proc_stream = ExCmd.stream!(["sh", "-c", "exit 5"])

    assert_raise ExCmd.Stream.AbnormalExit, "program exited with exit status: 5", fn ->
      proc_stream
      |> Enum.to_list()
    end
  end

  test "abnormal exit status" do
    proc_stream = ExCmd.stream!(["sh", "-c", "exit 5"])

    exit_status =
      try do
        proc_stream
        |> Enum.to_list()

        nil
      rescue
        e in ExCmd.Stream.AbnormalExit ->
          e.exit_status
      end

    assert exit_status == 5
  end
end
