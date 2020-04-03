defmodule ExCmd.ProcServer do
  require Logger
  alias ExCmd.FIFO
  use GenServer

  @default %{use_stderr: false}

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
        opts: Map.merge(@default, opts)
      }
    )
  end

  def run(server), do: GenServer.call(server, :run)

  def open_input(server), do: GenServer.call(server, {:open_fifo, :input, :write})

  def open_output(server), do: GenServer.call(server, {:open_fifo, :output, :read})

  def open_error(server), do: GenServer.call(server, {:open_fifo, :error, :read})

  def read(server, timeout \\ :infinity) do
    GenServer.call(server, :read, timeout)
  catch
    :exit, {:normal, _} -> :closed
  end

  def read_error(server, timeout \\ :infinity) do
    GenServer.call(server, :read_error, timeout)
  catch
    :exit, {:normal, _} -> :closed
  end

  def write(server, data, timeout \\ :infinity) do
    GenServer.call(server, {:write, data}, timeout)
  catch
    :exit, {:normal, _} -> :closed
  end

  def close_input(server), do: GenServer.call(server, :close_input)

  def stop(server), do: GenServer.stop(server, :normal)

  def status(server), do: GenServer.call(server, :status)

  def await_exit(server, timeout \\ :infinity), do: GenServer.call(server, {:await_exit, timeout})

  def port_info(server), do: GenServer.call(server, :port_info)

  def init(params) do
    {:ok, nil, {:continue, params}}
  end

  def handle_continue(params, _) do
    Process.flag(:trap_exit, true)

    Temp.track!()
    dir = Temp.mkdir!()
    input_fifo_path = Temp.path!(%{basedir: dir})
    FIFO.create(input_fifo_path)

    output_fifo_path = Temp.path!(%{basedir: dir})
    FIFO.create(output_fifo_path)

    error_fifo_path =
      if params.opts.use_stderr do
        path = Temp.path!(%{basedir: dir})
        FIFO.create(path)
        path
      else
        nil
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

  def handle_call(
        {:open_fifo, :error, _},
        _from,
        %{params: %{opts: %{use_stderr: false}}} = state
      ) do
    {:reply, {:error, :invalid_operation}, state}
  end

  # All blocking FIFO operations such as open, read, write etc, should
  # be offloaded to specific fifo GenServer. ProcServer must be
  # non-blocking
  def handle_call({:open_fifo, type, mode}, from, state) do
    {:ok, fifo} = GenServer.start_link(FIFO, %{path: state.fifo_paths[type], mode: mode})
    FIFO.open(fifo, from)
    {:noreply, Map.put(state, type, fifo)}
  end

  def handle_call({:await_exit, _}, _, %{state: {:done, status}} = state) do
    {:reply, {:ok, status}, state}
  end

  def handle_call({:await_exit, timeout}, from, state) do
    state =
      if timeout != :infinity do
        timeout_ref = Process.send_after(self(), {:await_timeout, from}, timeout)
        Map.put(state, :timeout_ref, timeout_ref)
      else
        state
      end

    {:noreply, Map.put(state, :waiting_process, from)}
  end

  def handle_call(:status, _, %{state: proc_state} = state) do
    {:reply, proc_state, state}
  end

  def handle_call(:port_info, _, state) do
    {:reply, Port.info(state.port), state}
  end

  def handle_call({:write, _}, _, %{input: :closed} = state) do
    {:reply, :closed, state}
  end

  def handle_call({:write, _}, _, %{state: {:done, _}} = state) do
    {:reply, :closed, state}
  end

  def handle_call({:write, data}, from, state) do
    FIFO.write(state.input, data, from)
    {:noreply, state}
  end

  def handle_call(:read, from, state) do
    FIFO.read(state.output, from)
    {:noreply, state}
  end

  def handle_call(:read_error, from, state) do
    FIFO.read(state.error, from)
    {:noreply, state}
  end

  def handle_call(:close_input, _, %{input: :closed} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:close_input, _, state) do
    # can not use :normal as a process might have pending write which
    # can exit delay arbirarily
    Process.exit(state.input, :force_close)
    {:reply, :ok, %{state | input: :closed}}
  end

  def handle_info({:EXIT, _, reason}, state) when reason in [:normal, :force_close] do
    {:noreply, state}
  end

  def handle_info({:EXIT, _, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.debug("command exited with status: #{status}")

    {waiting_process, state} = Map.pop(state, :waiting_process)

    if waiting_process do
      GenServer.reply(waiting_process, {:ok, status})
    end

    {await_timeout, state} = Map.pop(state, :await_timeout)

    if await_timeout do
      :timer.cancel(await_timeout)
    end

    {:noreply, %{state | state: {:done, status}}}
  end

  def handle_info({:await_timeout, pid}, state) do
    GenServer.reply(pid, :timeout)
    {:noreply, Map.drop(state, [:waiting_process, :timeout_ref])}
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
      ["-stdin", input_path, "-stdout", output_path, "-stderr", error_path || ""]
  end
end
