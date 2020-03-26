defmodule ExCmd.FIFO do
  use GenServer
  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def write(server, data, from), do: GenServer.cast(server, {:write, data, from})

  def read(server, from), do: GenServer.cast(server, {:read, from})

  def close(server, from), do: GenServer.cast(server, {:close, from})

  def init(args) do
    fifo = File.open!(args.path, [:binary, :raw, args.mode])
    {:ok, %{fifo: fifo, mode: args.mode}}
  end

  def handle_cast({:write, data, from}, %{mode: :write} = state) do
    data = [<<byte_size(data)::16>>, data]

    case :file.write(state.fifo, data) do
      :ok ->
        GenServer.reply(from, :ok)

      {:error, type} = error when type in [:epipe, :einval] ->
        GenServer.reply(from, error)
    end

    {:noreply, state}
  end

  def handle_cast({:read, from}, %{mode: :read} = state) do
    case :file.read(state.fifo, 2) do
      {:ok, <<len::16-integer-big-unsigned>>} ->
        {:ok, data} = :file.read(state.fifo, len)
        GenServer.reply(from, {:ok, data})

      :eof ->
        GenServer.reply(from, :eof)

      {:error, type} = error when type in [:epipe, :einval] ->
        GenServer.reply(from, error)
    end

    {:noreply, state}
  end

  def handle_cast({:close, from}, state) do
    GenServer.reply(from, :file.close(state.fifo))
    {:noreply, state}
  end
end
