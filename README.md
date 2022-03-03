# ExCmd

[![CI](https://github.com/akash-akya/ex_cmd/actions/workflows/elixir.yml/badge.svg)](https://github.com/akash-akya/ex_cmd/actions/workflows/elixir.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/ex_cmd.svg)](https://hex.pm/packages/ex_cmd)
[![docs](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/ex_cmd/)


ExCmd is an Elixir library to run and communicate with external programs with back-pressure mechanism. It makes use os provided stdio buffer for this.

Communication with external program using [Port](https://hexdocs.pm/elixir/Port.html) is not demand driven. So it is easy to run into memory issues when the size of the data we are writing or reading from the external program is large. ExCmd tries to solve this problem by making better use of os provided stdio buffers and providing demand-driven interface to write and read from external program. It can be used to stream data through an external program. For example, streaming a video through `ffmpeg` to serve a web request.

Getting audio out of a video stream is as simple as

``` elixir
ExCmd.stream!(~w(ffmpeg -i pipe:0 -f mp3 pipe:1), input: File.stream!("music_video.mkv", [], 65336))
|> Stream.into(File.stream!("music.mp3"))
|> Stream.run()
```

### Major advantages over port

* Unlike beam ports, ExCmd puts back pressure on the external program
* Stream abstraction
* Proper program termination. No more zombie process
* Ability to close stdin and wait for output (with ports one can not selectively close stdin)

Refer [documentation](https://hexdocs.pm/ex_cmd/readme.html) for information

**Check out [Exile](https://github.com/akash-akya/exile) which is an alternative solution based on NIF without middleware overhead**

## Installation

```elixir
def deps do
  [
    {:ex_cmd, "~> x.x.x"}
  ]
end
```
