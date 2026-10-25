defmodule ExCmd.DiagnosticsTest do
  @moduledoc "Synthetic env/argv values reach the child but must never enter launcher diagnostics."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias ExCmd.Process, as: Command
  alias ExCmd.Process.Exec

  @env_value "SYNTHETIC_EXCMD_ENV_NOT_A_CREDENTIAL"
  @arg_value "SYNTHETIC_EXCMD_ARG_NOT_A_CREDENTIAL"
  @input_value "SYNTHETIC_PENDING_INPUT_NOT_A_CREDENTIAL"
  @message_value "SYNTHETIC_LAST_MESSAGE_NOT_A_CREDENTIAL"
  @observation_timeout 2_000
  @moduletag :tmp_dir

  setup do
    previous = Application.fetch_env(:ex_cmd, :enable_debug_logs)
    previous_level = Logger.get_module_level(ExCmd.Log)
    Logger.put_module_level(ExCmd.Log, :debug)

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

  defp start_command(options \\ []) do
    {:ok, command} =
      Command.start_link(
        ["sh", "-c", "cat", @arg_value],
        Keyword.merge([env: [{"EX_CMD_SYNTHETIC", @env_value}], stderr: :disable], options)
      )

    on_exit(fn ->
      if Process.alive?(command.pid), do: GenServer.stop(command.pid, :normal, 1000)
    end)

    command
  end

  defp assert_private(text) do
    refute text =~ @env_value
    refute text =~ @arg_value
    refute text =~ @input_value
    refute text =~ @message_value
  end

  test "state inspection and OTP status omit private launch arguments" do
    command = start_command()
    state = :sys.get_state(command.pid)
    assert state.args.env == [{"EX_CMD_SYNTHETIC", @env_value}]
    assert_private(inspect(state, limit: :infinity))
    assert_private(inspect(:sys.get_status(command.pid), limit: :infinity))
    assert :ok = Command.close_stdin(command)
    assert {:ok, 0} = Command.await_exit(command, 1000)
  end

  test "real GenServer crash report omits private launch arguments" do
    command = start_command()
    Process.unlink(command.pid)

    log =
      capture_log(fn ->
        try do
          GenServer.call(
            command.pid,
            :synthetic_unhandled_message,
            1000
          )
        catch
          :exit, _ -> :ok
        end
      end)

    assert log =~ "terminating"
    assert_private(log)
  end

  test "real debug lifecycle omits env and argument values" do
    Application.put_env(:ex_cmd, :enable_debug_logs, true)

    log =
      capture_log([level: :debug], fn ->
        command = start_command()
        assert :ok = Command.write(command, "roundtrip")
        assert {:ok, bytes} = Command.read(command, 9)
        assert IO.iodata_to_binary(bytes) == "roundtrip"
        assert :ok = Command.close_stdin(command)
        assert :eof = Command.read(command)
        assert {:ok, 0} = Command.await_exit(command, 1000)
      end)

    assert log =~ "state:"
    assert_private(log)
  end

  test "private environment and arguments still reach the child unchanged" do
    output =
      ExCmd.stream!(["sh", "-c", ~S(printf '%s|%s' "$EX_CMD_SYNTHETIC" "$0"), @arg_value],
        env: [{"EX_CMD_SYNTHETIC", @env_value}]
      )
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert output == @env_value <> "|" <> @arg_value
  end

  test "pending stdin stays private in state and status while binary delivery remains exact" do
    command = start_command()
    input = :binary.copy(@input_value <> <<0, 255, 13, 10>>, 25_000)
    {writer, monitor} = pending_writer(command, input)

    assert_private(inspect(:sys.get_state(command.pid), limit: :infinity))
    assert_private(inspect(:sys.get_status(command.pid), limit: :infinity))

    digest = delivered_digest(command)
    assert digest == :crypto.hash(:sha256, input)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}, @observation_timeout
    assert {:ok, 0} = Command.await_exit(command, @observation_timeout)
  end

  test "real crash diagnostics omit an actual pending stdin operation" do
    command = start_command()
    Process.unlink(command.pid)
    {writer, writer_monitor} = pending_writer(command, :binary.copy(@input_value, 25_000))
    command_monitor = Process.monitor(command.pid)

    log =
      capture_log(fn ->
        crash_call(command, :synthetic_pending_input_crash)
        assert_receive {:DOWN, ^command_monitor, :process, _, _}, @observation_timeout
      end)

    assert log =~ "terminating"
    assert_private(log)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, _}, @observation_timeout
  end

  test "valid public writes cannot disclose the already pending input when the callback fails" do
    command = start_command()
    Process.unlink(command.pid)
    {writer, writer_monitor} = pending_writer(command, :binary.copy(@input_value, 25_000))
    command_monitor = Process.monitor(command.pid)

    log =
      capture_log(fn ->
        outcome =
          try do
            Command.write(command, @message_value)
            :returned
          catch
            :exit, _ -> :exited
          end

        assert outcome == :exited
        assert_receive {:DOWN, ^command_monitor, :process, _, _}, @observation_timeout
        assert_receive {:DOWN, ^writer_monitor, :process, ^writer, _}, @observation_timeout
        refute Process.alive?(writer)
      end)

    assert log =~ "terminating"
    assert_private(log)
  end

  test "the crashing last message is independently redacted" do
    command = start_command()
    Process.unlink(command.pid)
    monitor = Process.monitor(command.pid)

    log =
      capture_log(fn ->
        crash_call(command, {:synthetic_message_crash, @message_value})
        assert_receive {:DOWN, ^monitor, :process, _, _}, @observation_timeout
      end)

    assert log =~ "terminating"
    assert_private(log)
  end

  test "debug lifecycle omits pending input after its blocked writer dies" do
    Application.put_env(:ex_cmd, :enable_debug_logs, true)

    log =
      capture_log([level: :debug], fn ->
        command = start_command()
        {writer, monitor} = pending_writer(command, :binary.copy(@input_value, 25_000))
        Process.exit(writer, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}, @observation_timeout
        # Closing the owner's remaining pipe through the public API settles cat
        # even though it was blocked on output when the stdin owner disappeared.
        command_monitor = Process.monitor(command.pid)
        result = Command.await_exit(command, @observation_timeout)

        assert match?({:ok, status} when is_integer(status), result) or
                 result == {:error, :killed}

        assert_receive {:DOWN, ^command_monitor, :process, _, _}, @observation_timeout
        refute Process.alive?(command.pid)
      end)

    assert log =~ "pipe owner exit"
    assert log =~ "state:"
    assert_private(log)
  end

  defp pending_writer(command, input) do
    {writer, monitor} =
      spawn_monitor(fn ->
        receive do
          :write ->
            try do
              case Command.write(command, input) do
                :ok -> Command.close_stdin(command)
                {:error, _} -> :ok
              end
            catch
              :exit, _ -> :ok
            end
        end
      end)

    on_exit(fn -> if Process.alive?(writer), do: Process.exit(writer, :kill) end)
    assert :ok = Command.change_pipe_owner(command, :stdin, writer)
    send(writer, :write)
    deadline = System.monotonic_time(:millisecond) + @observation_timeout
    assert pending_write?(command.pid, writer, deadline), "stdin write did not become pending"
    {writer, monitor}
  end

  defp pending_write?(command, writer, deadline) do
    pending? =
      case :sys.get_state(command, @observation_timeout).operations.write_stdin do
        {:write_stdin, {^writer, _}, bytes} when is_binary(bytes) -> true
        _ -> false
      end

    cond do
      pending? ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          5 -> pending_write?(command, writer, deadline)
        end
    end
  end

  defp delivered_digest(command) do
    parent = self()

    {reader, monitor} =
      spawn_monitor(fn ->
        receive do
          :read ->
            send(parent, {:delivered_digest, self(), :crypto.hash(:sha256, drain(command, []))})
        end
      end)

    on_exit(fn -> if Process.alive?(reader), do: Process.exit(reader, :kill) end)
    assert :ok = Command.change_pipe_owner(command, :stdout, reader)
    send(reader, :read)
    assert_receive {:delivered_digest, ^reader, digest}, @observation_timeout
    assert_receive {:DOWN, ^monitor, :process, ^reader, :normal}, @observation_timeout
    digest
  end

  defp drain(command, chunks) do
    case Command.read(command) do
      {:ok, bytes} -> drain(command, [bytes | chunks])
      :eof -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp crash_call(command, message) do
    GenServer.call(command.pid, message, @observation_timeout)
  catch
    :exit, _ -> :ok
  end

  test "initialization failure redacts the invalid owner from logs and returned error" do
    log =
      capture_log(fn ->
        result =
          GenServer.start(Command, %{owner: @input_value, exit_ref: make_ref()},
            timeout: @observation_timeout
          )

        assert match?({:error, _}, result)
        diagnostic = inspect(result, limit: :infinity)
        assert diagnostic =~ "callback_failed"
        assert_private(diagnostic)
      end)

    assert_private(log)
  end

  test "continuation failure redacts arguments before any external process is opened" do
    log =
      capture_log(fn ->
        # These arguments pass init but omit exec's required cmd_with_args/env.
        # The failing map match precedes Proto.start and therefore Port.open.
        result =
          GenServer.start(
            Command,
            %{owner: self(), exit_ref: make_ref(), secret: @input_value},
            timeout: @observation_timeout
          )

        assert match?({:ok, _}, result)
        {:ok, command} = result
        monitor = Process.monitor(command)
        assert_receive {:DOWN, ^monitor, :process, ^command, reason}, @observation_timeout
        assert_private(inspect(reason, limit: :infinity))
        refute Process.alive?(command)
      end)

    assert log =~ "terminating"
    assert log =~ ":redacted"
    assert_private(log)
  end

  test "validation errors omit argument and option values" do
    assert {:error, message} =
             Exec.normalize_exec_args(["cat", @arg_value, nil], [])

    assert_private(message)

    assert {:error, message} =
             Exec.normalize_exec_args(["cat"], unexpected: @env_value)

    assert_private(message)
  end
end
