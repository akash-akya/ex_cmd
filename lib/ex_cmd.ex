defmodule ExCmd do
  @moduledoc ~S"""
  ExCmd is an alternative for beam [ports](https://hexdocs.pm/elixir/Port.html)
  with back-pressure and non-blocking IO.

  ### Quick Start

  Run a command and read from stdout

  ```
  iex> ExCmd.stream!(~w(echo Hello))
  ...> |> Enum.into("") # collect as string
  "Hello\n"
  ```

  Run a command with list of strings as input

  ```
  iex> ExCmd.stream!(~w(cat), input: ["Hello", " ", "World"])
  ...> |> Enum.into("") # collect as string
  "Hello World"
  ```

  Run a command with input as Stream

  ```
  iex> input_stream = Stream.map(1..10, fn num -> "#{num} " end)
  iex> ExCmd.stream!(~w(cat), input: input_stream)
  ...> |> Enum.into("")
  "1 2 3 4 5 6 7 8 9 10 "
  ```

  Run a command with input as infinite stream

  ```
  # create infinite stream
  iex> input_stream = Stream.repeatedly(fn -> "A" end)
  iex> binary =
  ...>   ExCmd.stream!(~w(cat), input: input_stream, ignore_epipe: true) # we need to ignore epipe since we are terminating the program before the input completes
  ...>   |> Stream.take(2) # we must limit since the input stream is infinite
  ...>   |> Enum.into("")
  iex> is_binary(binary)
  true
  iex> "AA" <> _ = binary # we might get more than 2 "A" due to buffering
  ```

  Run a command with input Collectable

  ```
  # ExCmd calls the callback with a sink where the process can push the data
  iex> ExCmd.stream!(~w(cat), input: fn sink ->
  ...>   Stream.map(1..10, fn num -> "#{num} " end)
  ...>   |> Stream.into(sink) # push to the external process
  ...>   |> Stream.run()
  ...> end)
  ...> |> Stream.take(100) # we must limit since the input stream is infinite
  ...> |> Enum.into("")
  "1 2 3 4 5 6 7 8 9 10 "
  ```

  When the command wait for the input stream to close

  ```
  # base64 command wait for the input to close and writes data to stdout at once
  iex> ExCmd.stream!(~w(base64), input: ["abcdef"])
  ...> |> Enum.into("")
  "YWJjZGVm\n"
  ```

  `stream!/2` raises non-zero exit as error

  ```
  iex> ExCmd.stream!(["sh", "-c", "echo 'foo' && exit 10"])
  ...> |> Enum.to_list()
  ** (ExCmd.Stream.AbnormalExit) program exited with exit status: 10
  ```

  `stream/2` variant returns exit status as last element

  ```
  iex> ExCmd.stream(["sh", "-c", "echo 'foo' && exit 10"])
  ...> |> Enum.to_list()
  [
    "foo\n",
    {:exit, {:status, 10}} # returns exit status of the program as last element
  ]
  ```

  You can fetch exit_status from the error for `stream!/2`

  ```
  iex> try do
  ...>   ExCmd.stream!(["sh", "-c", "exit 10"])
  ...>   |> Enum.to_list()
  ...> rescue
  ...>   e in ExCmd.Stream.AbnormalExit ->
  ...>     e.exit_status
  ...> end
  10
  ```

  With `max_chunk_size` set

  ```
  iex> data =
  ...>   ExCmd.stream!(~w(cat /dev/urandom), max_chunk_size: 100, ignore_epipe: true)
  ...>   |> Stream.take(5)
  ...>   |> Enum.into("")
  iex> byte_size(data)
  500
  ```

  When input and output run at different rate

  ```
  iex> input_stream = Stream.map(1..1000, fn num -> "X #{num} X\n" end)
  iex> ExCmd.stream!(~w(grep 250), input: input_stream)
  ...> |> Enum.into("")
  "X 250 X\n"
  ```

  With stderr set to :redirect_to_stdout

  ```
  iex> ExCmd.stream!(["sh", "-c", "echo foo; echo bar >&2"], stderr: :redirect_to_stdout)
  ...> |> Enum.into("")
  "foo\nbar\n"
  ```

  With stderr set to :disable

  ```
  iex> ExCmd.stream!(["sh", "-c", "echo foo; echo bar >&2"], stderr: :disable)
  ...> |> Enum.to_list()
  ["foo\n"]
  ```

  For more details about stream API, see `ExCmd.stream!/2` and `ExCmd.stream/2`.

  For more details about inner working, please check `ExCmd.Process`
  documentation.
  """

  use Application

  @doc false
  def start(_type, _args) do
    opts = [
      name: ExCmd.WatcherSupervisor,
      strategy: :one_for_one
    ]

    # We use DynamicSupervisor for cleaning up external processes on
    # :init.stop or SIGTERM
    DynamicSupervisor.start_link(opts)
  end

  @doc ~S"""
  Runs the command with arguments and return an the stdout as lazily
  Enumerable stream, similar to [`Stream`](https://hexdocs.pm/elixir/Stream.html).

  First parameter must be a list containing command with arguments.
  Example: `["cat", "file.txt"]`.

  ### Options

    * `input` - Input can be either an `Enumerable` or a function which accepts `Collectable`.

      * Enumerable:

        ```
        # List
        ExCmd.stream!(~w(base64), input: ["hello", "world"]) |> Enum.to_list()
        # Stream
        ExCmd.stream!(~w(cat), input: File.stream!("log.txt", [], 65_531)) |> Enum.to_list()
        ```

      * Collectable:

        If the input in a function with arity 1, ExCmd will call that function
        with a `Collectable` as the argument. The function must *push* input to this
        collectable. Return value of the function is ignored.

        ```
        ExCmd.stream!(~w(cat), input: fn sink -> Enum.into(1..100, sink, &to_string/1) end)
        |> Enum.to_list()
        ```

        By defaults no input is sent to the command.

    * `exit_timeout` - Duration to wait for external program to exit after completion
  (when stream ends). Defaults to `:infinity`

    * `max_chunk_size` - Maximum size of iodata chunk emitted by the stream.
  Chunk size can be less than the `max_chunk_size` depending on the amount of
  data available to be read. Defaults to 65_531. Value must <= 65_531 and > 0.

    * `stderr`  -  different ways to handle stderr stream.
        1. `:console`  -  stderr output is redirected to console (Default)
        2. `:redirect_to_stdout`  -  stderr output is redirected to stdout
        3. `:disable`  -  stderr output is redirected `/dev/null` suppressing all output

       See [`:stderr`](`m:ExCmd.Process#module-stderr`) for more details and issues associated with them.

    * `ignore_epipe` - When set to true, reader can exit early without raising error.
  Typically writer gets `EPIPE` error on write when program terminate prematurely.
  With `ignore_epipe` set to true this error will be ignored. This can be used to
  match UNIX shell default behaviour. EPIPE is the error raised when the reader finishes
  the reading and close output pipe before command completes. Defaults to `false`.

  Remaining options are passed to `ExCmd.Process.start_link/2`

  If program exits with non-zero exit status or :epipe then `ExCmd.Stream.AbnormalExit`
  error will be raised with `exit_status` field set.

  ### Examples

  ```
  ExCmd.stream!(~w(ffmpeg -i pipe:0 -f mp3 pipe:1), input: File.stream!("music_video.mkv", [], 65_535))
  |> Stream.into(File.stream!("music.mp3"))
  |> Stream.run()
  ```

  Stream with stderr redirected to stdout

  ```
  ExCmd.stream!(["sh", "-c", "echo foo; echo bar >&2"], stderr: :redirect_to_stdout)
  |> Stream.map(&IO.write/1)
  |> Stream.run()
  ```
  """
  @type collectable_func() :: (Collectable.t() -> any())

  @spec stream!(nonempty_list(String.t()),
          input: Enum.t() | collectable_func(),
          exit_timeout: timeout(),
          stderr: :console | :redirect_to_stdout | :disable,
          ignore_epipe: boolean(),
          max_chunk_size: pos_integer()
        ) :: ExCmd.Stream.t()
  def stream!(cmd_with_args, opts \\ []) do
    ExCmd.Stream.__build__(cmd_with_args, Keyword.put(opts, :stream_exit_status, false))
  end

  @doc ~S"""
  Same as `ExCmd.stream!/2` but the program exit status is passed as last
  element of the stream.

  The last element will be of the form `{:exit, term()}`. `term` will be a
  positive integer in case of normal exit and `:epipe` in case of epipe error

  See `ExCmd.stream!/2` documentation for details about the options and
  examples.
  """
  @spec stream(nonempty_list(String.t()),
          input: Enum.t() | collectable_func(),
          exit_timeout: timeout(),
          stderr: :console | :redirect_to_stdout | :disable,
          ignore_epipe: boolean(),
          max_chunk_size: pos_integer()
        ) :: ExCmd.Stream.t()
  def stream(cmd_with_args, opts \\ []) do
    ExCmd.Stream.__build__(cmd_with_args, Keyword.put(opts, :stream_exit_status, true))
  end
end
