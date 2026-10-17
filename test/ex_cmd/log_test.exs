defmodule ExCmd.LogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExCmd.Process, as: Command

  setup do
    previous = Application.fetch_env(:ex_cmd, :enable_debug_logs)
    previous_level = Logger.get_module_level(ExCmd.Log)

    # The test helper's primary level is :warning. Admit this module's debug
    # messages so the enabled control exercises their lazy functions as well.
    :ok = Logger.put_module_level(ExCmd.Log, :debug)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ex_cmd, :enable_debug_logs, value)
        :error -> Application.delete_env(:ex_cmd, :enable_debug_logs)
      end

      case previous_level do
        [{ExCmd.Log, level}] -> Logger.put_module_level(ExCmd.Log, level)
        [] -> Logger.delete_module_level(ExCmd.Log)
      end
    end)

    :ok
  end

  test "disabled debug does not evaluate its lazy message" do
    Application.put_env(:ex_cmd, :enable_debug_logs, false)

    assert :ok = ExCmd.Log.debug(fn -> evaluate("disabled", :message) end)

    refute_received {:evaluated, :message}
  end

  test "unset debug does not evaluate its lazy message" do
    Application.delete_env(:ex_cmd, :enable_debug_logs)

    assert :ok = ExCmd.Log.debug(fn -> evaluate("unset", :message) end)

    refute_received {:evaluated, :message}
  end

  test "enabled debug evaluates the lazy message once and retains metadata" do
    Application.put_env(:ex_cmd, :enable_debug_logs, true)

    log =
      capture_log([level: :debug, format: "$message $metadata", metadata: [:operation]], fn ->
        assert :ok =
                 ExCmd.Log.debug(fn -> evaluate("lazy-debug", :message) end, operation: "exit")
      end)

    assert log =~ "lazy-debug"
    assert log =~ "operation=exit"
    assert_received {:evaluated, :message}
    refute_received {:evaluated, :message}
  end

  test "disabled debug does not inspect state during real command I/O and shutdown" do
    Application.put_env(:ex_cmd, :enable_debug_logs, false)

    command_pid = exercise_command()

    refute_received {:trace, ^command_pid, :call, {Kernel, :inspect, 2}}
  end

  test "enabled debug inspects state during the same real command lifecycle" do
    Application.put_env(:ex_cmd, :enable_debug_logs, true)

    log =
      capture_log([level: :debug], fn ->
        command_pid = exercise_command()

        assert_received {:trace, ^command_pid, :call, {Kernel, :inspect, 2}}
      end)

    assert log =~ "maybe_shutdown: state:"
  end

  defp exercise_command do
    {:ok, command} = Command.start_link(["cat"])
    command_pid = command.pid
    monitor = Process.monitor(command_pid)

    try do
      # start_link returns before handle_continue opens the real helper/child.
      # Rendezvous before tracing so this proof covers I/O and settlement.
      assert %ExCmd.Process.State{status: :running, os_pid: os_pid} =
               :sys.get_state(command_pid)

      assert is_integer(os_pid) and os_pid > 0

      # This serial case traces only its own command. The suite has no other
      # trace patterns; remove both patterns after the command has settled.
      try do
        assert 1 = :erlang.trace_pattern({Kernel, :inspect, 2}, true, [:local])
        assert 1 = :erlang.trace_pattern({Command, :handle_info, 2}, true, [:local])
        assert 1 = :erlang.trace(command_pid, true, [:call, :arity, {:tracer, self()}])

        payload = "lazy-debug-roundtrip"
        assert :ok = Command.write(command, payload)
        assert read_exact(command, byte_size(payload), []) == payload
        assert :ok = Command.close_stdin(command)
        assert :eof = Command.read(command)
        assert {:ok, 0} = Command.await_exit(command, 5_000)
        assert_receive {:DOWN, ^monitor, :process, ^command_pid, :normal}, 5_000

        # The command has stopped, and this barrier delivers all its traces
        # before either test checks for the absence/presence of inspection.
        delivered = :erlang.trace_delivered(:all)
        assert_receive {:trace_delivered, :all, ^delivered}, 5_000
        assert_received {:trace, ^command_pid, :call, {Command, :handle_info, 2}}

        command_pid
      after
        :erlang.trace_pattern({Kernel, :inspect, 2}, false, [:local])
        :erlang.trace_pattern({Command, :handle_info, 2}, false, [:local])
      end
    after
      if Process.alive?(command_pid), do: Command.await_exit(command, 5_000)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp read_exact(_command, 0, chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp read_exact(command, remaining, chunks) do
    assert {:ok, chunk} = Command.read(command, remaining)
    chunk = IO.iodata_to_binary(chunk)
    assert byte_size(chunk) > 0 and byte_size(chunk) <= remaining
    read_exact(command, remaining - byte_size(chunk), [chunk | chunks])
  end

  defp evaluate(value, label) do
    send(self(), {:evaluated, label})
    value
  end
end
