defmodule ExCmd.Log do
  @moduledoc false

  require Logger

  @spec debug(String.t(), keyword) :: :ok
  def debug(msg, opts \\ []) do
    if Application.get_env(:ex_cmd, :enable_debug_logs) do
      Logger.debug(msg, opts)
    else
      :ok
    end
  end

  @spec error(String.t(), keyword) :: :ok
  def error(msg, opts \\ []) do
    Logger.error(msg, opts)
  end
end
