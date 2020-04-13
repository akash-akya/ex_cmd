defmodule ExCmd.Stream do
  alias ExCmd.Process
  defstruct [:proc_server, :stream_opts]

  @default_stream_opts %{exit_timeout: :infinity}

  def __build__(cmd, args, opts) do
    {stream_opts, proc_opts} = Map.split(opts, [:exit_timeout])
    stream_opts = Map.merge(@default_stream_opts, stream_opts)

    {:ok, proc} = Process.start_link(cmd, args, proc_opts)
    %ExCmd.Stream{proc_server: proc, stream_opts: stream_opts}
  end

  defimpl Collectable do
    def into(%{proc_server: proc} = stream) do
      :ok = Process.open_input(proc)

      collector_fun = fn
        :ok, {:cont, x} ->
          :ok = Process.write(proc, x)

        :ok, :done ->
          :ok = Process.close_input(proc)
          stream

        :ok, :halt ->
          :ok = Process.close_input(proc)
      end

      {:ok, collector_fun}
    end
  end

  defimpl Enumerable do
    def reduce(%{proc_server: proc, stream_opts: stream_opts}, acc, fun) do
      start_fun = fn ->
        :ok = Process.run(proc)
        :ok = Process.open_output(proc)
      end

      next_fun = fn :ok ->
        case Process.read(proc) do
          {:ok, x} ->
            {[x], :ok}

          :eof ->
            {:halt, :normal}

          error ->
            raise error
        end
      end

      after_fun = fn exit_type ->
        try do
          # always close stdin before stoping to give the command chance to exit properly
          Process.close_input(proc)

          result = Process.await_exit(proc, stream_opts.exit_timeout)

          if exit_type == :normal_exit do
            case result do
              {:ok, 0} -> :ok
              {:ok, status} -> raise "command exited with status: #{status}"
              :timeout -> raise "command fail to exit within timeout: #{stream_opts.exit_timeout}"
            end
          end
        after
          Process.stop(proc)
        end
      end

      Stream.resource(start_fun, next_fun, after_fun).(acc, fun)
    end

    def count(_stream) do
      {:error, __MODULE__}
    end

    def member?(_stream, _term) do
      {:error, __MODULE__}
    end

    def slice(_stream) do
      {:error, __MODULE__}
    end
  end
end
