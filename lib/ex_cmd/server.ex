defmodule ExCmd.Server do
  require Logger
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

  def pull(server, bytes) do
    GenServer.call(server, {:demand, bytes})
  end

  def stop(server) do
    GenServer.call(server, :stop)
    GenServer.stop(server)
  end

  def init(params) do
    {:ok, %{state: :init}, {:continue, params}}
  end

  def handle_continue(params, state) do
    odu_config_params =
      if params.opts[:log] do
        ["-log", "|2"]
      else
        []
      end

    args = odu_config_params ++ ["--", to_string(params.cmd_path) | params.args]
    opts = [:use_stdio, :exit_status, :binary, :hide, {:packet, 2}, args: args]
    port = Port.open({:spawn_executable, params.odu_path}, opts)

    state = Map.merge(state, %{port: port, state: :ready, waiting_proc: nil, demand: 0, data: []})

    {:noreply, state}
  end

  def handle_cast(_, _from, _state), do: {:error, :not_supported}

  def handle_call(:stop, from, %{state: {:done, _}} = state) do
    reply(from, :ok)
    {:noreply, state}
  end

  def handle_call(:stop, from, state) do
    # exit signal
    demand_output(state.port, 0)
    reply(from, :ok)
    {:noreply, %{state | state: {:done, :stop}, data: []}}
  end

  def handle_call({:demand, _demand}, from, %{state: {:done, status}} = state) do
    reply(from, [], status)
    {:noreply, state}
  end

  def handle_call({:demand, _demand}, from, %{state: :waiting} = state) do
    Logger.warn("Has pending request")
    GenServer.reply(from, {:error, :pending})
    {:noreply, state}
  end

  def handle_call({:demand, demand}, from, %{state: :ready} = state) do
    demand_output(state.port, demand)
    {:noreply, %{state | state: :waiting, waiting_proc: from, demand: demand, data: []}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if status == 0 do
      Logger.info("Normal command exit")
    else
      Logger.info("Abnormal command exit status: #{status}")
    end

    reply(state.waiting_proc, state.data, status)
    {:noreply, %{state | state: {:done, status}, data: []}}
  end

  def handle_info({port, {:data, <<0>> <> msg}}, %{port: port} = state) do
    data_size = IO.iodata_length(msg)
    IO.inspect("Got output of size: #{data_size}")

    data = [state.data, msg]
    total = IO.iodata_length(data)

    state =
      cond do
        total == state.demand ->
          reply(state.waiting_proc, data)
          %{state | state: :ready, waiting_proc: nil}

        total > state.demand ->
          raise "Command send more than requested"

        true ->
          %{state | data: data}
      end

    {:noreply, state}
  end

  defp reply(pid, data, status) do
    GenServer.reply(pid, {:done, data, status})
    :ok
  end

  defp reply(pid, data) do
    GenServer.reply(pid, {:cont, data})
    :ok
  end

  defp demand_output(port, demand) do
    data = [<<demand::32-integer-big-unsigned>>]
    true = Port.command(port, data)
  end
end
