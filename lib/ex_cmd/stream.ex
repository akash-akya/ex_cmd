defmodule ExCmd.Stream do
  @moduledoc """
  Defines a `ExCmd.Stream` struct returned by `ExCmd.stream!/2`.
  """

  alias ExCmd.Process
  alias ExCmd.Process.Error

  require Logger

  defmodule AbnormalExit do
    defexception [:message, :exit_status]

    @impl true
    def exception(:epipe) do
      msg = "program exited due to :epipe error"
      %__MODULE__{message: msg, exit_status: :epipe}
    end

    def exception(exit_status) do
      msg = "program exited with exit status: #{exit_status}"
      %__MODULE__{message: msg, exit_status: exit_status}
    end
  end

  defmodule Sink do
    @moduledoc false

    @type t :: %__MODULE__{process: Process.t()}

    defstruct [:process]

    defimpl Collectable do
      def into(%{process: process}) do
        collector_fun = fn
          :ok, {:cont, x} ->
            case Process.write(process, x) do
              {:error, :epipe} ->
                # there is no other way to stop a Collectable than to
                # raise error, we catch this error and return `{:error, :epipe}`
                raise Error, "epipe"

              :ok ->
                :ok
            end

          acc, :done ->
            acc

          acc, :halt ->
            acc
        end

        {:ok, collector_fun}
      end
    end
  end

  defstruct [:stream_opts, :process_opts, :cmd_with_args]

  @typedoc "Struct members are private, do not depend on them"
  @type t :: %__MODULE__{
          stream_opts: map(),
          process_opts: keyword(),
          cmd_with_args: [String.t()]
        }

  @stream_opts [
    :exit_timeout,
    :max_chunk_size,
    :input,
    :stderr,
    :ignore_epipe,
    :stream_exit_status
  ]

  @doc false
  @spec __build__(nonempty_list(String.t()), keyword()) :: t()
  def __build__(cmd_with_args, opts) do
    {stream_opts, process_opts} = Keyword.split(opts, @stream_opts)

    case normalize_stream_opts(stream_opts) do
      {:ok, stream_opts} ->
        %ExCmd.Stream{
          stream_opts: stream_opts,
          process_opts: process_opts,
          cmd_with_args: cmd_with_args
        }

      {:error, error} ->
        raise ArgumentError, message: error
    end
  end

  defimpl Enumerable do
    defmodule State do
      @moduledoc false
      @enforce_keys [:process, :writer_task]
      defstruct [
        :process,
        :writer_task,
        :max_chunk_size,
        :exit_timeout,
        :ignore_epipe,
        :stream_exit_status,
        process_status: :running
      ]
    end

    def reduce(arg, acc, fun) do
      start_fun = fn -> start_process(arg) end
      next_fun = &read_next/1
      after_fun = &cleanup/1

      Stream.resource(start_fun, next_fun, after_fun).(acc, fun)
    end

    defp read_next(%State{process_status: :running} = state) do
      case Process.read(state.process, state.max_chunk_size) do
        {:ok, data} ->
          {[IO.iodata_to_binary(data)], state}

        :eof ->
          state = stop_process(state)

          if state.stream_exit_status do
            {[state.process_status], state}
          else
            {:halt, state}
          end

        {:error, errno} ->
          raise Error, "failed to read from the external process. errno: #{inspect(errno)}"
      end
    end

    defp read_next(%State{} = state), do: {:halt, state}

    defp cleanup(state) do
      state = stop_process(state)
      raise_on_abnormal_exit(state)
    end

    defp raise_on_abnormal_exit(%State{stream_exit_status: true}), do: :ok

    defp raise_on_abnormal_exit(%State{process_status: status}) do
      case status do
        {:exit, {:status, 0}} -> :ok
        {:exit, {:status, code}} -> raise AbnormalExit, code
        {:error, reason} -> raise AbnormalExit, reason
      end
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

    defp start_process(%ExCmd.Stream{} = stream) do
      opts = stream.stream_opts

      process_opts = Keyword.put(stream.process_opts, :stderr, opts.stderr)
      {:ok, process} = Process.start_link(stream.cmd_with_args, process_opts)

      sink = %Sink{process: process}
      writer_task = start_input_streamer(sink, opts.input)

      %State{
        process: process,
        writer_task: writer_task,
        max_chunk_size: opts.max_chunk_size,
        exit_timeout: opts.exit_timeout,
        ignore_epipe: opts.ignore_epipe,
        stream_exit_status: opts.stream_exit_status
      }
    end

    defp start_input_streamer(%Sink{process: process} = sink, input) do
      case input do
        :no_input ->
          Task.async(fn -> :ok end)

        {:enumerable, enum} ->
          stream_to_sink(process, fn -> Enum.into(enum, sink) end)

        {:collectable, func} ->
          stream_to_sink(process, fn -> func.(sink) end)
      end
    end

    defp stream_to_sink(process, write_fn) do
      Task.async(fn ->
        Process.change_pipe_owner(process, :stdin, self())

        try do
          write_fn.()
        rescue
          Error -> {:error, :epipe}
        end
      end)
    end

    defp stop_process(state) do
      status =
        case await_exit(state) do
          {:exit, term} ->
            {:exit, term}

          {:error, reason} ->
            if state.ignore_epipe do
              {:exit, {:status, 0}}
            else
              {:error, reason}
            end
        end

      %{state | process_status: status}
    end

    @spec await_exit(map) :: {:exit, {:status, non_neg_integer}} | {:error, atom}
    defp await_exit(%{process_status: :running} = state) do
      process_result = Process.await_exit(state.process, state.exit_timeout)
      writer_task_status = Task.await(state.writer_task)

      case {process_result, writer_task_status} do
        {_process_exit_status, {:error, :epipe}} ->
          {:error, :epipe}

        {{:ok, status}, :ok} ->
          {:exit, {:status, status}}

        {{:error, reason}, _writer_status} ->
          {:error, reason}
      end
    end

    defp await_exit(%{process_status: status}), do: status
  end

  @spec normalize_input(term) ::
          {:ok, :no_input} | {:ok, {:enumerable, term}} | {:ok, {:collectable, function}}
  defp normalize_input(term) do
    cond do
      is_nil(term) ->
        {:ok, :no_input}

      !is_function(term, 1) && Enumerable.impl_for(term) ->
        {:ok, {:enumerable, term}}

      is_function(term, 1) ->
        {:ok, {:collectable, term}}

      is_binary(term) ->
        {:ok, {:enumerable, [term]}}

      true ->
        {:error,
         ":input must be a string, an Enumerable, or a function that accepts a Collectable."}
    end
  end

  defp normalize_max_chunk_size(max_chunk_size) do
    case max_chunk_size do
      nil ->
        {:ok, 65_531}

      max_chunk_size when is_integer(max_chunk_size) and max_chunk_size > 0 ->
        {:ok, max_chunk_size}

      _ ->
        {:error, ":max_chunk_size must be a positive integer"}
    end
  end

  defp normalize_exit_timeout(timeout) do
    case timeout do
      nil ->
        {:ok, 5000}

      timeout when is_integer(timeout) and timeout > 0 ->
        {:ok, timeout}

      _ ->
        {:error, ":exit_timeout must be either :infinity or an integer"}
    end
  end

  defp normalize_stderr(stderr) do
    case stderr do
      nil ->
        {:ok, :disable}

      stderr when stderr in [:console, :redirect_to_stdout, :disable] ->
        {:ok, stderr}

      _ ->
        {:error, ":stderr must be an atom and one of :console, :redirect_to_stdout, :disable"}
    end
  end

  defp normalize_ignore_epipe(ignore_epipe) do
    case ignore_epipe do
      nil ->
        {:ok, false}

      ignore_epipe when is_boolean(ignore_epipe) ->
        {:ok, ignore_epipe}

      _ ->
        {:error, ":ignore_epipe must be a boolean"}
    end
  end

  defp normalize_stream_exit_status(stream_exit_status) do
    case stream_exit_status do
      nil ->
        {:ok, false}

      stream_exit_status when is_boolean(stream_exit_status) ->
        {:ok, stream_exit_status}

      _ ->
        {:error, ":stream_exit_status must be a boolean"}
    end
  end

  defp normalize_stream_opts(opts) do
    with {:ok, input} <- normalize_input(opts[:input]),
         {:ok, exit_timeout} <- normalize_exit_timeout(opts[:exit_timeout]),
         {:ok, max_chunk_size} <- normalize_max_chunk_size(opts[:max_chunk_size]),
         {:ok, stderr} <- normalize_stderr(opts[:stderr]),
         {:ok, ignore_epipe} <- normalize_ignore_epipe(opts[:ignore_epipe]),
         {:ok, stream_exit_status} <- normalize_stream_exit_status(opts[:stream_exit_status]) do
      {:ok,
       %{
         input: input,
         exit_timeout: exit_timeout,
         max_chunk_size: max_chunk_size,
         stderr: stderr,
         ignore_epipe: ignore_epipe,
         stream_exit_status: stream_exit_status
       }}
    end
  end
end
