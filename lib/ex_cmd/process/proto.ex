defmodule ExCmd.Process.Proto do
  require Logger

  @doc false
  defmacro send_input, do: 1

  @doc false
  defmacro send_output, do: 2

  @doc false
  defmacro output, do: 3

  @doc false
  defmacro input, do: 4

  @doc false
  defmacro close_input, do: 5

  @doc false
  defmacro output_eof, do: 6

  @doc false
  defmacro command_env, do: 7

  @doc false
  defmacro os_pid, do: 8

  @doc false
  defmacro start_error, do: 9

  @doc false
  defmacro close_output, do: 10

  @doc false
  defmacro kill, do: 11

  @doc false
  defmacro exit_status, do: 12

  def parse_command(command) do
    <<tag::unsigned-integer-8, bin::binary>> = command

    case tag do
      output_eof() ->
        {:output_eof, bin}

      output() ->
        {:output, bin}

      send_input() ->
        {:send_input, bin}

      exit_status() ->
        <<exit_status::big-signed-integer-32>> = bin
        {:exit_status, exit_status}
    end
  end

  def read(port, max_size) when is_integer(max_size) and max_size > 0 and max_size <= 65_536 do
    send_command(send_output(), <<max_size::big-signed-integer-32>>, port)
    {:error, :eagain}
  end

  def send_env(nil, port), do: send_env([], port)

  def send_env(env, port) do
    payload =
      Enum.map_join(env, fn {key, value} ->
        entry = String.trim(key) <> "=" <> String.trim(value)

        if byte_size(entry) > 65_531 do
          raise ArgumentError, message: "Env entry length exceeds limit"
        end

        <<byte_size(entry)::big-unsigned-integer-16, entry::binary>>
      end)

    send_command(command_env(), payload, port)
  end

  # 4 byte length prefix + 1 byte tag
  @max_chunk_size 64 * 1024 - 5

  def write_input(port, bin) do
    {chunk, bin} = binary_split_at(bin, @max_chunk_size)
    send_command(input(), chunk, port)
    {:ok, bin}
  end

  def close(port, :stdin) when is_port(port) do
    send_command(close_input(), <<>>, port)
  end

  def close(port, :stdout) when is_port(port) do
    send_command(close_output(), <<>>, port)
  end

  def close(port, stream) when is_port(port) do
    Logger.debug("Closing stream: #{stream}")
    :ok
  end

  def kill(port) do
    send_command(kill(), <<>>, port)
  end

  def start(cmd_with_args, env, odu_opts) do
    port = start_odu_port(odu_path(), cmd_with_args, odu_opts)
    send_env(env, port)

    os_pid =
      receive do
        {^port, {:data, <<os_pid()::unsigned-integer-8, os_pid::big-unsigned-integer-32>>}} ->
          Logger.debug("Command started. os pid: #{os_pid}")
          os_pid

        {^port, {:data, <<start_error()::unsigned-integer-8, reason::binary>>}} ->
          Logger.error("Failed to start odu. reason: #{reason}")
          raise ArgumentError, message: "Failed to start odu"
      after
        5_000 ->
          raise ArgumentError, message: "Failed to start command"
      end

    {os_pid, port}
  end

  defp send_command(tag, bin, port) do
    bin = <<tag::unsigned-integer-8, bin::binary>>

    try do
      true = Port.command(port, bin)
      :ok
    rescue
      # this is needed because the port might have already been closed
      # when we try to close
      error in [ArgumentError] ->
        if Port.info(port) == nil do
          :ok
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  defp binary_split_at(bin, pos) when byte_size(bin) <= pos, do: {bin, <<>>}

  defp binary_split_at(bin, pos) do
    len = byte_size(bin)
    {binary_part(bin, 0, pos), binary_part(bin, pos, len - pos)}
  end

  defp start_odu_port(odu_path, cmd_with_args, opts) do
    args = build_odu_params(opts) ++ ["--" | cmd_with_args]
    options = [:use_stdio, :exit_status, :binary, :hide, {:packet, 4}, args: args]
    Port.open({:spawn_executable, odu_path}, options)
  end

  @odu_protocol_version "1.0"
  defp build_odu_params(opts) do
    cd = Path.expand(opts[:cd] || File.cwd!())

    if !File.exists?(cd) || !File.dir?(cd) do
      raise ArgumentError, message: ":cd is not a valid path"
    end

    params = [
      "-cd",
      cd,
      "-stderr",
      to_string(opts[:stderr]),
      "-protocol_version",
      @odu_protocol_version
    ]

    if opts[:log] do
      params ++ ["-log", opts[:log]]
    else
      params
    end
  end

  defp odu_path do
    path =
      Application.app_dir(:ex_cmd, "priv")
      |> Path.join(Mix.Tasks.Compile.Odu.executable_name())

    if !File.exists?(path) do
      raise ArgumentError, message: "'odu' executable not found"
    end

    path
  end
end
