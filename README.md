# ExCmd [![Hex.pm](https://img.shields.io/hexpm/v/ex_cmd.svg)](https://hex.pm/packages/ex_cmd)

ExCmd is an Elixir library to run and communicate with external programs with back-pressure.

ExCmd is built around the idea of streaming data through an external program. Think streaming a video through `ffmpeg` to server a web request. For example, getting audio out of a stream is as simple as
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

### Please read this before proceeding

**ExCmd uses `:file` module do IO using named pipes. File io operations with `:raw` mode are blocking operations. This can cause several issues. For example if you are executing a program which is slow and do `read` on its output, the read operation effectively blocks a scheduler (dirty IO scheduler) until the read request is fulfilled by the external program. This is how file operations are implemented in beam and there are no non-blocking alternatives at the moment. If you are still reading, are few ways to mitigate this issue**

1. limit number of parallel execution using a pooling library or adjust concurrency of background job which executes the program
2. increase dirty schedulers count using [`+SDio`](https://erlang.org/doc/man/erl.html) VM arg
3. read or write in smaller chunks

If you are executing a few programs this should not be a major issue.

**Check out [Exile](https://github.com/akash-akya/exile) which is NIF based solution to fix these issues**

### Why not use built-in ports?
* Unlike beam ports, ExCmd puts back pressure on the external program
* Proper program termination. No more zombie process
* Ability to close stdin and wait for output (with ports one can not selectively close stdin)

If all you want is to run a command with no communication, then just sticking with `System.cmd` is a better option.

## Overview
Each `ExCmd.ProcessServer` process maps to an OS process. Internally `ExCmd.ProcessServer` creates and manages separate processes for each of the IO streams (Stdin, Stdout, Stderr) and a port that maps to an OS process (an `odu` process). Keeping input, output and the OS process as a separate beam process helps us to handle them independently (closing stdin, blocking the OS process by not opening stdout pipe). Conceptually this directly maps to the OS primitives.

For most of the use-cases using `ExCmd.stream!` abstraction should be enough. Use `ExCmd.ProcessServer` only if you need more control over the life-cycle of IO streams and OS process.

Check [documentation](https://hexdocs.pm/ex_cmd/readme.html) for information

ExCmd uses [odu](https://github.com/akash-akya/odu) as a middleware to fill the gaps left ports.

## Installation

1. Install latest [odu](https://github.com/akash-akya/odu) and make sure its in your path
2. Install ExCmd
```elixir
def deps do
  [
    {:ex_cmd, "~> x.x.x"}
  ]
end
```
