defmodule Mix.Tasks.Compile.Odu do
  @moduledoc false
  use Mix.Task.Compiler

  @recursive true
  @system_arch List.to_string(:erlang.system_info(:system_architecture))

  @impl Mix.Task.Compiler
  def run(_args) do
    {os, arch} = platform_from_env()

    case {os, arch} do
      {os, arch} when is_binary(os) and is_binary(arch) ->
        build_odu(executable_path({os, arch}), [{"GOOS", os}, {"GOARCH", arch}])

      {nil, nil} ->
        build_for_current_platform()
    end
  end

  def executable_name(platform \\ current_platform()) do
    case platform do
      {"windows", "amd64"} -> "odu_windows_amd64.exe"
      {"windows", "arm64"} -> "odu_windows_arm64.exe"
      {"linux", "amd64"} -> "odu_linux_amd64"
      {"linux", "arm64"} -> "odu_linux_arm64"
      {"darwin", "amd64"} -> "odu_darwin_amd64"
      {"darwin", "arm64"} -> "odu_darwin_arm64"
      # generic name for all other platform
      _ -> "odu"
    end
  end

  defp build_for_current_platform do
    platform = current_platform()

    cond do
      System.find_executable("go") ->
        build_odu(executable_path(platform), [])

      # check if pre-built binary exists for currect platform
      File.exists?(executable_path(platform)) ->
        :ok

      true ->
        compiler_error("""
        ExCmd does not ship with `odu` shim for your operating system and arch.
        Please install `go` to build shim for you.

           System Architecture: #{@system_arch}

        """)
    end
  end

  defp build_odu(executable_path, env) do
    result =
      System.cmd(
        "go",
        ~w/build -ldflags -w -o #{executable_path}/,
        cd: "go_src",
        stderr_to_stdout: true,
        env: env
      )

    case result do
      {_, 0} ->
        {:ok, []}

      {output, _exit_status} ->
        compiler_error(output)
    end
  end

  defp compiler_error(msg) do
    error = %Mix.Task.Compiler.Diagnostic{
      compiler_name: "odu",
      details: nil,
      file: __ENV__.file,
      message: msg,
      position: nil,
      severity: :error
    }

    Mix.shell().error(error.message)
    {:error, [error]}
  end

  defp executable_path(platform) do
    Path.absname("priv")
    |> Path.join(executable_name(platform))
  end

  defp current_platform do
    case current_target(:os.type()) do
      {:ok, {"x86_64", "linux", _}} ->
        {"linux", "amd64"}

      {:ok, {"aarch64", "linux", _}} ->
        {"linux", "arm64"}

      {:ok, {"x86_64", "apple", _}} ->
        {"darwin", "amd64"}

      {:ok, {"aarch64", "apple", _}} ->
        {"darwin", "arm64"}

      {:ok, {"x86_64", "windows", _}} ->
        {"windows", "amd64"}

      {:ok, {"aarch64", "windows", _}} ->
        {"windows", "arm64"}

      {:ok, {_, os_name, _}} ->
        {os_name, nil}
    end
  end

  defp platform_from_env do
    os = System.get_env("ODU_GOOS")
    arch = System.get_env("ODU_GOARCH")

    if os && arch do
      {os, arch}
    else
      {nil, nil}
    end
  end

  defp current_target({:win32, _}) do
    processor_architecture =
      String.downcase(String.trim(System.get_env("PROCESSOR_ARCHITECTURE")))

    compiler =
      case :erlang.system_info(:c_compiler_used) do
        {:msc, _} -> "msvc"
        {:gnuc, _} -> "gnu"
        {other, _} -> Atom.to_string(other)
      end

    # https://docs.microsoft.com/en-gb/windows/win32/winprog64/wow64-implementation-details?redirectedfrom=MSDN
    case processor_architecture do
      "amd64" ->
        {:ok, {"x86_64", "windows", compiler}}

      "ia64" ->
        {:ok, {"ia64", "windows", compiler}}

      "arm64" ->
        {:ok, {"aarch64", "windows", compiler}}

      "x86" ->
        {:ok, {"x86", "windows", compiler}}
    end
  end

  defp current_target({:unix, _}) do
    # get current target triplet from `:erlang.system_info/1`
    system_architecture = to_string(:erlang.system_info(:system_architecture))
    current = String.split(system_architecture, "-", trim: true)

    case length(current) do
      4 ->
        {:ok, {Enum.at(current, 0), Enum.at(current, 2), Enum.at(current, 3)}}

      3 ->
        case :os.type() do
          {:unix, :darwin} ->
            # could be something like aarch64-apple-darwin21.0.0
            # but we don't really need the last 21.0.0 part
            # credo:disable-for-next-line
            if String.match?(Enum.at(current, 2), ~r/^darwin.*/) do
              {:ok, {Enum.at(current, 0), Enum.at(current, 1), "darwin"}}
            else
              {:ok, system_architecture}
            end

          _ ->
            {:ok, system_architecture}
        end

      _ ->
        {:error, "cannot decide current target"}
    end
  end
end
