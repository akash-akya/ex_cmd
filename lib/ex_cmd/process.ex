defmodule ExCmd.Process do
  @moduledoc ~S"""
  GenServer which wraps spawned external command.

  Use `ExCmd.stream!/1` over using this. Use this only if you are
  familiar with life-cycle and need more control of the IO streams
  and OS process.

  ## Comparison with Port

    * it is demand driven. User explicitly has to `read` the command
  output, and the progress of the external command is controlled
  using OS pipes. ExCmd never load more output than we can consume,
  so we should never experience memory issues

    * it can close stdin while consuming output

    * tries to handle zombie process by attempting to cleanup
  external process. Note that there is no middleware involved
  with ex_cmd so it is still possible to endup with zombie process.

    * selectively consume stdout and stderr

  Internally ExCmd uses non-blocking asynchronous system calls
  to interact with the external process. It does not use port's
  message based communication, instead uses raw stdio and NIF.
  Uses asynchronous system calls for IO. Most of the system
  calls are non-blocking, so it should not block the beam
  schedulers. Make use of dirty-schedulers for IO

  ## Introduction

  `ExCmd.Process` is a process based wrapper around the external
  process. It is similar to `port` as an entity but the interface is
  different. All communication with the external process must happen
  via `ExCmd.Process` interface.

  ExCmd process life-cycle tied to external process and owners. All
  system resources such are open file-descriptors, external process
  are cleaned up when the `ExCmd.Process` dies.

  ### Owner

  Each `ExCmd.Process` has an owner. And it will be the process which
  created it (via `ExCmd.Process.start_link/2`). Process owner can not
  be changed.

  Owner process will be linked to the `ExCmd.Process`. So when the
  ex_cmd process is dies abnormally the owner will be killed too or
  visa-versa. Owner process should avoid trapping the exit signal, if
  you want avoid the caller getting killed, create a separate process
  as owner to run the command and monitor that process.

  Only owner can get the exit status of the command, using
  `ExCmd.Process.await_exit/2`. All ex_cmd processes **MUST** be
  awaited.  Exit status or reason is **ALWAYS** sent to the owner. It
  is similar to [`Task`](https://hexdocs.pm/elixir/Task.html). If the
  owner exit without `await_exit`, the ex_cmd process will be killed,
  but if the owner continue without `await_exit` then the ex_cmd
  process will linger around till the process exit.

  ```
  iex> alias ExCmd.Process
  iex> {:ok, p} = Process.start_link(~w(echo hello))
  iex> Process.read(p, 100)
  {:ok, "hello\n"}
  iex> Process.read(p, 100) # read till we get :eof
  :eof
  iex> Process.await_exit(p)
  {:ok, 0}
  ```

  ### Pipe & Pipe Owner

  Standard IO pipes/channels/streams of the external process such as
  STDIN, STDOUT, STDERR are called as Pipes. User can either write or
  read data from pipes.

  Each pipe has an owner process and only that process can write or
  read from the ex_cmd process. By default the process who created the
  ex_cmd process is the owner of all the pipes. Pipe owner can be
  changed using `ExCmd.Process.change_pipe_owner/3`.

  Pipe owner is monitored and the pipes are closed automatically when
  the pipe owner exit. Pipe Owner can close the pipe early using
  `ExCmd.Process.close_stdin/1` etc.

  `ExCmd.Process.await_exit/2` closes all of the caller owned pipes by
  default.

  ```
  iex> {:ok, p} = Process.start_link(~w(cat))
  iex> writer = Task.async(fn ->
  ...>   :ok = Process.change_pipe_owner(p, :stdin, self())
  ...>   Process.write(p, "Hello World")
  ...> end)
  iex> Task.await(writer)
  :ok
  iex> Process.read(p, 100)
  {:ok, "Hello World"}
  iex> Process.await_exit(p)
  {:ok, 0}
  ```

  ### Pipe Operations

  Only Pipe owner can read or write date to the owned pipe.
  All Pipe operations (read/write) blocks the caller as a mechanism
  to put back-pressure, and this also makes the API simpler.
  This is same as how command-line programs works on the shell,
  along with pipes in-between, Example: `cat larg-file | grep "foo"`.
  Internally ExCmd uses asynchronous IO APIs to avoid blocking VM
  (by default NIF calls blocks the VM scheduler),
  so you can open several pipes and do concurrent IO operations without
  blocking VM.


  ### `stderr`

  by default is `:stderr` is connected to console, data written to
  stderr will appear on the console.

  You can change the behavior by setting `:stderr`:

    1. `:console`  -  stderr output is redirected to console (Default)
    2. `:redirect_to_stdout`  -  stderr output is redirected to stdout
    2. `:consume`  -  stderr output read separately, allowing you to consume it separately from stdout. See below for more details
    4. `:disable`  -  stderr output is redirected `/dev/null` suppressing all output. See below for more details.


  ### Using `redirect_to_stdout`

  stderr data will be redirected to stdout. When you read stdout
  you will see both stdout & stderr combined and you won't be
  able differentiate stdout and stderr separately.
  This is similar to `:stderr_to_stdout` option present in
  [Ports](https://www.erlang.org/doc/apps/erts/erlang.html#open_port/2).

  > #### Unexpected Behaviors {: .warning}
  >
  > On many systems, `stdout` and `stderr` are separated. And between
  > the source program to ExCmd, via the kernel, there are several places
  > that may buffer data, even temporarily, before ExCmd is ready
  > to read them. There is no enforced ordering of the readiness of
  > these independent buffers for ExCmd to make use of.
  >
  > This can result in unexpected behavior, including:
  >
  >  * mangled data, for example, UTF-8 characters may be incomplete
  > until an additional buffered segment is released on the same
  > source
  >  * raw data, where binary data sent on one source, is incompatible
  > with data sent on the other source.
  >  * interleaved data, where what appears to be synchronous, is not
  >
  > In short, the two streams might be combined at arbitrary byte position
  > leading to above mentioned issue.
  >
  > Most well-behaved command-line programs are unlikely to exhibit
  > this, but you need to be aware of the risk.
  >
  > A good example of this unexpected behavior is streaming JSON from
  > an external tool to ExCmd, where normal JSON output is expected on
  > stdout, and errors or warnings via stderr. In the case of an
  > unexpected error, the stdout stream could be incomplete, or the
  > stderr message might arrive before the closing data on the stdout
  > stream.


  ### Process Termination

  When owner does (normally or abnormally) the ExCmd process always
  terminated irrespective of pipe status or process status. External
  process get a chance to terminate gracefully, if that fail it will
  be killed.

  If owner calls `await_exit` then the owner owned pipes are closed
  and we wait for external process to terminate, if the process
  already terminated then call returns immediately with exit
  status. Else command will be attempted to stop gracefully following
  the exit sequence based on the timeout value (5s by default).

  If owner calls `await_exit` with `timeout` as `:infinity` then
  ExCmd does not attempt to forcefully stop the external command and
  wait for command to exit on itself. The `await_exit` call can be blocked
  indefinitely waiting for external process to terminate.

  If external process exit on its own, exit status is collected and
  ExCmd process will wait for owner to close pipes. Most commands exit
  with pipes are closed, so just ensuring to close pipes when works is
  done should be enough.

  Example of process getting terminated by `SIGTERM` signal

  ```
  # sleep command does not watch for stdin or stdout, so closing the
  # pipe does not terminate the sleep command.
  iex> {:ok, p} = Process.start_link(~w(sleep 100000000)) # sleep indefinitely
  iex> Process.await_exit(p, 100) # ensure `await_exit` finish within `100ms`. By default it waits for 5s
  {:error, :killed} # command exit due to SIGTERM
  ```

  ## Examples

  Run a command without any input or output

  ```
  iex> {:ok, p} = Process.start_link(["sh", "-c", "exit 1"])
  iex> Process.await_exit(p)
  {:ok, 1}
  ```

  Single process reading and writing to the command

  ```
  # bc is a calculator, which reads from stdin and writes output to stdout
  iex> {:ok, p} = Process.start_link(~w(bc))
  iex> Process.write(p, "1 + 1\n") # there must be new-line to indicate the end of the input line
  :ok
  iex> Process.read(p)
  {:ok, "2\n"}
  iex> Process.write(p, "2 * 10 + 1\n")
  :ok
  iex> Process.read(p)
  {:ok, "21\n"}
  # We must close stdin to signal the `bc` command that we are done.
  # since `await_exit` implicitly closes the pipes, in this case we don't have to
  iex> Process.await_exit(p)
  {:ok, 0}
  ```

  Running a command which flush the output on stdin close. This is not
  supported by Erlang/Elixir ports.

  ```
  # `base64` command reads all input and writes encoded output when stdin is closed.
  iex> {:ok, p} = Process.start_link(~w(base64))
  iex> Process.write(p, "abcdef")
  :ok
  iex> Process.close_stdin(p) # we can selectively close stdin and read all output
  :ok
  iex> Process.read(p)
  {:ok, "YWJjZGVm\n"}
  iex> Process.read(p) # typically it is better to read till we receive :eof when we are not sure how big the output data size is
  :eof
  iex> Process.await_exit(p)
  {:ok, 0}
  ```

  Read and write to pipes in separate processes

  ```
  iex> {:ok, p} = Process.start_link(~w(cat))
  iex> writer = Task.async(fn ->
  ...>   :ok = Process.change_pipe_owner(p, :stdin, self())
  ...>   Process.write(p, "Hello World")
  ...>   # no need to close the pipe explicitly here. Pipe will be closed automatically when process exit
  ...> end)
  iex> reader = Task.async(fn ->
  ...>   :ok = Process.change_pipe_owner(p, :stdout, self())
  ...>   Process.read(p)
  ...> end)
  iex> :timer.sleep(500) # wait for the reader and writer to change pipe owner, otherwise `await_exit` will close the pipes before we change pipe owner
  iex> Process.await_exit(p, :infinity) # let the reader and writer take indefinite time to finish
  {:ok, 0}
  iex> Task.await(writer)
  :ok
  iex> Task.await(reader)
  {:ok, "Hello World"}
  ```

  """

  use GenServer

  alias ExCmd.Process.Exec
  alias ExCmd.Process.Proto
  alias ExCmd.Process.Operations
  alias ExCmd.Process.Pipe
  alias ExCmd.Process.State

  require Logger

  defmodule Error do
    defexception [:message]
  end

  @type pipe_name :: :stdin | :stdout | :stderr

  @type t :: %__MODULE__{
          monitor_ref: reference(),
          exit_ref: reference(),
          pid: pid | nil,
          owner: pid
        }

  defstruct [:monitor_ref, :exit_ref, :pid, :owner]

  @type exit_status :: non_neg_integer

  @type caller :: GenServer.from()

  @default_opts [env: [], stderr: :console, log: nil]
  @default_buffer_size 65_531

  @doc false
  defmacro send_input, do: 1

  @doc false
  defmacro send_output, do: 2

  @doc false
  defmacro output, do: 3

  @doc false
  defmacro input, do: 4

  @doc false
  defmacro close_input, do: 5

  @doc false
  defmacro output_eof, do: 6

  @doc false
  defmacro command_env, do: 7

  @doc false
  defmacro os_pid, do: 8

  @doc false
  defmacro start_error, do: 9

  @doc """
  Starts `ExCmd.Process` server.

  Starts external program using `cmd_with_args` with options `opts`

  `cmd_with_args` must be a list containing command with arguments.
  example: `["cat", "file.txt"]`.

  ### Options

    * `cd`   -  the directory to run the command in

    * `env`  -  a list of tuples containing environment key-value.
  These can be accessed in the external program

    * `stderr`  -  different ways to handle stderr stream.
        1. `:console`  -  stderr output is redirected to console (Default)
        2. `:redirect_to_stdout`  -  stderr output is redirected to stdout
        3. `:disable`  -  stderr output is redirected `/dev/null` suppressing all output
        4. `:consume`  -  connects stderr for the consumption. When set, the stderr output must be consumed to
  avoid external program from blocking.

      See [`:stderr`](#module-stderr) for more details and issues associated with them

  Caller of the process will be the owner owner of the ExCmd Process.
  And default owner of all opened pipes.

  Please check module documentation for more details
  """
  @spec start_link(nonempty_list(String.t()),
          cd: String.t(),
          env: [{String.t(), String.t()}],
          stderr: :console | :disable | :stream
        ) :: {:ok, t} | {:error, any()}
  def start_link([cmd | args], opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    cmd_path = :os.find_executable(to_charlist(cmd))
    cmd_with_args = [to_string(cmd_path) | args]

    case Exec.normalize_exec_args(cmd_with_args, opts) do
      {:ok, args} ->
        owner = self()
        exit_ref = make_ref()
        args = Map.merge(args, %{owner: owner, exit_ref: exit_ref})
        {:ok, pid} = GenServer.start_link(__MODULE__, args)
        ref = Process.monitor(pid)

        process = %__MODULE__{
          pid: pid,
          monitor_ref: ref,
          exit_ref: exit_ref,
          owner: owner
        }

        {:ok, process}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Closes external program's standard input pipe (stdin).

  Only owner of the pipe can close the pipe. This call will return
  immediately.
  """
  @spec close_stdin(t) :: :ok | {:error, :pipe_closed_or_invalid_caller} | {:error, any()}
  def close_stdin(process) do
    GenServer.call(process.pid, {:close_pipe, :stdin}, :infinity)
  end

  @doc """
  Closes external program's standard output pipe (stdout)

  Only owner of the pipe can close the pipe. This call will return
  immediately.
  """
  @spec close_stdout(t) :: :ok | {:error, any()}
  def close_stdout(process) do
    GenServer.call(process.pid, {:close_pipe, :stdout}, :infinity)
  end

  @doc """
  Closes external program's standard error pipe (stderr)

  Only owner of the pipe can close the pipe. This call will return
  immediately.
  """
  @spec close_stderr(t) :: :ok | {:error, any()}
  def close_stderr(process) do
    GenServer.call(process.pid, {:close_pipe, :stderr}, :infinity)
  end

  @doc """
  Writes iodata `data` to external program's standard input pipe.

  This call blocks when the pipe is full. Returns `:ok` when
  the complete data is written.
  """
  @spec write(t, binary) :: :ok | {:error, any()}
  def write(process, iodata) do
    binary = IO.iodata_to_binary(iodata)
    GenServer.call(process.pid, {:write_stdin, binary}, :infinity)
  end

  @doc """
  Returns bytes from executed command's stdout with maximum size `max_size`.

  Blocks if no data present in stdout pipe yet. And returns as soon as
  data of any size is available.

  Note that `max_size` is the maximum size of the returned data. But
  the returned data can be less than that depending on how the program
  flush the data etc.
  """
  @spec read(t, pos_integer()) :: {:ok, iodata} | :eof | {:error, any()}
  def read(process, max_size \\ @default_buffer_size)
      when is_integer(max_size) and max_size > 0 and max_size <= @default_buffer_size do
    GenServer.call(process.pid, {:read_stdout, max_size}, :infinity)
  end

  @doc """
  Changes the Pipe owner of the pipe to specified pid.

  Note that currently any process can change the pipe owner.

  For more details about Pipe Owner, please check module docs.
  """
  @spec change_pipe_owner(t, pipe_name, pid) :: :ok | {:error, any()}
  def change_pipe_owner(process, pipe_name, target_owner_pid) do
    GenServer.call(
      process.pid,
      {:change_pipe_owner, pipe_name, target_owner_pid},
      :infinity
    )
  end

  @doc """
  Wait for the program to terminate and get exit status.

  **ONLY** the Process owner can call this function. And all ExCmd
  **process MUST** be awaited (Similar to Task).

  ExCmd first politely asks the program to terminate by closing the
  pipes owned by the process owner (by default process owner is the
  pipes owner). Most programs terminates when standard pipes are
  closed.

  If you have changed the pipe owner to other process, you have to
  close pipe yourself or wait for the program to exit.

  If the program fails to terminate within the timeout (default 5s)
  then the program will be killed using the exit sequence by sending
  `SIGTERM`, `SIGKILL` signals in sequence.

  When timeout is set to `:infinity` `await_exit` wait for the
  programs to terminate indefinitely.

  For more details check module documentation.
  """
  @spec await_exit(t, timeout :: timeout()) :: {:ok, exit_status}
  def await_exit(process, timeout \\ 5000) do
    %__MODULE__{
      monitor_ref: monitor_ref,
      exit_ref: exit_ref,
      owner: owner,
      pid: pid
    } = process

    cond do
      self() != owner ->
        raise ArgumentError,
              "task #{inspect(process)} exit status can only be queried by owner but was queried from #{inspect(self())}"

      timeout != :infinity && !is_integer(timeout) ->
        raise ArgumentError, "timeout must be an integer or :infinity"

      true ->
        :ok
    end

    graceful_exit_timeout =
      if timeout == :infinity do
        :infinity
      else
        # process exit steps should finish before receive timeout exceeds
        # receive timeout is max allowed time for the `await_exit` call to block
        max(50, timeout)
      end

    :ok = GenServer.cast(pid, {:prepare_exit, owner, graceful_exit_timeout})

    receive do
      {^exit_ref, exit_status} ->
        Process.demonitor(monitor_ref, [:flush])
        exit_status

      {:DOWN, ^monitor_ref, _, _proc, reason} ->
        exit({reason, {__MODULE__, :await_exit, [process, timeout]}})
    after
      # ideally we should never this this case since the process must
      # be terminated before the timeout and we should have received
      # `DOWN` message
      timeout ->
        exit({:timeout, {__MODULE__, :await_exit, [process, timeout]}})
    end
  end

  @doc """
  Returns OS pid of the command

  This is meant only for debugging. Avoid interacting with the
  external process directly
  """
  @spec os_pid(t) :: pos_integer()
  def os_pid(process) do
    GenServer.call(process.pid, :os_pid, :infinity)
  end

  ## Server

  @impl true
  def init(args) do
    {owner, args} = Map.pop!(args, :owner)
    {exit_ref, args} = Map.pop!(args, :exit_ref)

    state = %State{
      args: args,
      owner: owner,
      status: :init,
      operations: Operations.new(),
      exit_ref: exit_ref,
      monitor_ref: Process.monitor(owner)
    }

    {:ok, state, {:continue, nil}}
  end

  @impl true
  def handle_continue(nil, state) do
    {:noreply, exec(state)}
  end

  @impl true
  def handle_cast({:prepare_exit, caller, timeout}, state) do
    state = close_pipes(state, caller)

    case maybe_shutdown(state) do
      {:stop, :normal, state} ->
        {:stop, :normal, state}

      {:noreply, state} ->
        if timeout == :infinity do
          {:noreply, state}
        else
          {exit_timeout, kill_timeout} = divide_timeout(timeout)
          handle_info({:exit_sequence, :normal_exit, exit_timeout, kill_timeout}, state)
        end
    end
  end

  @impl true
  def handle_call({:change_pipe_owner, pipe_name, new_owner}, _from, state) do
    with {:ok, pipe} <- State.pipe(state, pipe_name),
         {:ok, new_pipe} <- Pipe.set_owner(pipe, new_owner),
         {:ok, state} <- State.put_pipe(state, pipe_name, new_pipe) do
      {:reply, :ok, state}
    else
      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:close_pipe, pipe_name}, {caller, _} = from, state) do
    with {:ok, pipe} <- State.pipe(state, pipe_name),
         {:ok, new_pipe} <- Pipe.close(pipe, caller),
         :ok <- GenServer.reply(from, :ok),
         {:ok, new_state} <- State.put_pipe(state, pipe_name, new_pipe) do
      maybe_shutdown(new_state)
    else
      {:error, _} = ret ->
        {:reply, ret, state}
    end
  end

  def handle_call({:read_stdout, size}, from, state) do
    case Operations.read(state, {:read_stdout, from, size}) do
      {:noreply, state} ->
        {:noreply, state}

      ret ->
        {:reply, ret, state}
    end
  end

  def handle_call({:write_stdin, binary}, from, state) do
    case State.pop_operation(state, :write_stdin) do
      {:error, :operation_not_found} ->
        case Operations.pending_input(state, from, binary) do
          {:noreply, state} ->
            {:noreply, state}

          {:error, term} ->
            raise inspect(term)
        end

      {:ok, {:write_stdin, :demand, nil}, state} ->
        case Operations.write(state, {:write_stdin, from, binary}) do
          {:noreply, state} ->
            {:noreply, state}

          ret ->
            :ok = GenServer.reply(from, ret)
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_call(:os_pid, _from, state) do
    {:reply, {:ok, state.os_pid}, state}
  end

  @impl true
  def handle_info(
        {:exit_sequence, current_stage, timeout, kill_timeout},
        %{status: status} = state
      ) do
    cond do
      status != :running ->
        {:noreply, state}

      current_stage == :normal_exit ->
        Elixir.Process.send_after(self(), {:exit_sequence, :kill, timeout, kill_timeout}, timeout)
        {:noreply, state}

      current_stage == :kill ->
        :ok = Proto.kill(state.port)
        Elixir.Process.send_after(self(), {:exit_sequence, :stop, timeout, kill_timeout}, timeout)
        {:noreply, state}

      current_stage == :stop ->
        {:stop, :sigkill_timeout, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {tag, bin} = Proto.parse_command(data)
    handle_command(tag, bin, state)
  end

  @impl true
  def handle_info({port, :eof}, %{port: port} = state) do
    state = State.set_stdout_status(state, :closed)

    case state.status do
      {:exit, exit} ->
        Operations.pending_callers(state)
        |> Enum.each(fn caller ->
          :ok = GenServer.reply(caller, {:error, :epipe})
        end)

        case exit do
          {:error, reason} ->
            send(state.owner, {state.exit_ref, {:error, reason}})

          exit_status when is_integer(exit_status) ->
            send(state.owner, {state.exit_ref, {:ok, exit_status}})
        end

      _ ->
        :ok
    end

    maybe_shutdown(state)
  end

  def handle_info({port, {:exit_status, odu_exit_status}}, %{port: port} = state) do
    if odu_exit_status != 0 do
      raise "Failed during command execution"
    end

    maybe_shutdown(state)
  end

  # we are only interested in Port exit signals
  def handle_info({:EXIT, port, reason}, %State{port: port} = state) when reason != :normal do
    Operations.pending_callers(state)
    |> Enum.each(fn caller ->
      :ok = GenServer.reply(caller, {:error, :epipe})
    end)

    state = set_exit_status(state, {:error, reason})

    maybe_shutdown(state)
  end

  def handle_info({:EXIT, port, :normal}, %State{port: port} = state) do
    maybe_shutdown(state)
  end

  # shutdown unconditionally when process owner exit normally.
  # Since ExCmd process is linked to the owner, in case of owner crash,
  # ex_cmd process will be killed by the VM.
  def handle_info(
        {:DOWN, owner_ref, :process, _pid, reason},
        %State{monitor_ref: owner_ref} = state
      ) do
    {:stop, reason, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = close_pipes(state, pid)
    maybe_shutdown(state)
  end

  @spec maybe_shutdown(State.t()) :: {:stop, :normal, State.t()} | {:noreply, State.t()}
  defp maybe_shutdown(state) do
    open_pipes_count =
      state.pipes
      |> Map.values()
      |> Enum.count(&Pipe.open?/1)

    if open_pipes_count == 0 &&
         !(state.status in [:init, :running]) &&
         state.stdout_status == :closed do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @spec exec(State.t()) :: State.t()
  defp exec(state) do
    Process.flag(:trap_exit, true)

    %{cmd_with_args: cmd_with_args, env: env} = state.args
    {os_pid, port} = Proto.start(cmd_with_args, env, Map.take(state.args, [:log, :stderr, :cd]))

    stderr =
      if state.stderr == :consume do
        Pipe.new(:stderr, port, state.owner)
      else
        Pipe.new(:stderr)
      end

    %State{
      state
      | port: port,
        os_pid: os_pid,
        status: :running,
        stdout_status: :open,
        pipes: %{
          stdin: Pipe.new(:stdin, port, state.owner),
          stdout: Pipe.new(:stdout, port, state.owner),
          stderr: stderr
        }
    }
  end

  @type recv_commands :: :output | :output_eof | :send_input | :exit_status

  @spec handle_command(recv_commands, binary, State.t()) :: {:noreply, State.t()}
  def handle_command(tag, bin, state) when tag in [:output_eof, :output] do
    # State.pipe_name_for_fd(state, read_resource)
    pipe_name = :stdout

    with {:ok, operation_name} <- Operations.match_pending_operation(state, pipe_name),
         {:ok, {_stream, from, _}, state} <- State.pop_operation(state, operation_name) do
      ret =
        case {operation_name, bin} do
          {:read_stdout_or_stderr, <<>>} ->
            :eof

          {:read_stdout_or_stderr, bin} ->
            # TODO: must be stderr in case of stderr
            {:ok, {:stdout, bin}}

          {name, <<>>} when name in [:read_stdout, :read_stderr] ->
            :eof

          {name, bin} when name in [:read_stdout, :read_stderr] ->
            {:ok, bin}
        end

      :ok = GenServer.reply(from, ret)
      {:noreply, state}
    else
      {:error, _error} ->
        {:noreply, state}
    end
  end

  def handle_command(:send_input, <<>>, state) do
    case State.pop_operation(state, :write_stdin) do
      {:error, :operation_not_found} ->
        case Operations.demand_input(state) do
          {:noreply, state} ->
            {:noreply, state}

          {:error, term} ->
            raise inspect(term)
        end

      {:ok, {:write_stdin, from, _bin} = operation, state} when from != :demand ->
        case Operations.write(state, operation) do
          {:noreply, state} ->
            {:noreply, state}

          ret ->
            :ok = GenServer.reply(from, ret)
            {:noreply, state}
        end
    end
  end

  def handle_command(:exit_status, exit_status, state) do
    Operations.pending_callers(state)
    |> Enum.each(fn caller ->
      :ok = GenServer.reply(caller, {:error, :epipe})
    end)

    state =
      state
      |> State.set_stdout_status(:closed)
      |> set_exit_status({:ok, exit_status})

    maybe_shutdown(state)
  end

  @spec close_pipes(State.t(), caller) :: State.t()
  defp close_pipes(state, caller) do
    state =
      case Pipe.close(state.pipes.stdin, caller) do
        {:ok, pipe} ->
          {:ok, state} = State.put_pipe(state, pipe.name, pipe)
          state

        {:error, _} ->
          state
      end

    Enum.reduce(state.pipes, state, fn {_pipe_name, pipe}, state ->
      case Pipe.close(pipe, caller) do
        {:ok, pipe} ->
          {:ok, state} = State.put_pipe(state, pipe.name, pipe)
          state

        {:error, _} ->
          state
      end
    end)
  end

  @spec divide_timeout(non_neg_integer) :: {non_neg_integer, non_neg_integer}
  defp divide_timeout(timeout) when timeout < 10, do: {0, 0}

  defp divide_timeout(timeout) do
    timeout = timeout - 10

    if timeout < 50 do
      {timeout, 0}
    else
      kill_timeout = min(50, timeout - 50)
      {timeout - kill_timeout, kill_timeout}
    end
  end

  @spec set_exit_status(State.t(), {:error, term} | {:ok, integer}) :: State.t()
  defp set_exit_status(state, status) do
    status =
      case status do
        {:error, reason} ->
          {:error, reason}

        {:ok, -1} ->
          {:error, :killed}

        {:ok, exit_status} when is_integer(exit_status) and exit_status >= 0 ->
          {:ok, exit_status}
      end

    send(state.owner, {state.exit_ref, status})

    State.set_status(state, {:exit, status})
  end
end
