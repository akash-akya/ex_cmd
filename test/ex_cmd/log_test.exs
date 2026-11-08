defmodule ExCmd.LogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require ExCmd.Log

  setup do
    previous = Application.fetch_env(:ex_cmd, :enable_debug_logs)
    # test_helper sets the primary level to :warning. Since log calls carry
    # the caller's module metadata, a module level is enough to let them through
    :ok = Logger.put_module_level(__MODULE__, :debug)

    on_exit(fn ->
      Logger.delete_module_level(__MODULE__)

      case previous do
        {:ok, value} -> Application.put_env(:ex_cmd, :enable_debug_logs, value)
        :error -> Application.delete_env(:ex_cmd, :enable_debug_logs)
      end
    end)
  end

  test "debug message is not evaluated when debug logs are disabled" do
    Application.put_env(:ex_cmd, :enable_debug_logs, false)

    assert :ok = ExCmd.Log.debug(evaluate("disabled"))
    refute_received :evaluated
  end

  test "debug message is logged when debug logs are enabled" do
    Application.put_env(:ex_cmd, :enable_debug_logs, true)

    assert capture_log([level: :debug], fn ->
             ExCmd.Log.debug(evaluate("enabled-message"))
           end) =~ "enabled-message"

    assert_received :evaluated
  end

  defp evaluate(msg) do
    send(self(), :evaluated)
    msg
  end
end
