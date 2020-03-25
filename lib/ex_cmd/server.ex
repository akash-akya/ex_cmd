defmodule ExCmd.Server do
  require Logger
  use GenServer

  defstruct [:port_server, :input_fifo, :output_fifo]

  def start_server(cmd, args, opts \\ %{}) do
    odu_path = :os.find_executable('odu')

    if !odu_path do
      raise "'odu' executable not found"
    end

    cmd_path = :os.find_executable(to_charlist(cmd))

    if !cmd_path do
      raise "'#{cmd}' executable not found"
    end

    {:ok, input_fifo} = GenServer.start_link(ExCmd.Fifo, nil)
    {:ok, output_fifo} = GenServer.start_link(ExCmd.Fifo, nil)

    {:ok, server} =
      GenServer.start_link(__MODULE__, %{
        odu_path: odu_path,
        cmd_path: cmd_path,
        args: args,
        opts: opts,
        input_fifo: input_fifo,
        output_fifo: output_fifo
      })

    %__MODULE__{port_server: server, input_fifo: input_fifo, output_fifo: output_fifo}
  end

  def read(server) do
    ExCmd.Fifo.read(server.output_fifo)
  end

  def write(server, data) do
    ExCmd.Fifo.write(server.input_fifo, data)
  end

  def close_input(server) do
    ExCmd.Fifo.close(server.input_fifo)
  end

  def stop(server) do
    # FIXME: we should only stop port_server, IO GenServers should stop automatically
    GenServer.stop(server.input_fifo, :normal)
    GenServer.stop(server.output_fifo, :normal)
    GenServer.stop(server.port_server, :normal)
  end

  # TODO: link input and output GenServers
  def init(params) do
    Temp.track!()
    dir = Temp.mkdir!()
    input_fifo_path = Temp.path!(%{basedir: dir})
    create_fifo(input_fifo_path)

    output_fifo_path = Temp.path!(%{basedir: dir})
    create_fifo(output_fifo_path)

    port = start_odu_port(params, input_fifo_path, output_fifo_path)

    # TODO: create proper supervision tree and delete fifo files
    # *after* all GenServers exit
    :ok = ExCmd.Fifo.open(params.input_fifo, input_fifo_path, :write)
    :ok = ExCmd.Fifo.open(params.output_fifo, output_fifo_path, :read)

    {:ok, %{state: :started, port: port}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if status == 0 do
      Logger.info("Normal command exit")
    else
      Logger.info("Abnormal command exit status: #{status}")
    end

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

  defp create_fifo(path) do
    mkfifo = :os.find_executable('mkfifo')

    if !mkfifo do
      raise "Can not create named fifo, mkfifo command not found"
    end

    {"", 0} = System.cmd("mkfifo", [path])
    path
  end
end
