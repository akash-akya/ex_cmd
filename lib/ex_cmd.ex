defmodule ExCmd do
  @moduledoc """
  ExCmd is an Elixir library to run and communicate with external programs with back-pressure.
  """

  @doc """
  Runs the given command with arguments and return an Enumerable to read command output.

  First parameter must be a list containing command with arguments. example: `["cat", "file.txt"]`.

  ### Options

    * `input` - Input can be either an `Enumerable` or a function which accepts `Collectable`.

      * Enumerable:

        ```
        # list
        ExCmd.stream!(~w(base64), input: ["hello", "world"]) |> Enum.to_list()
        # stream
        ExCmd.stream!(~w(cat), input: File.stream!("log.txt", [], 65536)) |> Enum.to_list()
        ```

      * Collectable:

        If the input in a function with arity 1, ExCmd will call that function with a `Collectable` as the argument. The function must *push* input to this collectable. Return value of the function is ignored.

        ```
        ExCmd.stream!(~w(cat), input: fn sink -> Enum.into(1..100, sink, &to_string/1) end)
        |> Enum.to_list()
        ```

      By defaults no input is given

    * `exit_timeout` - Duration to wait for external program to exit after completion before raising an error. Defaults to `:infinity`

  All other options are passed to `ExCmd.Process.start_link/2`

  ### Example

  ```
  ExCmd.stream!(~w(ffmpeg -i pipe:0 -f mp3 pipe:1), input: File.stream!("music_video.mkv", [], 65336))
  |> Stream.into(File.stream!("music.mp3"))
  |> Stream.run()
  ```
  """
  @type collectable_func() :: (Collectable.t() -> any())

  @spec stream!(nonempty_list(String.t()),
          input: Enum.t() | collectable_func(),
          exit_timeout: timeout(),
          cd: String.t(),
          env: [{String.t(), String.t()}],
          log: boolean()
        ) :: ExCmd.Stream.t()
  def stream!(cmd_with_args, opts \\ []) do
    ExCmd.Stream.__build__(cmd_with_args, opts)
  end
end
