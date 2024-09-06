defmodule ExCmd.Process.Pipe do
  @moduledoc false

  alias ExCmd.Process.Proto

  @type name :: ExCmd.Process.pipe_name()

  @type fd :: non_neg_integer()

  @type t :: %__MODULE__{
          name: name,
          fd: pos_integer() | nil,
          monitor_ref: reference() | nil,
          owner: pid | nil,
          status: :open | :closed
        }

  defstruct [:name, :fd, :monitor_ref, :owner, status: :init]

  alias __MODULE__

  @spec new(name, pos_integer, pid) :: t
  def new(name, fd, owner) do
    if name in [:stdin, :stdout, :stderr] do
      ref = Process.monitor(owner)
      %Pipe{name: name, fd: fd, status: :open, owner: owner, monitor_ref: ref}
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
  def open?(pipe), do: pipe.status == :open

  @spec read(t, non_neg_integer, pid) :: :eof | {:ok, binary} | {:error, :eagain} | {:error, term}
  def read(pipe, size, caller) do
    if caller != pipe.owner do
      {:error, :pipe_closed_or_invalid_caller}
    else
      case Proto.read(pipe.fd, size) do
        # normalize return value
        {:ok, <<>>} -> :eof
        ret -> ret
      end
    end
  end

  @spec write(t, binary, pid) :: {:ok, remaining :: binary} | {:error, term}
  def write(pipe, bin, caller) do
    if caller != pipe.owner do
      {:error, :pipe_closed_or_invalid_caller}
    else
      Proto.write_input(pipe.fd, bin)
    end
  end

  @spec close(t, pid) :: {:ok, t} | {:error, :pipe_closed_or_invalid_caller}
  def close(pipe, caller) do
    if caller != pipe.owner do
      {:error, :pipe_closed_or_invalid_caller}
    else
      Process.demonitor(pipe.monitor_ref, [:flush])
      :ok = Proto.close(pipe.fd, pipe.name)
      pipe = %Pipe{pipe | status: :closed, monitor_ref: nil, owner: nil}

      {:ok, pipe}
    end
  end

  @spec set_owner(t, pid) :: {:ok, t} | {:error, :closed}
  def set_owner(pipe, new_owner) do
    if pipe.status == :open do
      ref = Process.monitor(new_owner)
      Process.demonitor(pipe.monitor_ref, [:flush])
      pipe = %Pipe{pipe | owner: new_owner, monitor_ref: ref}

      {:ok, pipe}
    else
      {:error, :closed}
    end
  end
end
