defmodule ExCmd.Process.Operations do
  @moduledoc false

  alias ExCmd.Process.Pipe
  alias ExCmd.Process.State

  @type t :: %__MODULE__{
          write_stdin: write_operation() | nil,
          read_stdout: read_operation() | nil,
          read_stderr: read_operation() | nil
        }

  defstruct [:write_stdin, :read_stdout, :read_stderr]

  @spec new :: t
  def new, do: %__MODULE__{}

  @type write_operation ::
          {:write_stdin, GenServer.from(), binary}
          | {:write_stdin, :demand, nil}

  @type read_operation ::
          {:read_stdout, GenServer.from(), non_neg_integer}
          | {:read_stderr, GenServer.from(), non_neg_integer}

  @type operation :: write_operation() | read_operation()

  @type name :: :write_stdin | :read_stdout | :read_stderr

  @spec get(t, name) :: {:ok, operation()} | {:error, term}
  def get(operations, name) do
    {:ok, Map.fetch!(operations, name)}
  end

  @spec pop(t, name) :: {:ok, operation, t} | {:error, term}
  def pop(operations, name) do
    case Map.get(operations, name) do
      nil ->
        {:error, :operation_not_found}

      operation ->
        {:ok, operation, Map.put(operations, name, nil)}
    end
  end

  @spec put(t, operation()) :: {:ok, t} | {:error, term}
  def put(operations, operation) do
    with {:ok, {op_name, _from, _arg} = operation} <- validate_operation(operation) do
      {:ok, Map.put(operations, op_name, operation)}
    end
  end

  @spec read(State.t(), read_operation()) ::
          :eof
          | {:noreply, State.t()}
          | {:ok, binary}
          | {:error, term}
  def read(state, operation) do
    with {:ok, {_name, {caller, _}, arg}} <- validate_read_operation(operation),
         {:ok, pipe} <- State.pipe(state, pipe_name(operation)),
         {:error, :eagain} <- Pipe.read(pipe, arg, caller),
         {:ok, new_state} <- State.put_operation(state, operation) do
      {:noreply, new_state}
    end
  end

  @spec write(State.t(), write_operation()) ::
          :ok
          | {:noreply, State.t()}
          | {:error, :epipe}
          | {:error, term}
  def write(state, operation) do
    with {:ok, {_name, {caller, _}, bin}} <- validate_write_operation(operation),
         pipe_name <- pipe_name(operation),
         {:ok, pipe} <- State.pipe(state, pipe_name),
         {:ok, remaining} <- Pipe.write(pipe, bin, caller) do
      handle_successful_write(state, remaining, operation)
    end
  end

  @spec demand_input(State.t()) ::
          {:noreply, State.t()}
          | {:error, term}
  def demand_input(state) do
    operation = {:write_stdin, :demand, nil}

    with {:ok, _} <- validate_write_operation(operation),
         {:ok, new_state} <- State.put_operation(state, operation) do
      {:noreply, new_state}
    end
  end

  @spec pending_input(State.t(), term, binary) ::
          {:noreply, State.t()}
          | {:error, term}
  def pending_input(state, from, bin) do
    operation = {:write_stdin, from, bin}

    with {:ok, _} <- validate_write_operation(operation),
         {:ok, new_state} <- State.put_operation(state, operation) do
      {:noreply, new_state}
    end
  end

  @spec pop_pending_callers(State.t()) :: {State.t(), [pid]}
  def pop_pending_callers(state) do
    operations = Map.from_struct(state.operations)

    {state, pending_callers} =
      Enum.reduce(operations, {state, []}, fn {name, _}, {state, ops} ->
        case State.pop_operation(state, name) do
          {:error, :operation_not_found} ->
            {state, ops}

          {:ok, {_, :demand, _}, state} ->
            {state, ops}

          {:ok, {_, {_pid, _} = caller, _}, state} ->
            {state, [caller | ops]}
        end
      end)

    {state, pending_callers}
  end

  @spec match_pending_operation(State.t(), Pipe.name()) ::
          {:ok, name} | {:error, :no_pending_operation}
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def match_pending_operation(state, pipe_name) do
    cond do
      state.operations.read_stdout &&
          pipe_name == :stdout ->
        {:ok, :read_stdout}

      state.operations.read_stderr &&
          pipe_name == :stderr ->
        {:ok, :read_stderr}

      state.operations.write_stdin &&
          pipe_name == :stdin ->
        {:ok, :write_stdin}

      true ->
        {:error, :no_pending_operation}
    end
  end

  @spec handle_successful_write(State.t(), binary, write_operation()) ::
          :ok | {:noreply, State.t()} | {:error, term}
  defp handle_successful_write(state, remaining, {name, from, _bin}) do
    # check if it is partial write
    if byte_size(remaining) > 0 do
      case State.put_operation(state, {name, from, remaining}) do
        {:ok, new_state} ->
          {:noreply, new_state}

        error ->
          error
      end
    else
      :ok
    end
  end

  @spec validate_read_operation(operation) ::
          {:ok, read_operation()} | {:error, :invalid_operation}
  defp validate_read_operation(operation) do
    case operation do
      {:read_stdout, _from, size} when is_integer(size) and size >= 0 and size <= 65_531 ->
        {:ok, operation}

      {:read_stderr, _from, size} when is_integer(size) and size >= 0 and size <= 65_531 ->
        {:ok, operation}

      _ ->
        {:error, :invalid_operation}
    end
  end

  @spec validate_write_operation(operation) ::
          {:ok, write_operation()} | {:error, :invalid_operation}
  defp validate_write_operation(operation) do
    case operation do
      {:write_stdin, _from, bin} when is_binary(bin) ->
        {:ok, operation}

      {:write_stdin, :demand, nil} ->
        {:ok, operation}

      _ ->
        {:error, :invalid_operation}
    end
  end

  @spec validate_operation(operation) :: {:ok, operation()} | {:error, :invalid_operation}
  defp validate_operation(operation) do
    with {:error, :invalid_operation} <- validate_read_operation(operation) do
      validate_write_operation(operation)
    end
  end

  @spec pipe_name(operation()) :: :stdin | :stdout | :stderr
  defp pipe_name({op, _from, _}) do
    case op do
      :write_stdin -> :stdin
      :read_stdout -> :stdout
      :read_stderr -> :stderr
    end
  end
end
