defmodule ExCmd do
  @moduledoc """
  ExCmd is an Elixir library to run and communicate with external
  programs with back-pressure.
  """

  @doc """
  Runs the given command with arguments and return an Enumerable to
  read command output.

  First parameter must be a list containing command with
  arguments. example: `["cat", "file.txt"]`.

  ### Optional

    * `input` - Input can be binary, iodata, `Enumerable` (list, stream)
       or a function which accepts `Collectable`.

      * Binary
        ```
        # binary
        ExCmd.stream!(~w(base64), input: "Hello Wolrd")
        ```

      * Enumerable or iodata

        ```
        # list
        ExCmd.stream!(~w(base64), input: ["hello", "world"])

        # iodata
        ExCmd.stream!(~w(cat), input: ["He", ["llo"], [' ', ?W], ['or', "ld"]])

        # stream
        ExCmd.stream!(~w(cat), input: File.stream!("log.txt", [], 65536))
        ```

      * Collectable:

        If the input in a function with arity 1, ExCmd will call that
        function with a `Collectable` as the argument. The function
        must *push* input to this collectable. Return value of the
        function is ignored.

        ```
        ExCmd.stream!(~w(cat), input: fn sink ->
          Enum.into(1..100, sink, &to_string/1)
        end)
        ```

    * `exit_timeout` - Time to wait for external program to exit.
      After writing all of the input we close the stdin stream and
      wait for external program to finish and exit. If program does
      not exit within `exit_timeout` an error will be raised and
      subsequently program will be killed in background. Defaults
      timeout is `:infinity`.

  All other options are passed to `ExCmd.Process.start_link/2`

  ## Examples

  ```
  ExCmd.stream!(~w(ffmpeg -i pipe:0 -f mp3 pipe:1), input: File.stream!("music_video.mkv", [], 65336))
  |> Stream.into(File.stream!("music.mp3"))
  |> Stream.run()
  ```

  With input as binary

  ```
  iex> ExCmd.stream!(~w(cat), input: "Hello World")
  ...> |> Enum.into("")
  "Hello World"
  ```

  ```
  iex> ExCmd.stream!(~w(base64), input: <<1, 2, 3, 4, 5>>)
  ...> |> Enum.into("")
  "AQIDBAU=\n"
  ```

  With input as list

  ```
  iex> ExCmd.stream!(~w(cat), input: ["Hello ", "World"])
  ...> |> Enum.into("")
  "Hello World"
  ```

  With input as iodata

  ```
  iex> ExCmd.stream!(~w(base64), input: [<<1, 2,>>, [3], [<<4, 5>>]])
  ...> |> Enum.into("")
  "AQIDBAU=\n"
  ```

  When program exit abnormally it will raise
  `ExCmd.Stream.AbnormalExit` error with exit_status.

  ```
  iex> try do
  ...>   ExCmd.stream!(["sh", "-c", "exit 5"]) |> Enum.to_list()
  ...> rescue
  ...>   e in ExCmd.Stream.AbnormalExit ->
  ...>    e.exit_status
  ...> end
  5
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
