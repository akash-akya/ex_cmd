defmodule ExCmd.ProcServer do
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

    GenServer.start_link(__MODULE__, %{
      odu_path: odu_path,
      cmd_path: cmd_path,
      args: args,
      opts: opts
    })
  end

  def run(server), do: GenServer.call(server, :run)

  def open_input(server), do: GenServer.call(server, {:open_fifo, :input})

  def open_output(server), do: GenServer.call(server, {:open_fifo, :output})

  def read(server, timeout \\ :infinity) do
    GenServer.call(server, :read, timeout)
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

    {:noreply,
     %{
       state: :init,
       input_fifo_path: input_fifo_path,
       output_fifo_path: output_fifo_path,
       input: nil,
       output: nil,
       params: params
     }}
  end

  # TODO: re-check state machine and raise proper errors for invalid state transitions
  def handle_call(:run, _, state) do
    port = start_odu_port(state.params, state.input_fifo_path, state.output_fifo_path)
    {:reply, :ok, Map.merge(state, %{port: port, state: :started})}
  end

  # All blocking FIFO operations such as open, read, write etc, should
  # be offloaded to specific fifo GenServer. ProcServer must be
  # non-blocking
  def handle_call({:open_fifo, :input}, from, state) do
    {:ok, input_fifo} = GenServer.start_link(FIFO, %{path: state.input_fifo_path, mode: :write})
    FIFO.open(input_fifo, from)
    {:noreply, %{state | input: input_fifo}}
  end

  def handle_call({:open_fifo, :output}, from, state) do
    {:ok, output_fifo} = GenServer.start_link(FIFO, %{path: state.output_fifo_path, mode: :read})
    FIFO.open(output_fifo, from)
    {:noreply, %{state | output: output_fifo}}
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

  defp start_odu_port(params, input_fifo_path, output_fifo_path) do
    args =
      build_odu_params(params.opts, input_fifo_path, output_fifo_path) ++
        ["--", to_string(params.cmd_path) | params.args]

    options = [:use_stdio, :exit_status, :binary, :hide, {:packet, 2}, args: args]
    Port.open({:spawn_executable, params.odu_path}, options)
  end

  defp build_odu_params(opts, input_fifo_path, output_fifo_path) do
    odu_config_params =
      if opts[:log] do
        ["-log", "|2"]
      else
        []
      end

    odu_config_params ++ ["-input", input_fifo_path, "-output", output_fifo_path]
  end
end
