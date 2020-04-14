defmodule ExCmd.Process do
  @moduledoc """
  Helper to interact with `ExCmd.ProcessServer`

  ## Overview
  Each `ExCmd.ProcessServer` process maps to an instance of port (and
  an OS process). Internally `ExCmd.ProcessServer` creates and manages
  separate processes for each of the IO streams (Stdin, Stdout,
  Stderr) and a port that maps to an OS process of `odu`. Blocking
  functions such as `read` and `write` only blocks the calling
  process, not the `ExCmd.Process` itself. A blocking read does
  *not* block a parallel write. Blocking calls are the primitives for
  building back-pressure.

  For most of the use-cases using `ExCmd.stream!` abstraction should
  be enough. Use this only if you need more control over the
  life-cycle of IO streams and OS process.
  """

  @default %{log: false, use_stderr: false}

  @doc """
  Starts `ExCmd.ProcessServer`

  Starts a process for running `cmd` with arguments `args` with options `opts`. Note that this does not run the program immediately. User has to explicitly run by calling `run/1`, `open_input/1`, `open_output/1` depending on the program.

  ### Options
    * `use_stderr`     -  Whether to allow reading from stderr. Note that setting `true` but not reading from stderr might block external program due to back-pressure. Defaults to `false`
    * `log`            -  When set to `true` odu outputs are logged. Defaults to `false`
  """
  def start_link(cmd, args, opts \\ %{}) do
    opts = Map.merge(@default, opts)
    ExCmd.ProcessServer.start_link(cmd, args, opts)
  end

  @doc """
  Opens the port and runs the program
  """
  def run(server), do: GenServer.call(server, :run)

  @doc """
  Opens the input stream of the program for writing. Blocks till reader opens
  """
  def open_input(server), do: GenServer.call(server, {:open_fifo, :input, :write})

  @doc """
  Opens the output stream of the program for reading. Blocks till writer opens
  """
  def open_output(server), do: GenServer.call(server, {:open_fifo, :output, :read})

  @doc """
  Opens the error stream of the program for reading. Blocks till writer opens
  """
  def open_error(server), do: GenServer.call(server, {:open_fifo, :error, :read})

  @doc """
  Return bytes written by the program to output stream.

  This blocks until the programs write and flush the output
  """
  @spec read(pid, non_neg_integer | :infinity) ::
          {:ok, iodata} | :eof | {:error, String.t()} | :closed
  def read(server, timeout \\ :infinity) do
    GenServer.call(server, :read, timeout)
  catch
    :exit, {:normal, _} -> :closed
  end

  @doc """
  Return bytes written by the program to error stream.

  This blocks until the programs write and flush the output
  """
  @spec read_error(pid, non_neg_integer | :infinity) ::
          {:ok, iodata} | :eof | {:error, String.t()} | :closed
  def read_error(server, timeout \\ :infinity) do
    GenServer.call(server, :read_error, timeout)
  catch
    :exit, {:normal, _} -> :closed
  end

  @doc """
  Writes iodata `data` to programs input streams

  This blocks when the fifo is full
  """
  @spec write(pid, iodata, non_neg_integer | :infinity) :: :ok | {:error, String.t()} | :closed
  def write(server, data, timeout \\ :infinity) do
    GenServer.call(server, {:write, data}, timeout)
  catch
    :exit, {:normal, _} -> :closed
  end

  @doc """
  Closes input stream. Which signal EOF to the program
  """
  def close_input(server), do: GenServer.call(server, :close_input)

  @doc """
  Kills the program
  """
  def stop(server), do: GenServer.stop(server, :normal)

  @doc """
  Returns status of the process. It will be either of `:started`, `{:done, exit_status}`
  """
  def status(server), do: GenServer.call(server, :status)

  @doc """
  Waits for the program to terminate.

  If the program terminates before timeout, it returns `{:ok, exit_status}` else returns `:timeout`
  """
  def await_exit(server, timeout \\ :infinity), do: GenServer.call(server, {:await_exit, timeout})

  @doc """
  Returns [port_info](http://erlang.org/doc/man/erlang.html#port_info-1)
  """
  def port_info(server), do: GenServer.call(server, :port_info)
end
