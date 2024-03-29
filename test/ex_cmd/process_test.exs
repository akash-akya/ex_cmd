defmodule ExCmd.ProcessTest do
  use ExUnit.Case, async: true

  alias ExCmd.Process
  alias Mix.Tasks.Compile.Odu

  @large_bin Stream.cycle(["a"])
             |> Stream.take(1_000_000)
             |> Enum.to_list()
             |> IO.iodata_to_binary()

  test "read" do
    {:ok, s} = Process.start_link(~w(echo test))
    assert {:ok, output} = Process.read(s)
    assert String.trim(output) == "test"
    assert :eof == Process.read(s)
    assert :ok == Process.close_stdin(s)
    # exit status from terminated command is async
    :timer.sleep(100)
    assert {:done, 0} == Process.status(s)
  end

  test "write" do
    {:ok, s} = Process.start_link(~w(cat))
    assert :ok == Process.write(s, "hello")
    assert {:ok, "hello"} == Process.read(s)
    assert :ok == Process.write(s, "world")
    assert {:ok, "world"} == Process.read(s)
    assert :ok == Process.close_stdin(s)
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

    # parallel reader should be blocked till we close stdin
    start_parallel_reader(s, logger)
    :timer.sleep(50)

    assert :ok == Process.write(s, "hello")
    add_event(logger, {:write, "hello"})
    assert :ok == Process.write(s, "world")
    add_event(logger, {:write, "world"})
    :timer.sleep(50)

    assert :ok == Process.close_stdin(s)
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

  test "os pid" do
    if windows?() do
      {:ok, s} = Process.start_link(~w(cat))
      os_pid = Process.os_pid(s)

      {output, 0} = System.cmd("tasklist", ["/fi", "pid eq #{os_pid}"])
      assert String.contains?(output, "cat.exe")
      Process.stop(s)
    else
      {:ok, s} = Process.start_link(~w(cat))
      os_pid = Process.os_pid(s)

      {outout, 0} = System.cmd("sh", ["-c", "ps -o args -p #{os_pid} | tail -1"])
      assert System.find_executable("cat") == String.trim(outout)
      Process.stop(s)
    end
  end

  test "external command kill" do
    {:ok, s} = Process.start_link(~w(cat))
    os_pid = Process.os_pid(s)
    assert os_process_alive?(os_pid)

    Process.close_stdin(s)

    Process.stop(s)
    :timer.sleep(100)

    refute os_process_alive?(os_pid)
  end

  test "external command forceful kill" do
    # cat command hangs waiting for EOF
    {:ok, s} = Process.start_link(~w(cat))

    os_pid = Process.os_pid(s)
    assert os_process_alive?(os_pid)

    Process.stop(s)

    :timer.sleep(4000)

    refute os_process_alive?(os_pid)
  end

  test "exit status" do
    odu_path =
      Application.app_dir(:ex_cmd, "priv")
      |> Path.join(Odu.executable_name())

    {:ok, s} = Process.start_link(~w(#{odu_path} -invalid))
    :eof = Process.read(s)
    :timer.sleep(500)
    assert {:done, 2} == Process.status(s)
  end

  test "if large write blocks other commands" do
    {:ok, s} = Process.start_link(~w(cat))

    spawn_link(fn -> Process.write(s, @large_bin) end)

    :timer.sleep(20)
    :ok = Process.close_stdin(s)

    size =
      Stream.unfold(nil, fn _ ->
        case Process.read(s) do
          {:ok, data} ->
            :timer.sleep(10)
            {byte_size(data), nil}

          :eof ->
            nil
        end
      end)
      |> Enum.sum()

    Process.stop(s)

    assert size < byte_size(@large_bin)

    :timer.sleep(100)
    assert Elixir.Process.alive?(s) == false
  end

  test "pending writes on stdin close" do
    {:ok, s} = Process.start_link(~w(cat))
    task1 = Task.async(fn -> Process.write(s, @large_bin) end)
    task2 = Task.async(fn -> Process.write(s, "test") end)
    Process.close_stdin(s)

    assert Task.await(task1) == {:error, :epipe}
    assert Task.await(task2) == {:error, :epipe}
    Process.stop(s)
  end

  test "pending reads when program exits" do
    {:ok, s} = Process.start_link(~w(cat))
    task1 = Task.async(fn -> Process.read(s) end)
    task2 = Task.async(fn -> Process.read(s) end)
    :timer.sleep(200)
    Process.close_stdin(s)

    assert Process.read(s) == :eof
    assert Task.await(task1) == :eof
    assert Task.await(task2) == :eof
    Process.stop(s)
  end

  test "pending write on port close" do
    {:ok, s} = Process.start_link(~w(cat))
    task = Task.async(fn -> Process.write(s, @large_bin) end)

    :timer.sleep(200)
    {:started, %{port: port}} = :sys.get_state(s)
    Port.close(port)

    assert Task.await(task) == {:error, :epipe}
    Process.stop(s)
  end

  test "pending read on port close" do
    {:ok, s} = Process.start_link(~w(cat))
    task = Task.async(fn -> Process.read(s) end)

    :timer.sleep(200)
    {:started, %{port: port}} = :sys.get_state(s)
    Port.close(port)

    assert Task.await(task) == :eof
    Process.stop(s)
  end

  test "invalid write" do
    Elixir.Process.flag(:trap_exit, true)
    {:ok, s} = Process.start_link(~w(cat))

    pid = spawn_link(fn -> Process.write(s, :invalid) end)
    assert_receive {:EXIT, ^pid, reason} when reason != :normal

    assert Elixir.Process.alive?(s) == false
  end

  test "if closing stdin exits the server" do
    {:ok, s} = Process.start_link(~w(cat))

    Process.close_stdin(s)
    :timer.sleep(100)
    assert Elixir.Process.alive?(s) == true
  end

  # test "process kill with parallel blocking write" do
  #   {:ok, s} = Process.start_link(~w(cat))

  #   pid = Task.async(fn -> Process.write(s, @large_bin) end)

  #   :timer.sleep(200)
  #   os_pid = Process.os_pid(s)
  #   {"", 0} = System.cmd("kill", ["-SIGKILL", to_string(os_pid)])
  #   :timer.sleep(1000)
  #   assert Task.await(pid) == :closed
  # end

  test "cd" do
    parent = Path.expand("..", File.cwd!())
    {:ok, s} = Process.start_link(~w(sh -c pwd), cd: parent)
    {:ok, dir} = Process.read(s)
    :eof = Process.read(s)
    assert String.trim(dir) |> Path.basename() == Path.basename(parent)
    assert {:ok, 0} = Process.await_exit(s)
    Process.stop(s)
  end

  test "env" do
    assert {:ok, s} = Process.start_link(~w(printenv TEST_ENV), env: %{"TEST_ENV" => "test"})

    assert {:ok, "test\n"} = Process.read(s)
    assert :eof = Process.read(s)
    assert {:ok, 0} = Process.await_exit(s)
    Process.stop(s)
  end

  test "if external process inherits beam env" do
    :ok = System.put_env([{"BEAM_ENV_A", "10"}])
    assert {:ok, s} = Process.start_link(~w(printenv BEAM_ENV_A))

    assert {:ok, "10\n"} = Process.read(s)
    assert :eof == Process.read(s)
    assert :ok == Process.close_stdin(s)

    :timer.sleep(100)
    assert {:done, 0} == Process.status(s)

    assert {:ok, 0} = Process.await_exit(s)
    Process.stop(s)
  end

  test "if user env overrides beam env" do
    :ok = System.put_env([{"BEAM_ENV", "base"}])

    assert {:ok, s} =
             Process.start_link(~w(printenv BEAM_ENV), env: %{"BEAM_ENV" => "overridden"})

    assert {:ok, "overridden\n"} = Process.read(s)
    assert :eof = Process.read(s)
    assert {:ok, 0} = Process.await_exit(s)
    Process.stop(s)
  end

  test "multiple await_exit" do
    {:ok, s} = Process.start_link(~w(cat))

    tasks =
      for _ <- 1..5 do
        Task.async(fn ->
          Process.await_exit(s, :infinity)
        end)
      end

    Process.close_stdin(s)
    :eof = Process.read(s)

    for task <- tasks do
      assert {:ok, 0} == Task.await(task)
    end
  end

  test "await_exit timeout" do
    {:ok, s} = Process.start_link(~w(cat))
    assert :timeout = Process.await_exit(s, 100)
    assert {:started, %{waiting_processes: waiting_processes}} = :sys.get_state(s)
    assert MapSet.size(waiting_processes) == 0
    assert :ok = Process.stop(s)
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
    if windows?() do
      case System.cmd("tasklist", ["/fi", "pid eq #{pid}"]) do
        {"INFO: No tasks are running which match the specified criteria.\r\n", 0} -> false
        {_, 0} -> true
      end
    else
      match?({_, 0}, System.cmd("ps", ["-p", to_string(pid)]))
    end
  end

  defp windows?, do: :os.type() == {:win32, :nt}
end
