defmodule ExCmd.Log do
  @moduledoc false

  # These are macros, like `Logger.debug/2` & co., so that the message is
  # evaluated only when it is actually going to be logged. Otherwise
  # expensive messages such as `inspect(state)` are built on every call
  # even when debug logging is disabled.
  #
  # Expanding to `Logger` macros at the call-site also keeps the logger
  # metadata (module, function, line) pointing to the caller instead of
  # this module.

  defmacro debug(msg, metadata \\ []) do
    quote do
      if Application.get_env(:ex_cmd, :enable_debug_logs) do
        require Logger
        Logger.debug(unquote(msg), unquote(metadata))
      else
        :ok
      end
    end
  end

  defmacro error(msg, metadata \\ []) do
    quote do
      require Logger
      Logger.error(unquote(msg), unquote(metadata))
    end
  end
end
