defmodule ExCmd.ProcessServer do
  @moduledoc false

  require Logger
  alias ExCmd.FIFO
  use GenStateMachine, callback_mode: :handle_event_function

  def start_link([cmd | args], opts \\ %{}) do
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

  def init(params) do
    actions = [{:next_event, :internal, :setup}]
    {:ok, :init, params, actions}
  end

  def handle_event(:internal, :setup, :init, params) do
    Process.flag(:trap_exit, true)

    Temp.track!()
    dir = Temp.mkdir!()

    input_fifo_path =
      unless params.opts[:no_stdin] do
        path = Temp.path!(%{basedir: dir})
        FIFO.create(path)
        path
      end

    output_fifo_path = Temp.path!(%{basedir: dir})
    FIFO.create(output_fifo_path)

    error_fifo_path =
      unless params.opts[:no_stderr] do
        path = Temp.path!(%{basedir: dir})
        FIFO.create(path)
        path
      end

    data = %{
      input: nil,
      output: nil,
      error: nil,
      fifo_paths: %{
        input: input_fifo_path,
        output: output_fifo_path,
        error: error_fifo_path
      },
      params: params,
      waiting_processes: MapSet.new()
    }

    {:next_state, :setup, data, []}
  end

  def handle_event({:call, from}, :run, :setup, data) do
    paths = data.fifo_paths
    port = start_odu_port(data.params, paths.input, paths.output, paths.error)

    # ordering matters. see: func openIOFiles(...) in odu
    input = open_fifo(paths.input, :write)
    output = open_fifo(paths.output, :read)
    error = open_fifo(paths.error, :read)

    data =
      Map.merge(data, %{port: port, state: :started, input: input, output: output, error: error})

    actions = [{:reply, from, :ok}]
    {:next_state, :started, data, actions}
  end

  # All blocking FIFO operations such as open, read, write etc, should
  # be offloaded to specific fifo GenServer. ProcessServer must be
  # non-blocking
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

  def handle_event({:call, from}, :port_info, state, data) when state not in [:init, :setup] do
    {:keep_state_and_data, [{:reply, from, Port.info(data.port)}]}
  end

  def handle_event({:call, from}, {:write, bin}, state, data) do
    cond do
      is_nil(data.fifo_paths.input) ->
        {:keep_state_and_data, [{:reply, from, {:error, :unused_stream}}]}

      data.input == :closed || match?({:done, _}, state) ->
        {:keep_state_and_data, [{:reply, from, {:error, :closed}}]}

      true ->
        FIFO.write(data.input, bin, from)
        {:keep_state_and_data, []}
    end
  end

  def handle_event({:call, from}, :read, _, data) do
    cond do
      is_nil(data.fifo_paths.output) ->
        {:keep_state_and_data, [{:reply, from, {:error, :unused_stream}}]}

      data.output == :closed ->
        {:keep_state_and_data, [{:reply, from, {:error, :closed}}]}

      true ->
        FIFO.read(data.output, from)
        {:keep_state_and_data, []}
    end
  end

  def handle_event({:call, from}, :read_error, _, data) do
    cond do
      is_nil(data.fifo_paths.error) ->
        {:keep_state_and_data, [{:reply, from, {:error, :unused_stream}}]}

      data.error == :closed ->
        {:keep_state_and_data, [{:reply, from, {:error, :closed}}]}

      true ->
        FIFO.read(data.error, from)
        {:keep_state_and_data, []}
    end
  end

  def handle_event({:call, from}, :close_stdin, _, data) do
    cond do
      !data.fifo_paths[:input] ->
        Logger.debug(fn -> "Can not close unused input stream" end)
        {:keep_state_and_data, [{:reply, from, {:error, :unused_stream}}]}

      data.input == :closed ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      true ->
        # can not use :normal as a process might have pending write which
        # can delay exit arbitrarily
        Process.exit(data.input, :force_close)
        {:keep_state, %{data | input: :closed}, [{:reply, from, :ok}]}
    end
  end

  def handle_event(:info, {:EXIT, _, reason}, _, data) do
    if reason in [:normal, :force_close] do
      {:keep_state_and_data, []}
    else
      {:stop, reason, data}
    end
  end

  def handle_event(:info, {port, {:exit_status, exit_status}}, _, %{port: port} = data) do
    Logger.debug("command exited with status: #{exit_status}")

    actions =
      Enum.flat_map(data.waiting_processes, fn pid ->
        [{:reply, pid, {:ok, exit_status}}, {{:timeout, {:await_exit, pid}}, :infinity, nil}]
      end)

    {:next_state, {:done, exit_status}, %{data | waiting_processes: MapSet.new()}, actions}
  end

  def handle_event({:timeout, {:await_exit, from}}, _, _, data) do
    {:keep_state, %{data | waiting_processes: MapSet.delete(data.waiting_processes, from)},
     [{:reply, from, :timeout}]}
  end

  def open_fifo(nil, _mode), do: nil

  def open_fifo(path, mode) do
    {:ok, fifo} = GenServer.start_link(FIFO, %{path: path, mode: mode})
    FIFO.open(fifo)
    fifo
  end

  defp start_odu_port(params, input_path, output_path, error_path) do
    args =
      build_odu_params(params.opts, input_path, output_path, error_path) ++
        ["--" | params.cmd_with_args]

    options = [:use_stdio, :exit_status, :binary, :hide, {:packet, 2}, args: args]
    Port.open({:spawn_executable, params.odu_path}, options)
  end

  defp build_odu_params(opts, input_path, output_path, error_path) do
    odu_config_params = ["-log", if(opts[:log], do: "|2", else: "")]

    odu_config_params ++
      ["-stdin", input_path || "", "-stdout", output_path, "-stderr", error_path || ""]
  end
end
