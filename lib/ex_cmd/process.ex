defmodule ExCmd.Process do
  @default %{use_stderr: false}

  def start_link(cmd, args, opts \\ %{}) do
    opts = Map.merge(@default, opts)
    ExCmd.ProcessServer.start_link(cmd, args, opts)
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
end
