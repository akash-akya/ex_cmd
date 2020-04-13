# ExCmd

ExCmd is an Elixir library to run and communicate with external programs with back-pressure.

ExCmd is built around the idea of streaming data through external program. Think streaming a video through `ffmpeg` to server a web request. For example, getting audio out of a stream is as simple as
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

`ExCmd.stream!` is a convenience wrapper around `ExCmd.ProcServer`. If you want more control over stdin, stdout and os process use `ExCmd.ProcServer` directly.

*Note: ExCmd is still work-in-progress. Expect breaking changes*

### Why not use built-in ports?
* Unlike beam ports, ExCmd puts back pressure on external program
* Proper program termination. No more zombie process
* Ability to close stdin and wait for output (with ports one can not selectively close stdin)

If all you want is to run a command with no communication, then just sticking with `System.cmd` is better option.

## Overview
Each `ExCmd.ProcessServer` process maps to an OS process. Internally `ExCmd.ProcessServer` creates and manages separate processes for each of the IO streams (Stdin, Stdout, Stderr) and a port which maps to an OS proccess (an `odu` process). Keeping input, output and the OS process as separate beam proccess helps us to handle them independently (closing stdin, blocking the OS process by not opening stdout pipe). Conceptually this directly maps to handling of process at OS level. Blocking functions such as `read` and `write` only blocks the calling process, not the `ExCmd.Process` itself. A blocking read does not *not* block a parallel write. These blocking calls are the primitives for building back-pressure.

For most of the use-cases using `ExCmd.stream!` abstraction should be enough. Use `ExCmd.ProcessServer` only if you need more control over the life-cycle of IO streams and OS process.

### Why not use NIF?
These are essentially same as "why use port over NIF"
* **Safety:** Failures in external command or ExCmd doesn't bring whole VM down
* **Scheduling:** ExCmd plays well with the beam scheduler, you don't have to worry about blocking scheduler
* **Ease:** It is easier to work with an Elixir library than to understanding NIF
* **Ergonomics:** ExCmd can be thought as just linking your beam processes and external program with good old pipes


ExCmd uses [odu](https://github.com/akash-akya/odu) as a middleware to fill the gaps left ports.

## Installation

1. Install [odu](https://github.com/akash-akya/odu) and make sure its in you path
2. Install ExCmd
