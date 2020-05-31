defmodule ExCmd.Process do
  @moduledoc """
  Server to interact with external process

  `ExCmd.stream!` should be preferred over this. Use this only if you need more control over the life-cycle of IO streams and OS process.
  """

  @default [log: false, no_stderr: true]

  @doc """
  Starts a process using `cmd_with_args` and with options `opts`

  `cmd_with_args` must be a list containing command with arguments. example: `["cat", "file.txt"]`.

  ### Options
    * `cd`             -  the directory to run the command in
    * `env`            -  an enumerable of tuples containing environment key-value. These can be accessed in the external program
    * `log`            -  When set to `true` odu outputs are logged. Defaults to `false`
  """
  def start_link([cmd | args], opts \\ []) do
    opts = Keyword.merge(@default, opts)
    odu_path = :os.find_executable('odu')

    if !odu_path do
      raise "'odu' executable not found"
    end

    cmd_path = :os.find_executable(to_charlist(cmd))

    if !cmd_path do
      raise "'#{cmd}' executable not found"
    end

    GenStateMachine.start_link(__MODULE__, %{
      odu_path: odu_path,
      cmd_with_args: [to_string(cmd_path) | args],
      opts: opts
    })
  end

  # client

  @doc """
  Return bytes written by the program to output stream.

  This blocks until the programs write and flush the output
  """
  @spec read(pid, non_neg_integer | :infinity) ::
          {:ok, iodata} | :eof | {:error, String.t()} | :closed
  def read(server, timeout \\ :infinity) do
    GenStateMachine.call(server, :read, timeout)
  end

  @doc """
  Return bytes written by the program to error stream.

  This blocks until the programs write and flush the output
  """
  @spec read_error(pid, non_neg_integer | :infinity) ::
          {:ok, iodata} | :eof | {:error, String.t()} | :closed
  def read_error(server, timeout \\ :infinity) do
    GenStateMachine.call(server, :read_error, timeout)
  end

  @doc """
  Writes iodata `data` to programs input streams

  This blocks when the fifo is full
  """
  @spec write(pid, iodata, non_neg_integer | :infinity) :: :ok | {:error, String.t()} | :closed
  def write(server, data, timeout \\ :infinity) do
    GenStateMachine.call(server, {:write, data}, timeout)
  end

  @doc """
  Closes input stream. Which signal EOF to the program
  """
  def close_stdin(server), do: GenStateMachine.call(server, :close_stdin)

  @doc """
  Kills the program
  """
  def stop(server), do: GenStateMachine.stop(server, :normal)

  @doc """
  Returns status of the process. It will be either of `:started`, `{:done, exit_status}`
  """
  def status(server), do: GenStateMachine.call(server, :status)

  @doc """
  Returns os pid of the command
  """
  def os_pid(server), do: GenStateMachine.call(server, :os_pid)

  @doc """
  Waits for the program to terminate.

  If the program terminates before timeout, it returns `{:ok, exit_status}` else returns `:timeout`
  """
  def await_exit(server, timeout \\ :infinity),
    do: GenStateMachine.call(server, {:await_exit, timeout})

  @doc """
  Returns [port_info](http://erlang.org/doc/man/erlang.html#port_info-1)
  """
  def port_info(server), do: GenStateMachine.call(server, :port_info)

  ## server
  require Logger
  use GenStateMachine, callback_mode: :handle_event_function

  defmacro send_input, do: 1
  defmacro send_output, do: 2
  defmacro output, do: 3
  defmacro input, do: 4
  defmacro close_input, do: 5
  defmacro output_eof, do: 6
  defmacro command_env, do: 7
  defmacro os_pid, do: 8

  # 4 byte length prefix + 1 byte tag
  @max_chunk_size 64 * 1024 - 5

  def init(params) do
    actions = [{:next_event, :internal, :setup}]
    {:ok, :init, params, actions}
  end

  def handle_event(:internal, :setup, :init, params) do
    Process.flag(:trap_exit, true)

    odu_opts = Keyword.take(params.opts, [:log, :cd])
    port = start_odu_port(params.odu_path, params.cmd_with_args, odu_opts)
    send_env(params.opts[:env], port)

    os_pid =
      receive do
        {^port, {:data, <<os_pid()::unsigned-integer-8, os_pid::big-unsigned-integer-32>>}} ->
          Logger.debug("Command started. os pid: #{os_pid}")
          os_pid
      after
        5_000 ->
          raise "Failed to start command"
      end

    data = %{
      pending_write: [],
      pending_read: [],
      input_ready: false,
      waiting_processes: MapSet.new(),
      port: port,
      os_pid: os_pid
    }

    {:next_state, :started, data, []}
  end

  def handle_event({:call, from}, {:await_exit, timeout}, state, data) do
    case state do
      {:done, exit_status} ->
        {:keep_state_and_data, [{:reply, from, {:ok, exit_status}}]}

      _ ->
        actions = [{{:timeout, {:await_exit, from}}, timeout, nil}]
        data = %{data | waiting_processes: MapSet.put(data.waiting_processes, from)}
        {:keep_state, data, actions}
    end
  end

  def handle_event({:call, from}, :status, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle_event({:call, from}, :os_pid, _state, %{os_pid: os_pid}) do
    {:keep_state_and_data, [{:reply, from, os_pid}]}
  end

  def handle_event({:call, from}, :port_info, state, data) when state not in [:init, :setup] do
    {:keep_state_and_data, [{:reply, from, Port.info(data.port)}]}
  end

  def handle_event(:internal, :input_ready, _state, data) do
    {data, actions} = try_sending_input(data)
    {:keep_state, data, actions}
  end

  def handle_event({:call, from}, {:write, iodata}, :started, data) do
    bin = IO.iodata_to_binary(iodata)
    data = %{data | pending_write: data.pending_write ++ [{from, bin}]}
    {data, actions} = try_sending_input(data)
    {:keep_state, data, actions}
  end

  def handle_event({:call, from}, {:write, _iodata}, _state, _) do
    {:keep_state_and_data, [{:reply, from, {:error, :epipe}}]}
  end

  def handle_event({:call, from}, :read, state, data) when state in [:started, :input_closed] do
    {:keep_state, request_output(from, data), []}
  end

  def handle_event({:call, from}, :read, _state, _) do
    {:keep_state_and_data, [{:reply, from, :eof}]}
  end

  def handle_event({:call, from}, :close_stdin, :started, data) do
    {data, actions} = close_stream(:stdin, from, data)
    {data, write_actions} = handle_stdin_close(data)

    {:next_state, :input_closed, data, actions ++ write_actions}
  end

  def handle_event({:call, from}, :close_stdin, _, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def handle_event(:info, {:EXIT, port, _reason}, state, %{port: port} = data) do
    {data, write_actions} = handle_stdin_close(data)
    {data, read_actions} = handle_eof(data)
    {data, await_exit_actions} = reply_await_exit(data, {:error, :stopped})

    if state in [:started, :input_closed] do
      {:next_state, :port_closed, data, write_actions ++ read_actions ++ await_exit_actions}
    else
      {:keep_state, data, write_actions ++ read_actions ++ await_exit_actions}
    end
  end

  def handle_event(:info, {:EXIT, _, reason}, _, data) do
    {:stop_and_reply, reason, [], data}
  end

  def handle_event(:info, {port, {:exit_status, exit_status}}, _, %{port: port} = data) do
    Logger.debug("command exited with status: #{exit_status}")

    {data, write_actions} = handle_stdin_close(data)
    {data, read_actions} = handle_eof(data)
    {data, await_exit_actions} = reply_await_exit(data, {:ok, exit_status})

    {:next_state, {:done, exit_status}, data, write_actions ++ read_actions ++ await_exit_actions}
  end

  def handle_event(:info, {port, {:data, output}}, _, %{port: port} = data) do
    <<tag::unsigned-integer-8, bin::binary>> = output
    {data, actions} = handle_command(tag, bin, data)
    {:keep_state, data, actions}
  end

  def handle_event({:timeout, {:await_exit, from}}, _, _, data) do
    {:keep_state, %{data | waiting_processes: MapSet.delete(data.waiting_processes, from)},
     [{:reply, from, :timeout}]}
  end

  defp start_odu_port(odu_path, cmd_with_args, opts) do
    args = build_odu_params(opts) ++ ["--" | cmd_with_args]
    options = [:use_stdio, :exit_status, :binary, :hide, {:packet, 4}, args: args]
    Port.open({:spawn_executable, odu_path}, options)
  end

  defp build_odu_params(opts) do
    log = if(opts[:log], do: "|2", else: "")
    cd = Path.expand(opts[:cd] || File.cwd!())

    if !File.exists?(cd) || !File.dir?(cd) do
      raise ":cd is not a valid path"
    end

    ["-log", log, "-cd", cd]
  end

  defp handle_command(output_eof(), <<>>, data) do
    handle_eof(data)
  end

  defp handle_command(output(), bin, %{pending_read: [pid | pending]} = data) do
    actions = [{:reply, pid, {:ok, bin}}]

    data =
      if Enum.empty?(pending) do
        %{data | pending_read: []}
      else
        send_command(send_output(), <<>>, data.port)
        %{data | pending_read: pending}
      end

    {data, actions}
  end

  defp handle_command(send_input(), <<>>, data) do
    data = %{data | input_ready: true}
    actions = [{:next_event, :internal, :input_ready}]

    {data, actions}
  end

  defp send_env(nil, port), do: send_env([], port)

  defp send_env(env, port) do
    payload =
      Enum.map(env, fn {key, value} ->
        entry = String.trim(key) <> "=" <> String.trim(value)

        if byte_size(entry) > 65536 do
          raise "Env entry length exceeds limit"
        end

        <<byte_size(entry)::big-unsigned-integer-16, entry::binary>>
      end)
      |> Enum.join()

    send_command(command_env(), payload, port)
  end

  defp handle_stdin_close(data) do
    actions =
      Enum.flat_map(data.pending_write, fn {pid, _} ->
        [{:reply, pid, {:error, :epipe}}]
      end)

    {%{data | pending_write: []}, actions}
  end

  defp handle_eof(data) do
    actions =
      Enum.flat_map(data.pending_read, fn pid ->
        [{:reply, pid, :eof}]
      end)

    {%{data | pending_read: []}, actions}
  end

  defp reply_await_exit(data, response) do
    actions =
      Enum.flat_map(data.waiting_processes, fn pid ->
        [{:reply, pid, response}, {{:timeout, {:await_exit, pid}}, :infinity, nil}]
      end)

    {%{data | waiting_processes: MapSet.new()}, actions}
  end

  defp try_sending_input(%{pending_write: [{pid, bin} | pending], input_ready: true} = data) do
    {chunk, bin} = binary_split_at(bin, @max_chunk_size)
    send_command(input(), chunk, data.port)

    if bin == <<>> do
      actions = [{:reply, pid, :ok}]
      data = %{data | pending_write: pending, input_ready: false}
      {data, actions}
    else
      data = %{data | pending_write: [{pid, bin} | pending], input_ready: false}
      {data, []}
    end
  end

  defp try_sending_input(data) do
    {data, []}
  end

  defp request_output(from, %{pending_read: []} = data) do
    send_command(send_output(), <<>>, data.port)
    %{data | pending_read: [from]}
  end

  defp request_output(from, data) do
    %{data | pending_read: data.pending_read ++ [from]}
  end

  defp close_stream(:stdin, pid, data) do
    send_command(close_input(), <<>>, data.port)
    actions = [{:reply, pid, :ok}]
    {data, actions}
  end

  defp send_command(tag, bin, port) do
    bin = <<tag::unsigned-integer-8, bin::binary>>
    Port.command(port, bin)
  end

  defp binary_split_at(bin, pos) when byte_size(bin) <= pos, do: {bin, <<>>}

  defp binary_split_at(bin, pos) do
    len = byte_size(bin)
    {binary_part(bin, 0, pos), binary_part(bin, pos, len - pos)}
  end
end
