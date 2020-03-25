defmodule ExCmd.Fifo do
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil)
  end

  def write(server, data) do
    GenServer.call(server, {:write, data})
  end

  def read(server) do
    GenServer.call(server, :read)
  end

  def open(server, path, mode) do
    GenServer.call(server, {:open, path, mode})
  end

  def close(server) do
    _ = GenServer.call(server, :close)
    :ok
  end

  def init(_args) do
    {:ok, :init}
  end

  def handle_call({:open, path, mode}, _from, :init) do
    fifo = File.open!(path, [:binary, :raw, mode])
    {:reply, :ok, %{fifo: fifo, mode: mode}}
  end

  def handle_call({:write, data}, _from, %{mode: :write} = state) do
    data = [<<byte_size(data)::16>>, data]

    case :file.write(state.fifo, data) do
      :ok ->
        {:reply, :ok, state}

      # no reader. pipe is closed by the command program
      {:error, :epipe} ->
        {:reply, {:error, :epipe}, state}

      # pipe is already closed by the user
      {:error, :einval} ->
        {:reply, {:error, :einval}, state}
    end
  end

  def handle_call(:read, _from, %{mode: :read} = state) do
    case :file.read(state.fifo, 2) do
      {:ok, <<len::16-integer-big-unsigned>>} ->
        {:ok, data} = :file.read(state.fifo, len)
        {:reply, {:ok, data}, state}

      :eof ->
        {:reply, :eof, state}

      # pipe is already closed by the user
      {:error, :einval} ->
        {:reply, {:error, :einval}, state}
    end
  end

  def handle_call(:close, _from, state) do
    {:reply, :file.close(state.fifo), state}
  end
end
