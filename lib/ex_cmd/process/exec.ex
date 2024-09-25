defmodule ExCmd.Process.Exec do
  @moduledoc false

  @type args :: %{
          cmd_with_args: [String.t()],
          cd: String.t(),
          env: [{String.t(), String.t()}]
        }

  @spec normalize_exec_args(nonempty_list(), keyword()) ::
          {:ok,
           %{
             cmd_with_args: nonempty_list(),
             cd: charlist,
             env: env,
             stderr: :console | :redirect_to_stdout | :disable,
             log: nil | String.t()
           }}
          | {:error, String.t()}
  def normalize_exec_args(cmd_with_args, opts) do
    with {:ok, cmd} <- normalize_cmd(cmd_with_args),
         {:ok, args} <- normalize_cmd_args(cmd_with_args),
         :ok <- validate_opts_fields(opts),
         {:ok, cd} <- normalize_cd(opts[:cd]),
         {:ok, stderr} <- normalize_stderr(opts[:stderr]),
         {:ok, log} <- normalize_log(opts[:log]),
         {:ok, env} <- normalize_env(opts[:env]) do
      {:ok, %{cmd_with_args: [cmd | args], cd: cd, env: env, stderr: stderr, log: log}}
    end
  end

  @spec normalize_cmd(nonempty_list()) :: {:ok, nonempty_list()} | {:error, String.t()}
  defp normalize_cmd(arg) do
    case arg do
      [cmd | _] when is_binary(cmd) ->
        path = System.find_executable(cmd)

        if path do
          {:ok, to_charlist(path)}
        else
          {:error, "command not found: #{inspect(cmd)}"}
        end

      _ ->
        {:error, "`cmd_with_args` must be a list of strings, Please check the documentation"}
    end
  end

  defp normalize_cmd_args([_ | args]) do
    if Enum.all?(args, &is_binary/1) do
      {:ok, Enum.map(args, &to_charlist/1)}
    else
      {:error, "command arguments must be list of strings. #{inspect(args)}"}
    end
  end

  @spec normalize_cd(String.t()) :: {:ok, charlist()} | {:error, String.t()}
  defp normalize_cd(cd) do
    case cd do
      nil ->
        {:ok, ~c""}

      cd when is_binary(cd) ->
        if File.exists?(cd) && File.dir?(cd) do
          {:ok, to_charlist(cd)}
        else
          {:error, "`:cd` must be valid directory path"}
        end

      _ ->
        {:error, "`:cd` must be a binary string"}
    end
  end

  @type env :: [{String.t(), String.t()}]

  @spec normalize_env(env) :: {:ok, env} | {:error, String.t()}
  defp normalize_env(env) do
    case env do
      nil ->
        {:ok, []}

      env when is_list(env) or is_map(env) ->
        env =
          Enum.map(env, fn {key, value} ->
            {to_string(key), to_string(value)}
          end)

        {:ok, env}

      _ ->
        {:error, "`:env` must be a map or list of `{string, string}`"}
    end
  end

  @spec normalize_stderr(stderr :: :console | :redirect_to_stdout | :disable | nil) ::
          {:ok, :console | :redirect_to_stdout | :disable} | {:error, String.t()}
  defp normalize_stderr(stderr) do
    case stderr do
      nil ->
        {:ok, :console}

      stderr when stderr in [:console, :disable, :redirect_to_stdout] ->
        {:ok, stderr}

      _ ->
        {:error, ":stderr must be an atom and one of :redirect_to_stdout, :console, :disable"}
    end
  end

  @spec normalize_log(log :: nil | :stdout | :stderr | String.t()) ::
          {:ok, nil | String.t()} | {:error, String.t()}
  defp normalize_log(log) do
    case log do
      nil ->
        {:ok, nil}

      :stdout ->
        {:ok, "|1"}

      :stderr ->
        {:ok, "|2"}

      file when is_binary(file) ->
        {:ok, file}

      _ ->
        {:error, ":log must be an atom and one of nil, :stdout, :stderr, or path"}
    end
  end

  @spec validate_opts_fields(keyword) :: :ok | {:error, String.t()}
  defp validate_opts_fields(opts) do
    {_, additional_opts} = Keyword.split(opts, [:cd, :env, :stderr, :log])

    if Enum.empty?(additional_opts) do
      :ok
    else
      {:error, "invalid opts: #{inspect(additional_opts)}"}
    end
  end
end
