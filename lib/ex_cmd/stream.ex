defmodule ExCmd.Stream do
  @moduledoc """
  Defines a `ExCmd.Stream` struct returned by `ExCmd.stream!/3`.
  """

  alias ExCmd.Process

  defmodule Sink do
    defstruct [:process]

    defimpl Collectable do
      def into(%{process: process} = stream) do
        case Process.open_input(process) do
          :ok -> :ok
          {:error, :unused_stream} -> raise "Can not use Collectable stream with :no_stdin option"
        end

        collector_fun = fn
          :ok, {:cont, x} ->
            :ok = Process.write(process, x)

          :ok, :done ->
            :ok = Process.close_input(process)
            stream

          :ok, :halt ->
            :ok = Process.close_input(process)
        end

        {:ok, collector_fun}
      end
    end
  end

  defstruct [:process, :stream_opts]

  @default_opts [exit_timeout: :infinity, chunk_size: 65535]

  @type t :: %__MODULE__{}

  @doc false
  def __build__(cmd_with_args, opts) do
    {stream_opts, process_opts} = Keyword.split(opts, [:exit_timeout, :chunk_size, :input])
    stream_opts = Keyword.merge(@default_opts, stream_opts)
    no_stdin = !stream_opts[:input]

    {:ok, process} =
      Process.start_link(cmd_with_args, Keyword.put(process_opts, :no_stdin, no_stdin))

    start_input_streamer(%Sink{process: process}, stream_opts[:input])
    %ExCmd.Stream{process: process, stream_opts: stream_opts}
  end

  @doc false
  defp start_input_streamer(sink, input) do
    cond do
      is_nil(input) ->
        :ok

      !is_function(input) && Enumerable.impl_for(input) ->
        spawn_link(fn ->
          Enum.into(input, sink)
        end)

      is_function(input, 1) ->
        spawn_link(fn ->
          input.(sink)
        end)

      true ->
        raise ArgumentError,
          message: ":input must be either Enumerable or a function with arity 1"
    end
  end

  defimpl Enumerable do
    def reduce(%{process: process, stream_opts: stream_opts}, acc, fun) do
      start_fun = fn ->
        :ok = Process.run(process)
        :ok = Process.open_output(process)
      end

      next_fun = fn :ok ->
        case Process.read(process) do
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
          Process.close_input(process)

          result = Process.await_exit(process, stream_opts[:exit_timeout])

          if exit_type == :normal_exit do
            case result do
              {:ok, 0} -> :ok
              {:ok, status} -> raise "command exited with status: #{status}"
              :timeout -> raise "command fail to exit within timeout: #{stream_opts.exit_timeout}"
            end
          end
        after
          Process.stop(process)
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
