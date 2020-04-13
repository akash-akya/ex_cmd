defmodule ExCmd do
  @moduledoc """
  ExCmd is an Elixir library to run and communicate with external programs with back-pressure.
  """

  @default_opts %{exit_timeout: :infinity}

  @doc """
  Returns a `ExCmd.Stream` for the given `cmd` with arguments `args`.

  The stream implements both `Enumerable` and `Collectable` protocols,
  which means it can be used both for reading from stdout and write to
  stdin of an OS process simultaneously (see examples).

  ### Options
    * `exit_timeout`     - Duration to wait for external program to terminate after completion before raising an error. Defaults to `:infinity`
  All other options are passed to `ExCmd.Process.start_link/3`

  Since reading and writing are blocking actions, these should be done
  in separate processes (unless you know each input producess an
  output)

  ### Examples

  ``` elixir
  def audio_stream!(stream) do
    # read from stdin and write to stdout
    proc_stream = ExCmd.stream!("ffmpeg", ~w(-i - -f mp3 -))

    Task.async(fn ->
      Stream.into(stream, proc_stream)
      |> Stream.run()
    end)

    proc_stream
  end

  File.stream!("music_video.mkv", [], 65535)
  |> audio_stream!()
  |> Stream.into(File.stream!("music.mp3"))
  |> Stream.run()
  ```
  """
  def stream!(cmd, args \\ [], opts \\ %{}) do
    opts = Map.merge(opts, @default_opts)
    ExCmd.Stream.__build__(cmd, args, opts)
  end
end
