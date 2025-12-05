defmodule ExCmdTest do
  use ExUnit.Case

  doctest ExCmd

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

  test "stream/2 early termination with non-zero exit does not raise" do
    result =
      ExCmd.stream(["sh", "-c", "echo foo; exit 120"])
      |> Enum.take(1)

    assert result == ["foo\n"]
  end

  test "stream!/2 early termination with non-zero exit raises" do
    assert_raise ExCmd.Stream.AbnormalExit, "program exited due to :epipe error", fn ->
      ExCmd.stream!(["sh", "-c", "echo foo; exit 120"])
      |> Enum.take(1)
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

  test "stream/2 returns exit status as last element" do
    result =
      ExCmd.stream(["sh", "-c", "echo foo; exit 42"])
      |> Enum.to_list()

    assert result == ["foo\n", {:exit, {:status, 42}}]
  end

  test "stream!/2 early termination with ignore_epipe does not raise" do
    result =
      ExCmd.stream!(["cat"], input: Stream.cycle(["data"]), ignore_epipe: true)
      |> Enum.take(1)

    assert is_binary(hd(result))
  end

  test "stream!/2 early termination without ignore_epipe raises on epipe" do
    assert_raise ExCmd.Stream.AbnormalExit, ~r/epipe/, fn ->
      ExCmd.stream!(["cat"], input: Stream.cycle(["data"]))
      |> Enum.take(1)
    end
  end
end
