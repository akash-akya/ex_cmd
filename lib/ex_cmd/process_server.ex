defmodule ExCmd.ProcessServer do
  require Logger
  alias ExCmd.FIFO
  use GenServer

  def start_link(cmd, args, opts \\ %{}) do
    odu_path = :os.find_executable('odu')

    if !odu_path do
      raise "'odu' executable not found"
    end

    cmd_path = :os.find_executable(to_charlist(cmd))

    if !cmd_path do
      raise "'#{cmd}' executable not found"
    end

    GenServer.start_link(
      __MODULE__,
      %{
        odu_path: odu_path,
        cmd_path: cmd_path,
        args: args,
        opts: opts
      }
    )
  end

  def init(params) do
    {:ok, nil, {:continue, params}}
  end

  def handle_continue(params, _) do
    Process.flag(:trap_exit, true)

    Temp.track!()
    dir = Temp.mkdir!()

    input_fifo_path =
      unless params.opts.no_stdin do
        path = Temp.path!(%{basedir: dir})
        FIFO.create(path)
        path
      end

    output_fifo_path = Temp.path!(%{basedir: dir})
    FIFO.create(output_fifo_path)

    error_fifo_path =
      unless params.opts.no_stderr do
        path = Temp.path!(%{basedir: dir})
        FIFO.create(path)
        path
      end

    {:noreply,
     %{
       state: :init,
       input: nil,
       output: nil,
       error: nil,
       fifo_paths: %{
         input: input_fifo_path,
         output: output_fifo_path,
         error: error_fifo_path
       },
       params: params
     }}
  end

  # TODO: re-check state machine and raise proper errors for invalid state transitions
  def handle_call(:run, _, state) do
    paths = state.fifo_paths
    port = start_odu_port(state.params, paths.input, paths.output, paths.error)
    {:reply, :ok, Map.merge(state, %{port: port, state: :started})}
  end

  # All blocking FIFO operations such as open, read, write etc, should
  # be offloaded to specific fifo GenServer. ProcessServer must be
  # non-blocking
  def handle_call({:open_fifo, type, mode}, from, state) do
    cond do
      !state.fifo_paths[type] ->
        Logger.debug(fn -> "Can not open unused #{type} stream" end)
        {:reply, {:error, :unused_stream}, state}

      state[type] ->
        {:reply, {:error, :already_opened}, state}

      true ->
        {:ok, fifo} = GenServer.start_link(FIFO, %{path: state.fifo_paths[type], mode: mode})
        FIFO.open(fifo, from)
        {:noreply, Map.put(state, type, fifo)}
    end
  end

  def handle_call({:await_exit, _}, _, %{state: {:done, status}} = state) do
    {:reply, {:ok, status}, state}
  end

  def handle_call({:await_exit, timeout}, from, state) do
    timeout_ref =
      if timeout != :infinity do
        Process.send_after(self(), {:await_timeout, from}, timeout)
      else
        nil
      end

    state =
      Map.update(
        state,
        :waiting_processes,
        %{from => timeout_ref},
        &Map.put(&1, from, timeout_ref)
      )

    {:noreply, state}
  end

  def handle_call(:status, _, %{state: proc_state} = state) do
    {:reply, proc_state, state}
  end

  def handle_call(:port_info, _, state) do
    {:reply, Port.info(state.port), state}
  end

  def handle_call({:write, _}, _, %{fifo_paths: %{input: nil}} = state) do
    {:reply, {:error, :unused_stream}, state}
  end

  def handle_call({:write, _}, _, %{input: :closed} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:write, _}, _, %{state: {:done, _}} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:write, data}, from, state) do
    FIFO.write(state.input, data, from)
    {:noreply, state}
  end

  def handle_call(:read, from, state) do
    if state[:output] == :closed do
      {:reply, {:error, :closed}, state}
    else
      FIFO.read(state.output, from)
      {:noreply, state}
    end
  end

  def handle_call(:read_error, from, state) do
    if state[:error] == :closed do
      {:reply, {:error, :closed}, state}
    else
      FIFO.read(state.error, from)
      {:noreply, state}
    end
  end

  def handle_call(:close_input, _, state) do
    cond do
      !state.fifo_paths[:input] ->
        Logger.debug(fn -> "Can not close unused input stream" end)
        {:reply, {:error, :unused_stream}, state}

      state[:input] == :closed ->
        {:reply, :ok, state}

      true ->
        # can not use :normal as a process might have pending write which
        # can delay exit arbitrarily
        Process.exit(state.input, :force_close)
        {:reply, :ok, %{state | input: :closed}}
    end
  end

  def handle_info({:EXIT, _, reason}, state) when reason in [:normal, :force_close] do
    {:noreply, state}
  end

  def handle_info({:EXIT, _, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.debug("command exited with status: #{status}")

    {waiting_process, state} = Map.pop(state, :waiting_processes)

    if waiting_process do
      for {pid, timeout_ref} <- waiting_process do
        GenServer.reply(pid, {:ok, status})
        if timeout_ref, do: :timer.cancel(timeout_ref)
      end
    end

    {:noreply, %{state | state: {:done, status}}}
  end

  def handle_info({:await_timeout, pid}, state) do
    GenServer.reply(pid, :timeout)
    {:noreply, Map.update!(state, :waiting_processes, &Map.delete(&1, pid))}
  end

  defp start_odu_port(params, input_path, output_path, error_path) do
    args =
      build_odu_params(params.opts, input_path, output_path, error_path) ++
        ["--", to_string(params.cmd_path) | params.args]

    options = [:use_stdio, :exit_status, :binary, :hide, {:packet, 2}, args: args]
    Port.open({:spawn_executable, params.odu_path}, options)
  end

  defp build_odu_params(opts, input_path, output_path, error_path) do
    odu_config_params = ["-log", if(opts[:log], do: "|2", else: "")]

    odu_config_params ++
      ["-stdin", input_path || "", "-stdout", output_path, "-stderr", error_path || ""]
  end
end
