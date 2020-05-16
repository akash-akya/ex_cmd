defmodule ExCmd.ProcessTest do
  use ExUnit.Case, async: true
  alias ExCmd.Process

  test "read" do
    {:ok, s} = Process.start_link(~w(echo test))
    :ok = Process.run(s)
    :ok = Process.open_input(s)
    :ok = Process.open_output(s)
    assert {:ok, "test\n"} == Process.read(s)
    assert :eof == Process.read(s)
    assert :ok == Process.close_input(s)
    # exit status from terminated command is async
    :timer.sleep(100)
    assert {:done, 0} == Process.status(s)
  end

  test "write" do
    {:ok, s} = Process.start_link(~w(cat))
    :ok = Process.run(s)
    :ok = Process.open_input(s)
    :ok = Process.open_output(s)
    assert :ok == Process.write(s, "hello")
    assert {:ok, "hello"} == Process.read(s)
    assert :ok == Process.write(s, "world")
    assert {:ok, "world"} == Process.read(s)
    assert :ok == Process.close_input(s)
    assert :eof == Process.read(s)

    # exit status from terminated command is async
    :timer.sleep(50)
    assert {:done, 0} == Process.status(s)
  end

  test "stdin close" do
    logger = start_events_collector()

    # base64 produces output only after getting EOF from stdin.  we
    # collect events in order and assert that we can still read from
    # stdout even after closing stdin
    {:ok, s} = Process.start_link(~w(base64))
    :ok = Process.run(s)
    :ok = Process.open_input(s)
    :ok = Process.open_output(s)

    # parallel reader should be blocked till we close stdin
    start_parallel_reader(s, logger)
    :timer.sleep(50)

    assert :ok == Process.write(s, "hello")
    add_event(logger, {:write, "hello"})
    assert :ok == Process.write(s, "world")
    add_event(logger, {:write, "world"})
    :timer.sleep(50)

    assert :ok == Process.close_input(s)
    add_event(logger, :input_close)
    :timer.sleep(50)
    assert {:done, 0} == Process.status(s)

    assert [
             {:write, "hello"},
             {:write, "world"},
             :input_close,
             {:read, "aGVsbG93b3JsZA==\n"},
             :eof
           ] == get_events(logger)
  end

  test "external command kill" do
    {:ok, s} = Process.start_link(~w(cat))
    :ok = Process.run(s)
    :ok = Process.open_input(s)
    :ok = Process.open_output(s)
    os_pid = Process.port_info(s)[:os_pid]
    assert os_process_alive?(os_pid)

    Process.close_input(s)

    Process.stop(s)
    :timer.sleep(100)

    refute os_process_alive?(os_pid)
  end

  test "external command forceful kill" do
    # cat command hangs waiting for EOF
    {:ok, s} = Process.start_link(~w(cat))
    :ok = Process.run(s)
    :ok = Process.open_input(s)
    :ok = Process.open_output(s)

    os_pid = Process.port_info(s)[:os_pid]
    assert os_process_alive?(os_pid)

    Process.stop(s)

    # odu waits for 3s before killing the command
    # TODO: make this timeout configurable
    :timer.sleep(4000)

    refute os_process_alive?(os_pid)
  end

  test "exit status" do
    {:ok, s} = Process.start_link(~w(odu -invalid))
    :ok = Process.run(s)
    :ok = Process.open_input(s)
    :ok = Process.open_output(s)
    :timer.sleep(500)
    assert {:done, 2} == Process.status(s)
  end

  test "abnormal exit of fifo" do
    Elixir.Process.flag(:trap_exit, true)
    {:ok, s} = Process.start_link(~w(cat))
    :ok = Process.run(s)
    :ok = Process.open_input(s)
    :ok = Process.open_output(s)

    pid = spawn_link(fn -> Process.write(s, :invalid) end)
    assert_receive {:EXIT, ^pid, reason} when reason != :normal

    assert Elixir.Process.alive?(s) == false
  end

  test "explicite exit of fifo" do
    {:ok, s} = Process.start_link(~w(cat))
    :ok = Process.run(s)
    :ok = Process.open_input(s)
    :ok = Process.open_output(s)

    Process.close_input(s)
    :timer.sleep(100)
    assert Elixir.Process.alive?(s) == true
  end

  test "process kill with parallel blocking write" do
    {:ok, s} = Process.start_link(~w(cat))
    :ok = Process.run(s)
    :ok = Process.open_input(s)
    :ok = Process.open_output(s)

    large_data = Stream.cycle(["test"]) |> Stream.take(100_000) |> Enum.to_list()
    pid = Task.async(fn -> Process.write(s, large_data) end)

    :timer.sleep(200)
    Process.stop(s)
    :timer.sleep(100)

    assert Task.await(pid) == :closed
  end

  test "stderr" do
    {:ok, s} = Process.start_link(~w(odu -invalid), no_stderr: false)
    :ok = Process.run(s)
    :ok = Process.open_input(s)
    :ok = Process.open_output(s)
    :ok = Process.open_error(s)
    :timer.sleep(500)

    assert {:ok, "flag provided but not defined: -invalid\n" <> _} = Process.read_error(s)

    assert {:done, 2} == Process.status(s)
  end

  test "no_stdin option" do
    {:ok, s} = Process.start_link(~w(echo hello), no_stdin: true)
    :ok = Process.run(s)
    :ok = Process.open_output(s)
    assert {:ok, "hello\n"} == Process.read(s)
    assert :eof == Process.read(s)
    # exit status from terminated command is async
    :timer.sleep(100)
    assert {:done, 0} == Process.status(s)
  end

  test "open_input on no_stdin" do
    {:ok, s} = Process.start_link(~w(echo hello), no_stdin: true)
    assert {:error, :unused_stream} = Process.open_input(s)
  end

  def start_parallel_reader(proc_server, logger) do
    spawn_link(fn -> reader_loop(proc_server, logger) end)
  end

  def reader_loop(proc_server, logger) do
    case Process.read(proc_server) do
      {:ok, data} ->
        add_event(logger, {:read, data})
        reader_loop(proc_server, logger)

      :eof ->
        add_event(logger, :eof)
    end
  end

  def start_events_collector do
    {:ok, ordered_events} = Agent.start(fn -> [] end)
    ordered_events
  end

  def add_event(agent, event) do
    :ok = Agent.update(agent, fn events -> events ++ [event] end)
  end

  def get_events(agent) do
    Agent.get(agent, & &1)
  end

  defp os_process_alive?(pid) do
    match?({_, 0}, System.cmd("ps", ["-p", to_string(pid)]))
  end
end
