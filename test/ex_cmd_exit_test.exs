defmodule ExCmdExitTest do
  use ExUnit.Case, async: false

  # currently running `elixir` command is not working in Windows
  @tag os: :unix
  test "if it kills external command on abnormal vm exit" do
    ex_cmd_expr = ~S{ExCmd.stream!(["sleep", "10"]) |> Stream.run()}

    port =
      Port.open(
        {:spawn, "elixir -S mix run -e '#{ex_cmd_expr}'"},
        [:stderr_to_stdout, :use_stdio, :exit_status, :binary, :hide]
      )

    port_info = Port.info(port)
    os_pid = port_info[:os_pid]

    on_exit(fn ->
      os_process_alive?(os_pid) && os_process_kill(os_pid)
    end)

    assert os_process_alive?(os_pid)

    [_, cmd_pid] = capture_output!(port, ~r/os pid: ([0-9]+)/)

    cmd_pid = String.to_integer(cmd_pid)
    assert os_process_alive?(cmd_pid)

    assert {:ok, _msg} = os_process_kill(os_pid)

    # wait for the cleanup
    :timer.sleep(3000)

    refute os_process_alive?(os_pid)
    refute os_process_alive?(cmd_pid)
  end

  defp os_process_alive?(pid) do
    if windows?() do
      case cmd(["tasklist", "/fi", "pid eq #{pid}"]) do
        {"INFO: No tasks are running which match the specified criteria.\r\n", 0} -> false
        {_, 0} -> true
      end
    else
      match?({_, 0}, cmd(["ps", "-p", to_string(pid)]))
    end
  end

  defp os_process_kill(pid) do
    if windows?() do
      cmd(["taskkill", "/pid", "#{pid}", "/f"])
    else
      cmd(["kill", "-SIGKILL", "#{pid}"])
    end
    |> case do
      {msg, 0} -> {:ok, msg}
      {msg, status} -> {:error, status, msg}
    end
  end

  defp windows?, do: :os.type() == {:win32, :nt}

  def cmd([cmd | args]), do: System.cmd(cmd, args, stderr_to_stdout: true)

  defp capture_output!(port, regexp, acc \\ "") do
    receive do
      {^port, {:data, bin}} ->
        output = acc <> bin

        if match = Regex.run(regexp, output) do
          match
        else
          capture_output!(port, regexp, output)
        end
    after
      5000 ->
        raise "timeout while waiting for the iex prompt, acc: #{acc}"
    end
  end
end
