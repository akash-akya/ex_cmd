defmodule ExCmd.ProcServer do
  require Logger
  alias ExCmd.FIFO
  use GenServer

  defstruct [:port_server, :input_fifo, :output_fifo]

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

  def read(server), do: GenServer.call(server, :read)

  def write(server, data), do: GenServer.call(server, {:write, data})

  def close_input(server), do: GenServer.call(server, :close_input)

  def stop(server), do: GenServer.stop(server, :normal)

  def status(server), do: GenServer.call(server, :status)

  def port_info(server), do: GenServer.call(server, :port_info)

  def init(params) do
    {:ok, nil, {:continue, params}}
  end

  def handle_continue(params, _) do
    Temp.track!()
    dir = Temp.mkdir!()
    input_fifo_path = Temp.path!(%{basedir: dir})
    FIFO.create(input_fifo_path)

    output_fifo_path = Temp.path!(%{basedir: dir})
    FIFO.create(output_fifo_path)

    port = start_odu_port(params, input_fifo_path, output_fifo_path)

    {:ok, input_fifo} = GenServer.start_link(FIFO, %{path: input_fifo_path, mode: :write})
    {:ok, output_fifo} = GenServer.start_link(FIFO, %{path: output_fifo_path, mode: :read})

    {:noreply, %{state: :started, port: port, input: input_fifo, output: output_fifo}}
  end

  def handle_call(:status, _, %{state: proc_state} = state) do
    {:reply, proc_state, state}
  end

  def handle_call(:port_info, _, state) do
    {:reply, Port.info(state.port), state}
  end

  def handle_call({:write, _}, _, %{state: {:done, status}} = state) do
    {:reply, {:command_exit, status}, state}
  end

  def handle_call({:write, data}, from, state) do
    FIFO.write(state.input, data, from)
    {:noreply, state}
  end

  def handle_call(:read, from, state) do
    FIFO.read(state.output, from)
    {:noreply, state}
  end

  def handle_call(:close_input, from, state) do
    FIFO.close(state.input, from)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("command exited with status: #{status}")
    {:noreply, %{state | state: {:done, status}}}
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
