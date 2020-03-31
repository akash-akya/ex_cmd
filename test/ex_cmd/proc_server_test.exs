defmodule ExCmd.ProcServerTest do
  use ExUnit.Case, async: false
  alias ExCmd.ProcServer

  test "read" do
    {:ok, s} = ProcServer.start_link("echo", ["test"])
    :ok = ProcServer.run(s)
    :ok = ProcServer.open_input(s)
    :ok = ProcServer.open_output(s)
    assert {:ok, "test\n"} == ProcServer.read(s)
    assert :eof == ProcServer.read(s)
    assert :ok == ProcServer.close_input(s)
    # exit status from terminated command is async
    :timer.sleep(100)
    assert {:done, 0} == ProcServer.status(s)
  end

  test "write" do
    {:ok, s} = ProcServer.start_link("cat", [])
    :ok = ProcServer.run(s)
    :ok = ProcServer.open_input(s)
    :ok = ProcServer.open_output(s)
    assert :ok == ProcServer.write(s, "hello")
    assert {:ok, "hello"} == ProcServer.read(s)
    assert :ok == ProcServer.write(s, "world")
    assert {:ok, "world"} == ProcServer.read(s)
    assert :ok == ProcServer.close_input(s)
    assert :eof == ProcServer.read(s)

    # exit status from terminated command is async
    :timer.sleep(50)
    assert {:done, 0} == ProcServer.status(s)
  end

  test "stdin close" do
    logger = start_events_collector()

    # base64 produces output only after getting EOF from stdin.  we
    # collect events in order and assert that we can still read from
    # stdout even after closing stdin
    {:ok, s} = ProcServer.start_link("base64", [])
    :ok = ProcServer.run(s)
    :ok = ProcServer.open_input(s)
    :ok = ProcServer.open_output(s)

    # parallel reader should be blocked till we close stdin
    start_parallel_reader(s, logger)
    :timer.sleep(50)

    assert :ok == ProcServer.write(s, "hello")
    add_event(logger, {:write, "hello"})
    assert :ok == ProcServer.write(s, "world")
    add_event(logger, {:write, "world"})
    :timer.sleep(50)

    assert :ok == ProcServer.close_input(s)
    add_event(logger, :input_close)
    :timer.sleep(50)
    assert {:done, 0} == ProcServer.status(s)

    assert [
             {:write, "hello"},
             {:write, "world"},
             :input_close,
             {:read, "aGVsbG93b3JsZA==\n"},
             :eof
           ] == get_events(logger)
  end

  test "external command kill" do
    {:ok, s} = ProcServer.start_link("cat", [])
    :ok = ProcServer.run(s)
    :ok = ProcServer.open_input(s)
    :ok = ProcServer.open_output(s)
    os_pid = ProcServer.port_info(s)[:os_pid]
    assert os_process_alive?(os_pid)

    ProcServer.close_input(s)

    ProcServer.stop(s)
    :timer.sleep(100)

    refute os_process_alive?(os_pid)
  end

  test "external command forceful kill" do
    # cat command hangs waiting for EOF
    {:ok, s} = ProcServer.start_link("cat", [])
    :ok = ProcServer.run(s)
    :ok = ProcServer.open_input(s)
    :ok = ProcServer.open_output(s)

    os_pid = ProcServer.port_info(s)[:os_pid]
    assert os_process_alive?(os_pid)

    ProcServer.stop(s)

    # odu waits for 3s before killing the command
    # TODO: make this timeout configurable
    :timer.sleep(4000)

    refute os_process_alive?(os_pid)
  end

  test "exit status" do
    {:ok, s} = ProcServer.start_link("cat", ["some_invalid_file_name"])
    :ok = ProcServer.run(s)
    :ok = ProcServer.open_input(s)
    :ok = ProcServer.open_output(s)
    :timer.sleep(500)
    assert {:done, 1} == ProcServer.status(s)
  end

  def start_parallel_reader(proc_server, logger) do
    spawn_link(fn -> reader_loop(proc_server, logger) end)
  end

  def reader_loop(proc_server, logger) do
    case ProcServer.read(proc_server) do
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
