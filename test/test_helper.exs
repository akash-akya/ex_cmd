:ok =
  Application.put_env(
    :ex_cmd,
    :current_os,
    case :os.type() do
      {:win32, :nt} -> :windows
      {:unix, _} -> :unix
    end
  )

Logger.configure(level: :warning)
ExUnit.start(capture_log: false)
