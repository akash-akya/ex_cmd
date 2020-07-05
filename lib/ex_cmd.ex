defmodule ExCmd do
  @moduledoc """
  ExCmd is an Elixir library to run and communicate with external programs with back-pressure.
  """

  @doc """
  Runs the given command with arguments and return an Enumerable to read command output.

  First parameter must be a list containing command with arguments. example: `["cat", "file.txt"]`.

  ### Options
    * `input`            - Input can be either an `Enumerable` or a function which accepts `Collectable`.
                           1. input as Enumerable:
                           ```elixir
                           # List
                           ExCmd.stream!(~w(bc -q), input: ["1+1\n", "2*2\n"]) |> Enum.to_list()

                           # Stream
                           ExCmd.stream!(~w(cat), input: File.stream!("log.txt", [], 65536)) |> Enum.to_list()
                           ```
                           2. input as collectable:
                           If the input in a function with arity 1, ex_cmd will call that function with a `Collectable` as the argument. The function must *push* input to this collectable. Return value of the function is ignored.
                           ```elixir
                           ExCmd.stream!(~w(cat), input: fn sink -> Enum.into(1..100, sink, &to_string/1) end)
                           |> Enum.to_list()
                           ```
                           By defaults no input will be given to the command
    * `exit_timeout`     - Duration to wait for external program to exit after completion before raising an error. Defaults to `:infinity`
    * `chunk_size`       - Size of each iodata chunk emitted by Enumerable stream. When set to `nil` the output is unbuffered and chunk size will be variable. Defaults to 65336
  All other options are passed to `ExCmd.Process.start_link/2`

  ### Example

  ``` elixir
  ExCmd.stream!(~w(ffmpeg -i pipe:0 -f mp3 pipe:1), input: File.stream!("music_video.mkv", [], 65336))
  |> Stream.into(File.stream!("music.mp3"))
  |> Stream.run()
  ```
  """
  def stream!(cmd_with_args, opts \\ []) do
    ExCmd.Stream.__build__(cmd_with_args, opts)
  end
end
