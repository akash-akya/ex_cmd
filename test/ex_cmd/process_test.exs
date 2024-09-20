defmodule ExCmd.ProcessTest do
  use ExUnit.Case, async: true

  alias ExCmd.Process
  alias ExCmd.Process.{Pipe, State}

  doctest ExCmd.Process

  describe "pipes" do
    test "reading from stdout" do
      {:ok, s} = Process.start_link(~w(echo test))
      :timer.sleep(100)

      assert {:ok, iodata} = Process.read(s, 100)
      assert :eof = Process.read(s, 100)
      assert IO.iodata_to_binary(iodata) == "test\n"

      assert :ok == Process.close_stdin(s)
      assert :ok == Process.close_stdout(s)

      assert {:ok, 0} == Process.await_exit(s, 500)

      refute Elixir.Process.alive?(s.pid)
    end

    test "write to stdin" do
      {:ok, s} = Process.start_link(~w(cat))

      assert :ok == Process.write(s, "hello")
      assert {:ok, iodata} = Process.read(s, 5)
      assert IO.iodata_to_binary(iodata) == "hello"

      assert :ok == Process.write(s, "world")
      assert {:ok, iodata} = Process.read(s, 5)
      assert IO.iodata_to_binary(iodata) == "world"

      assert :ok == Process.close_stdin(s)
      assert :eof == Process.read(s)

      assert {:ok, 0} == Process.await_exit(s, 100)

      :timer.sleep(100)
      refute Elixir.Process.alive?(s.pid)
    end

    test "when stdin is closed" do
      logger = start_events_collector()

      # base64 produces output only after getting EOF from stdin.  we
      # collect events in order and assert that we can still read from
      # stdout even after closing stdin
      {:ok, s} = Process.start_link(~w(base64))

      # parallel reader should be blocked till we close stdin
      start_parallel_reader(s, logger)
      :timer.sleep(100)

      assert :ok == Process.write(s, "hello")
      add_event(logger, {:write, "hello"})
      assert :ok == Process.write(s, "world")
      add_event(logger, {:write, "world"})
      :timer.sleep(100)

      assert :ok == Process.close_stdin(s)
      add_event(logger, :input_close)
      assert {:ok, 0} == Process.await_exit(s)
      # Process.stop(s)

      # wait for the reader to read
      Elixir.Process.sleep(500)

      assert [
               {:write, "hello"},
               {:write, "world"},
               :input_close,
               {:read, "aGVsbG93b3JsZA==\n"},
               :eof
             ] == get_events(logger)
    end

    test "stderr disabled" do
      script = """
      echo "==foo=="
      echo "==bar==" >&2
      """

      {:ok, s} = Process.start_link(["sh", "-c", script], stderr: :disable)

      assert {:ok, "==foo==\n"} = Process.read(s, 100)
      assert :eof = Process.read(s, 100)
      assert {:ok, 0} = Process.await_exit(s, 100)
    end

    test "stderr redirect_to_stdout" do
      script = """
      echo "==foo=="
      echo "==bar==" >&2
      """

      {:ok, s} = Process.start_link(["sh", "-c", script], stderr: :redirect_to_stdout)
      # wait for the the both output to merge
      :timer.sleep(500)

      assert {:ok, "==foo==\n==bar==\n"} = Process.read(s, 100)
      assert :eof = Process.read(s, 100)
      assert {:ok, 0} = Process.await_exit(s, 100)
    end

    test "if pipe gets closed on pipe owner exit normally" do
      {:ok, s} = Process.start_link(~w(sleep 10000))

      writer =
        Task.async(fn ->
          Process.change_pipe_owner(s, :stdin, self())
        end)

      # stdin must be closed on task completion
      :ok = Task.await(writer)

      assert %State{
               pipes: %{
                 stdin: %Pipe{
                   name: :stdin,
                   fd: _,
                   monitor_ref: nil,
                   owner: nil,
                   status: :closed
                 },
                 # ensure other pipes are unaffected
                 stdout: %Pipe{
                   name: :stdout,
                   status: :open
                 }
               }
             } = :sys.get_state(s.pid)
    end

    test "if pipe gets closed on pipe owner is killed" do
      {:ok, s} = Process.start_link(~w(sleep 10000))

      writer =
        spawn(fn ->
          Process.change_pipe_owner(s, :stdin, self())

          receive do
            :block -> :ok
          end
        end)

      # wait for pipe owner to change
      :timer.sleep(100)

      # stdin must be closed on process kill
      true = Elixir.Process.exit(writer, :kill)
      :timer.sleep(1000)

      assert %State{
               pipes: %{
                 stdin: %Pipe{
                   name: :stdin,
                   fd: _,
                   monitor_ref: nil,
                   owner: nil,
                   status: :closed
                 },
                 # ensure other pipes are unaffected
                 stdout: %Pipe{
                   name: :stdout,
                   status: :open
                 }
               }
             } = :sys.get_state(s.pid)
    end
  end

  describe "process termination" do
    test "if process is terminated automatically on owner exit" do
      pid = self()

      spawn_link(fn ->
        {:ok, s} = Process.start_link(~w(cat))
        {:ok, os_pid} = Process.os_pid(s)
        send(pid, os_pid)
      end)

      os_pid =
        receive do
          os_pid -> os_pid
        end

      :timer.sleep(500)

      refute os_process_alive?(os_pid)
    end

    test "if await_exit closes stdin implicitly" do
      {:ok, s} = Process.start_link(~w(cat))
      assert {:ok, 0} = Process.await_exit(s, 100)
    end

    test "if await_exit kills the program" do
      {:ok, s} = Process.start_link(~w(sleep 1000))
      assert {:error, :killed} = Process.await_exit(s, 100)
    end

    test "if external program terminates on process exit" do
      {:ok, s} = Process.start_link(~w(cat))
      {:ok, os_pid} = Process.os_pid(s)

      assert os_process_alive?(os_pid)

      :ok = Process.close_stdin(s)
      assert :eof = Process.read(s)
      :timer.sleep(1000)

      refute os_process_alive?(os_pid)
    end

    test "read after command finishes" do
      {:ok, s} = Process.start_link(~w(cat))
      {:ok, os_pid} = Process.os_pid(s)
      assert os_process_alive?(os_pid)

      assert :ok == Process.write(s, "hello")
      :ok = Process.close_stdin(s)
      :timer.sleep(1000)

      assert {:ok, "hello"} == Process.read(s)
    end

    test "watcher kills external command on process without exit_await" do
      {os_pid, s} =
        Task.async(fn ->
          {:ok, s} = Process.start_link([fixture("ignore_sigterm.sh")])
          {:ok, os_pid} = Process.os_pid(s)
          assert os_process_alive?(os_pid)

          # ensure the script set the correct signal handlers (handlers to ignore signal)
          assert {:ok, "ignored signals\n" <> _} = Process.read(s)

          # exit without waiting for the ex_cmd process
          {os_pid, s}
        end)
        |> Task.await()

      :timer.sleep(2000)

      # ExCmd Process should exit after Task process terminates
      refute Elixir.Process.alive?(s.pid)
      refute os_process_alive?(os_pid)
    end

    test "await_exit with timeout" do
      {:ok, s} = Process.start_link([fixture("ignore_sigterm.sh")])
      {:ok, os_pid} = Process.os_pid(s)
      assert os_process_alive?(os_pid)

      assert {:ok, "ignored signals\n" <> _} = Process.read(s)

      # attempt to kill the process after 100ms
      assert {:error, :killed} = Process.await_exit(s, 200)

      refute os_process_alive?(os_pid)
      refute Elixir.Process.alive?(s.pid)
    end

    test "exit status" do
      {:ok, s} = Process.start_link(["sh", "-c", "exit 10"])
      assert {:ok, 10} == Process.await_exit(s)
    end

    test "check command that does not take any input or produce output" do
      {:ok, s} = Process.start_link(["sh", "-c", "./forever.sh"])
      assert ret = Process.await_exit(s)
      # process might die with different reason due to race condition
      assert ret in [{:error, :killed}, {:ok, 127}]
    end

    test "writing binary larger than pipe buffer size" do
      large_bin = generate_binary(5 * 65_535)
      {:ok, s} = Process.start_link(~w(cat))

      writer =
        Task.async(fn ->
          Process.change_pipe_owner(s, :stdin, self())
          Process.write(s, large_bin)
        end)

      :timer.sleep(100)

      iodata =
        Stream.unfold(nil, fn _ ->
          case Process.read(s) do
            {:ok, data} -> {data, nil}
            :eof -> nil
          end
        end)
        |> Enum.to_list()

      Task.await(writer)

      assert IO.iodata_length(iodata) == 5 * 65_535
      assert {:ok, 0} == Process.await_exit(s, 500)
    end

    test "if ex_cmd process is terminated on owner exit even if pipe owner is alive" do
      parent = self()

      owner =
        spawn(fn ->
          # owner process terminated without await_exit
          {:ok, s} = Process.start_link(~w(cat))

          snd(parent, {:ok, s})
          :exit = recv(parent)
        end)

      {:ok, s} = recv(owner)

      spawn_link(fn ->
        Process.change_pipe_owner(s, :stdin, self())
        block()
      end)

      spawn_link(fn ->
        Process.change_pipe_owner(s, :stdout, self())
        block()
      end)

      # wait for pipe owner to change
      :timer.sleep(500)

      snd(owner, :exit)

      # wait for messages to propagate, if there are any
      :timer.sleep(500)

      refute Elixir.Process.alive?(owner)
      refute Elixir.Process.alive?(s.pid)
    end

    test "if ex_cmd process is *NOT* terminated on owner exit, if any pipe owner is alive" do
      parent = self()

      {:ok, s} = Process.start_link(~w(cat))

      io_proc =
        spawn_link(fn ->
          :ok = Process.change_pipe_owner(s, :stdin, self())
          :ok = Process.change_pipe_owner(s, :stdout, self())
          send(parent, :continue)
          recv(parent)
        end)

      # wait for pipe owner to change
      receive do
        :continue -> :ok
      end

      # external process will be killed with SIGTERM (143)
      assert {:error, :killed} = Process.await_exit(s, 100)

      # wait for messages to propagate, if there are any
      :timer.sleep(100)

      assert Elixir.Process.alive?(s.pid)

      assert %State{
               pipes: %{
                 stdin: %Pipe{status: :open},
                 stdout: %Pipe{status: :open}
               }
             } = :sys.get_state(s.pid)

      # when the io_proc exits, the pipes should be closed and process must terminate
      snd(io_proc, :exit)
      :timer.sleep(100)

      refute Elixir.Process.alive?(s.pid)
    end

    test "when process is killed with a pending concurrent write" do
      {:ok, s} = Process.start_link(~w(cat))
      {:ok, os_pid} = Process.os_pid(s)

      large_data =
        Stream.cycle(["test"])
        |> Stream.take(500_000)
        |> Enum.to_list()
        |> IO.iodata_to_binary()

      task =
        Task.async(fn ->
          Process.change_pipe_owner(s, :stdin, self())
          Process.write(s, large_data)
        end)

      # to avoid race conditions, like if process is killed before owner
      # is changed
      :timer.sleep(200)

      assert {:error, :killed} = Process.await_exit(s)

      refute os_process_alive?(os_pid)
      assert {:error, :epipe} == Task.await(task)
    end

    test "if owner is killed when the ex_cmd process is killed" do
      parent = self()

      # create an ex_cmd process without linking to caller
      owner =
        spawn(fn ->
          assert {:ok, s} = Process.start_link(~w(cat))
          snd(parent, s.pid)
          block()
        end)

      owner_ref = Elixir.Process.monitor(owner)

      ex_cmd_pid = recv(owner)

      ex_cmd_ref = Elixir.Process.monitor(ex_cmd_pid)

      assert Elixir.Process.alive?(owner)
      assert Elixir.Process.alive?(ex_cmd_pid)

      true = Elixir.Process.exit(ex_cmd_pid, :kill)

      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
      assert_receive {:DOWN, ^ex_cmd_ref, :process, ^ex_cmd_pid, :killed}
    end

    test "if ex_cmd process is killed when the owner is killed" do
      parent = self()

      # create an ex_cmd process without linking to caller
      owner =
        spawn(fn ->
          assert {:ok, s} = Process.start_link(~w(cat))
          snd(parent, s.pid)
          block()
        end)

      owner_ref = Elixir.Process.monitor(owner)

      ex_cmd_pid = recv(owner)

      ex_cmd_ref = Elixir.Process.monitor(ex_cmd_pid)

      assert Elixir.Process.alive?(owner)
      assert Elixir.Process.alive?(ex_cmd_pid)

      true = Elixir.Process.exit(owner, :kill)

      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
      assert_receive {:DOWN, ^ex_cmd_ref, :process, ^ex_cmd_pid, :killed}
    end
  end

  test "back-pressure" do
    logger = start_events_collector()

    # we test backpressure by testing if `write` is delayed when we delay read
    {:ok, s} = Process.start_link(~w(cat))

    large_bin = generate_binary(65_535 * 5)

    writer =
      Task.async(fn ->
        Process.change_pipe_owner(s, :stdin, self())
        :ok = Process.write(s, large_bin)
        add_event(logger, {:write, IO.iodata_length(large_bin)})
      end)

    :timer.sleep(50)

    reader =
      Task.async(fn ->
        Process.change_pipe_owner(s, :stdout, self())

        Stream.unfold(nil, fn _ ->
          case Process.read(s) do
            {:ok, data} ->
              add_event(logger, {:read, IO.iodata_length(data)})
              # delay in reading should delay writes
              :timer.sleep(10)
              {nil, nil}

            :eof ->
              nil
          end
        end)
        |> Stream.run()
      end)

    Task.await(writer)
    Task.await(reader)

    assert {:ok, 0} == Process.await_exit(s)

    events = get_events(logger)

    {write_events, read_evants} = Enum.split_with(events, &match?({:write, _}, &1))

    assert Enum.sum(Enum.map(read_evants, fn {:read, size} -> size end)) ==
             Enum.sum(Enum.map(write_events, fn {:write, size} -> size end))

    # There must be a read before write completes
    assert {:read, _} = hd(events)
  end

  test "os pid" do
    if windows?() do
      {:ok, s} = Process.start_link(~w(cat))
      {:ok, os_pid} = Process.os_pid(s)

      {output, 0} = System.cmd("tasklist", ["/fi", "pid eq #{os_pid}"])
      assert String.contains?(output, "cat.exe")
      assert {:ok, 0} = Process.await_exit(s)
    else
      {:ok, s} = Process.start_link(~w(cat))
      {:ok, os_pid} = Process.os_pid(s)

      {outout, 0} = System.cmd("sh", ["-c", "ps -o args -p #{os_pid} | tail -1"])
      assert System.find_executable("cat") == String.trim(outout)
      assert {:ok, 0} = Process.await_exit(s)
    end
  end

  # this test does not work properly in linux
  @tag :skip
  test "if we are leaking file descriptor" do
    {:ok, s} = Process.start_link(~w(sleep 60))
    {:ok, os_pid} = Process.os_pid(s)

    # we are only printing FD, TYPE, NAME with respective prefix
    {bin, 0} = System.cmd("lsof", ["-F", "ftn", "-p", to_string(os_pid)])

    open_files = parse_lsof(bin)

    assert [
             %{type: "PIPE", fd: "0", name: _},
             %{type: "PIPE", fd: "1", name: _},
             %{type: "CHR", fd: "2", name: "/dev/ttys007"}
           ] = open_files
  end

  describe "options and validation" do
    test "cd option" do
      parent = Path.expand("..", File.cwd!())
      {:ok, s} = Process.start_link(~w(sh -c pwd), cd: parent)
      {:ok, dir} = Process.read(s)

      assert String.trim(dir) == parent
      assert {:ok, 0} = Process.await_exit(s)
    end

    test "when cd is invalid" do
      assert {:error, _} = Process.start_link(~w(sh -c pwd), cd: "invalid")
    end

    test "when user pass invalid option" do
      assert {:error, "invalid opts: [invalid: :test]"} =
               Process.start_link(~w(cat), invalid: :test)
    end

    test "env option" do
      assert {:ok, s} = Process.start_link(~w(printenv TEST_ENV), env: %{"TEST_ENV" => "test"})

      assert {:ok, "test\n"} = Process.read(s)
      assert {:ok, 0} = Process.await_exit(s)
    end

    test "if external process inherits beam env" do
      :ok = System.put_env([{"BEAM_ENV_A", "10"}])
      assert {:ok, s} = Process.start_link(~w(printenv BEAM_ENV_A))

      assert {:ok, "10\n"} = Process.read(s)
      assert {:ok, 0} = Process.await_exit(s)
    end

    test "if user env overrides beam env" do
      :ok = System.put_env([{"BEAM_ENV", "base"}])

      assert {:ok, s} =
               Process.start_link(~w(printenv BEAM_ENV), env: %{"BEAM_ENV" => "overridden"})

      assert {:ok, "overridden\n"} = Process.read(s)
      assert {:ok, 0} = Process.await_exit(s)
    end
  end

  def start_parallel_reader(process, logger) do
    spawn_link(fn ->
      :ok = Process.change_pipe_owner(process, :stdout, self())
      reader_loop(process, logger)
    end)
  end

  def reader_loop(process, logger) do
    case Process.read(process) do
      {:ok, data} ->
        add_event(logger, {:read, data})
        reader_loop(process, logger)

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

  defp fixture(script) do
    Path.join([__DIR__, "../scripts", script])
  end

  defp parse_lsof(iodata) do
    String.split(IO.iodata_to_binary(iodata), "\n", trim: true)
    |> Enum.reduce([], fn
      "f" <> fd, acc -> [%{fd: fd} | acc]
      "t" <> type, [h | acc] -> [Map.put(h, :type, type) | acc]
      "n" <> name, [h | acc] -> [Map.put(h, :name, name) | acc]
      _, acc -> acc
    end)
    |> Enum.reverse()
    |> Enum.reject(fn
      %{fd: fd} when fd in ["255", "cwd", "txt"] ->
        true

      %{fd: "rtd", name: "/", type: "DIR"} ->
        true

      # filter libc and friends
      %{fd: "mem", type: "REG", name: "/lib/x86_64-linux-gnu/" <> _} ->
        true

      %{fd: "mem", type: "REG", name: "/usr/lib/locale/C.UTF-8/" <> _} ->
        true

      %{fd: "mem", type: "REG", name: "/usr/lib/locale/locale-archive" <> _} ->
        true

      %{fd: "mem", type: "REG", name: "/usr/lib/x86_64-linux-gnu/gconv" <> _} ->
        true

      _ ->
        false
    end)
  end

  defp generate_binary(size) do
    Stream.repeatedly(fn -> "A" end)
    |> Enum.take(size)
    |> IO.iodata_to_binary()
  end

  defp block do
    rand = :rand.uniform()

    receive do
      ^rand -> :ok
    end
  end

  defp snd(pid, term) do
    send(pid, {self(), term})
  end

  defp recv(sender) do
    receive do
      {^sender, term} -> term
    after
      1000 ->
        raise "recv timeout"
    end
  end
end
