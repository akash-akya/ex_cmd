defmodule Mix.Tasks.Compile.Odu do
  @moduledoc false
  use Mix.Task.Compiler

  @recursive true
  @system_arch List.to_string(:erlang.system_info(:system_architecture))

  @impl Mix.Task.Compiler
  def run(args) do
    {opts, _, errors} = OptionParser.parse(args, switches: [os: :string, arch: :string])

    case {opts[:os], opts[:arch], errors} do
      {os, arch, []} when is_binary(os) and is_binary(arch) ->
        build_odu(executable_path({os, arch}), [{"GOOS", os}, {"GOARCH", arch}])

      {nil, nil, []} ->
        build_for_current_platform()

      _ ->
        compiler_error("""
        Invalid compile options. To build shim for different platform - pass `--os <string>` and `--arch <string>`
        options. Skip these options to build shim for current platform.
        """)
    end
  end

  def executable_name(platform \\ current_platform()) do
    case platform do
      {"windows", "amd64"} -> "odu_windows_amd64.exe"
      {"linux", "amd64"} -> "odu_linux_amd64"
      {"darwin", "amd64"} -> "odu_darwin_amd64"
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
        ~w/build -o #{executable_path}/,
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
    is_amd64 = String.starts_with?(@system_arch, "x86_64")

    case :os.type() do
      {:win32, _} ->
        # FIXME: determine architecture properly
        {"windows", "amd64"}

      {:unix, :linux} when is_amd64 ->
        {"linux", "amd64"}

      {:unix, :darwin} when is_amd64 ->
        {"darwin", "amd64"}

      {:unix, os_name} ->
        {to_string(os_name), nil}
    end
  end
end
