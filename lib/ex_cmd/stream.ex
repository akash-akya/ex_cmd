defmodule ExCmd.Stream do
  @moduledoc """
  Defines a `ExCmd.Stream` struct returned by `ExCmd.stream!/2`.
  """

  alias ExCmd.Process
  alias ExCmd.Process.Error

  defmodule AbnormalExit do
    defexception [:message, :exit_status]

    @impl true
    def exception(exit_status) do
      msg = "program exited with exit status: #{exit_status}"
      %__MODULE__{message: msg, exit_status: exit_status}
    end
  end

  defmodule Sink do
    @moduledoc false
    defstruct [:process]

    defimpl Collectable do
      def into(%{process: process} = stream) do
        collector_fun = fn
          :ok, {:cont, x} ->
            :ok = Process.write(process, x)

          :ok, :done ->
            :ok = Process.close_stdin(process)
            stream

          :ok, :halt ->
            :ok = Process.close_stdin(process)
        end

        {:ok, collector_fun}
      end
    end
  end

  defstruct [:process, :stream_opts]

  @type t :: %__MODULE__{}

  @doc false
  def __build__(cmd_with_args, opts) do
    {stream_opts, process_opts} = Keyword.split(opts, [:exit_timeout, :input])

    case normalize_stream_opts(stream_opts) do
      {:ok, stream_opts} ->
        {:ok, process} = Process.start_link(cmd_with_args, process_opts)

        start_input_streamer(%Sink{process: process}, stream_opts[:input])

        %ExCmd.Stream{
          process: process,
          stream_opts: stream_opts
        }

      {:error, error} ->
        raise ArgumentError, message: error
    end
  end

  @doc false
  defp start_input_streamer(sink, input) do
    case input do
      :no_input ->
        :ok

      {:enumerable, enum} ->
        spawn_link(fn ->
          Enum.into(enum, sink)
        end)

      {:collectable, func} ->
        spawn_link(fn ->
          func.(sink)
        end)
    end
  end

  defimpl Enumerable do
    def reduce(%{process: process, stream_opts: stream_opts}, acc, fun) do
      start_fun = fn -> :ok end

      next_fun = fn :ok ->
        case Process.read(process) do
          {:ok, x} ->
            {[x], :ok}

          :eof ->
            {:halt, :normal}

          error ->
            raise Error, "Failed to read data from the program. error: #{inspect(error)}"
        end
      end

      after_fun = fn exit_type ->
        try do
          # always close stdin before stopping to give the command chance to exit properly
          Process.close_stdin(process)

          if exit_type == :normal do
            result = Process.await_exit(process, stream_opts[:exit_timeout])

            case result do
              {:ok, 0} ->
                :ok

              {:ok, status} ->
                raise AbnormalExit, status

              :timeout ->
                raise Error, "program fail to exit within timeout: #{stream_opts.exit_timeout}"
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

  @spec normalize_input(term) ::
          {:ok, :no_input} | {:ok, {:enumerable, term}} | {:ok, {:collectable, function}}
  defp normalize_input(term) do
    cond do
      is_nil(term) ->
        {:ok, :no_input}

      is_binary(term) ->
        {:ok, {:enumerable, [IO.iodata_to_binary(term)]}}

      is_function(term, 1) ->
        {:ok, {:collectable, term}}

      Enumerable.impl_for(term) ->
        {:ok, {:enumerable, term}}

      true ->
        {:error, "`:input` must be either Enumerable or a function which accepts collectable"}
    end
  end

  defp normalize_exit_timeout(timeout) do
    case timeout do
      nil ->
        {:ok, :infinity}

      :infinity ->
        {:ok, :infinity}

      timeout when is_integer(timeout) and timeout > 0 ->
        {:ok, timeout}

      _ ->
        {:error, ":exit_timeout must be either :infinity or a non-zero integer"}
    end
  end

  defp normalize_stream_opts(opts) do
    with {:ok, input} <- normalize_input(opts[:input]),
         {:ok, exit_timeout} <- normalize_exit_timeout(opts[:exit_timeout]) do
      opts = %{
        input: input,
        exit_timeout: exit_timeout
      }

      {:ok, opts}
    end
  end
end
