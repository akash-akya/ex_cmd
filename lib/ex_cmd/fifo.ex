defmodule ExCmd.FIFO do
  @doc false
  use GenServer
  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def open(server, dst), do: GenServer.cast(server, {:open, dst})

  def write(server, data, dst), do: GenServer.cast(server, {:write, data, dst})

  def read(server, dst), do: GenServer.cast(server, {:read, dst})

  def init(args) do
    {:ok, %{path: args.path, mode: args.mode}}
  end

  def handle_cast({:open, dst}, state) do
    fifo = File.open!(state.path, [:binary, :raw, state.mode])
    GenServer.reply(dst, :ok)
    {:noreply, Map.put(state, :fifo, fifo)}
  end

  def handle_cast({:write, data, dst}, %{mode: :write} = state) do
    data = [<<byte_size(data)::16>>, data]

    case :file.write(state.fifo, data) do
      :ok ->
        GenServer.reply(dst, :ok)

      {:error, type} = error when type in [:epipe, :einval] ->
        GenServer.reply(dst, error)
    end

    {:noreply, state}
  end

  def handle_cast({:read, dst}, %{mode: :read} = state) do
    case :file.read(state.fifo, 2) do
      {:ok, <<len::16-integer-big-unsigned>>} ->
        {:ok, data} = :file.read(state.fifo, len)
        GenServer.reply(dst, {:ok, data})

      :eof ->
        GenServer.reply(dst, :eof)

      {:error, type} = error when type in [:epipe, :einval] ->
        GenServer.reply(dst, error)
    end

    {:noreply, state}
  end

  def create(path) do
    mkfifo = :os.find_executable('mkfifo')

    if !mkfifo do
      raise "Can not create named fifo, mkfifo command not found"
    end

    {"", 0} = System.cmd("mkfifo", [path])
    :ok
  end
end
