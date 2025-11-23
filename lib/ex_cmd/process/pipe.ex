defmodule ExCmd.Process.Pipe do
  @moduledoc false

  alias ExCmd.Process.Proto

  @type name :: ExCmd.Process.pipe_name()

  @type t :: %__MODULE__{
          name: name,
          port: port | nil,
          monitor_ref: reference() | nil,
          owner: pid | nil,
          status: :open | :closed | :eof
        }

  defstruct [:name, :port, :monitor_ref, :owner, status: :init]

  alias __MODULE__

  @spec new(name, port, pid) :: t
  def new(name, port, owner) do
    if name in [:stdin, :stdout, :stderr] do
      ref = Process.monitor(owner)
      %Pipe{name: name, port: port, status: :open, owner: owner, monitor_ref: ref}
    else
      raise "invalid pipe name"
    end
  end

  @spec new(name) :: t
  def new(name) do
    if name in [:stdin, :stdout, :stderr] do
      %Pipe{name: name, status: :closed}
    else
      raise "invalid pipe name"
    end
  end

  @spec open?(t) :: boolean()
  def open?(pipe), do: pipe.status in [:open, :eof]

  @spec read(t, non_neg_integer, pid) :: :eof | {:error, :eagain} | {:error, term}
  def read(pipe, size, caller) do
    cond do
      caller != pipe.owner ->
        {:error, :pipe_closed_or_invalid_caller}

      pipe.status == :eof ->
        :eof

      true ->
        {:error, :eagain} = Proto.read(pipe.port, size)
    end
  end

  @spec write(t, binary, pid) :: {:ok, remaining :: binary} | {:error, term}
  def write(pipe, bin, caller) do
    if caller != pipe.owner do
      {:error, :pipe_closed_or_invalid_caller}
    else
      Proto.write_input(pipe.port, bin)
    end
  end

  @spec close(t, pid) :: {:ok, t} | {:error, :pipe_closed_or_invalid_caller}
  def close(%Pipe{} = pipe, caller) do
    cond do
      caller != pipe.owner ->
        {:error, :pipe_closed_or_invalid_caller}

      pipe.status in [:closed, :eof] ->
        # Already closed/eof - skip protocol command
        if pipe.monitor_ref do
          Process.demonitor(pipe.monitor_ref, [:flush])
        end

        pipe = %Pipe{pipe | status: :closed, monitor_ref: nil, owner: nil}
        {:ok, pipe}

      true ->
        Process.demonitor(pipe.monitor_ref, [:flush])
        :ok = Proto.close(pipe.port, pipe.name)
        pipe = %Pipe{pipe | status: :closed, monitor_ref: nil, owner: nil}
        {:ok, pipe}
    end
  end

  @spec set_owner(t, pid) :: {:ok, t} | {:error, :closed}
  def set_owner(%Pipe{} = pipe, new_owner) do
    if open?(pipe) do
      ref = Process.monitor(new_owner)
      Process.demonitor(pipe.monitor_ref, [:flush])
      pipe = %Pipe{pipe | owner: new_owner, monitor_ref: ref}

      {:ok, pipe}
    else
      {:error, :closed}
    end
  end

  @doc """
  Mark pipe as EOF when remote side closes.

  Only used for stdout/stderr. `:eof` means remote closed,
  `:closed` means we explicitly closed.
  """
  @spec mark_eof(t) :: {:ok, t}
  def mark_eof(%Pipe{} = pipe) do
    pipe = %Pipe{pipe | status: :eof}
    {:ok, pipe}
  end
end
