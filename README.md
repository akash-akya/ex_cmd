# ExCmd [![Hex.pm](https://img.shields.io/hexpm/v/ex_cmd.svg)](https://hex.pm/packages/ex_cmd)

ExCmd is an Elixir library to run and communicate with external programs with back-pressure.

ExCmd is built around the idea of streaming data through an external program. Think streaming a video through `ffmpeg` to server a web request. For example, getting audio out of a stream is as simple as
``` elixir
ExCmd.stream!(~w(ffmpeg -i pipe:0 -f mp3 pipe:1), input: File.stream!("music_video.mkv", [], 65336))
|> Stream.into(File.stream!("music.mp3"))
|> Stream.run()
```

`ExCmd.stream!` is a convenience wrapper around `ExCmd.ProcServer`. If you want more control over stdin, stdout and os process use `ExCmd.Process`.

**Check out [Exile](https://github.com/akash-akya/exile) which is an alternative solution based on NIF**

**Note: ExCmd is still WIP. Expect breaking changes**

### Why not use built-in ports?
* Unlike beam ports, ExCmd puts back pressure on the external program
* Proper program termination. No more zombie process
* Ability to close stdin and wait for output (with ports one can not selectively close stdin)
* Safer, issues in the external process does not crash beam

## Overview
Each `ExCmd.Process` process maps to an OS process. ExCmd uses [odu](https://github.com/akash-akya/odu) middleware to interact and manage external process. It uses a demand-driven protocol for IO and it never reads than the demand.

For most of the use-cases using `ExCmd.stream!` abstraction should be enough.

Check [documentation](https://hexdocs.pm/ex_cmd/readme.html) for information

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
