defmodule ExCmd.Process do
  @moduledoc """
  Helper to interact with `ExCmd.ProcessServer`

  ## Overview
  Each `ExCmd.ProcessServer` process maps to an instance of port (and an OS process). Internally `ExCmd.ProcessServer` creates and manages separate processes for each of the IO streams (Stdin, Stdout, Stderr) and a port that maps to an OS process of `odu`. Blocking operations such as `read` and `write` only blocks that stream, not the `ExCmd.Process` itself. For example, a blocking read does *not* block a parallel write.

  `ExCmd.stream!` should be preferred over this. Use this only if you need more control over the life-cycle of IO streams and OS process.
  """

  @default [log: false, no_stderr: true]

  @doc """
  Starts `ExCmd.ProcessServer`

  Starts a process using `cmd_with_args` and with options `opts`. start_link does not start the external program. It should be started with `run` explicitly.

  `cmd_with_args` must be a list containing command with arguments. example: `["cat", "file.txt"]`.

  ### Options
    * `no_stderr`      -  Whether to allow reading from stderr. Note that setting `true` but not reading from stderr might block external program due to back-pressure. Defaults to `true`
    * `log`            -  When set to `true` odu outputs are logged. Defaults to `false`
  """
  def start_link(cmd_with_args, opts \\ []) do
    opts = Keyword.merge(@default, opts)
    ExCmd.ProcessServer.start_link(cmd_with_args, opts)
  end

  @doc """
  Opens the port and runs the program
  """
  def run(server), do: GenStateMachine.call(server, :run)

  @doc """
  Return bytes written by the program to output stream.

  This blocks until the programs write and flush the output
  """
  @spec read(pid, non_neg_integer | :infinity) ::
          {:ok, iodata} | :eof | {:error, String.t()} | :closed
  def read(server, timeout \\ :infinity) do
    GenStateMachine.call(server, :read, timeout)
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
    GenStateMachine.call(server, :read_error, timeout)
  catch
    :exit, {:normal, _} -> :closed
  end

  @doc """
  Writes iodata `data` to programs input streams

  This blocks when the fifo is full
  """
  @spec write(pid, iodata, non_neg_integer | :infinity) :: :ok | {:error, String.t()} | :closed
  def write(server, data, timeout \\ :infinity) do
    GenStateMachine.call(server, {:write, data}, timeout)
  catch
    :exit, {:normal, _} -> :closed
  end

  @doc """
  Closes input stream. Which signal EOF to the program
  """
  def close_stdin(server), do: GenStateMachine.call(server, :close_stdin)

  @doc """
  Kills the program
  """
  def stop(server), do: GenStateMachine.stop(server, :normal)

  @doc """
  Returns status of the process. It will be either of `:started`, `{:done, exit_status}`
  """
  def status(server), do: GenStateMachine.call(server, :status)

  @doc """
  Waits for the program to terminate.

  If the program terminates before timeout, it returns `{:ok, exit_status}` else returns `:timeout`
  """
  def await_exit(server, timeout \\ :infinity),
    do: GenStateMachine.call(server, {:await_exit, timeout})

  @doc """
  Returns [port_info](http://erlang.org/doc/man/erlang.html#port_info-1)
  """
  def port_info(server), do: GenStateMachine.call(server, :port_info)
end
