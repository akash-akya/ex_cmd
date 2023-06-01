# ExCmd

[![CI](https://github.com/akash-akya/ex_cmd/actions/workflows/elixir.yml/badge.svg)](https://github.com/akash-akya/ex_cmd/actions/workflows/elixir.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/ex_cmd.svg)](https://hex.pm/packages/ex_cmd)
[![docs](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/ex_cmd/)


ExCmd is an Elixir library to run and communicate with external
programs with back-pressure mechanism. It makes use os backed stdio
buffer for this.

Communication with external program using
[Port](https://hexdocs.pm/elixir/Port.html) is not demand driven. So
it is easy to run into memory issues when the size of the data we are
writing or reading from the external program is large. ExCmd tries to
solve this problem by making better use of os backed stdio buffers
and providing demand-driven interface to write and read from external
program. It can be used to stream data through an external
program. For example, streaming a video through `ffmpeg` to serve a
web request.

Getting audio out of a video stream is as simple as

``` elixir
ExCmd.stream!(~w(ffmpeg -i pipe:0 -f mp3 pipe:1), input: File.stream!("music_video.mkv", [], 65336))
|> Stream.into(File.stream!("music.mp3"))
|> Stream.run()
```

### Major Features

* Unlike beam ports, ExCmd puts back pressure on the external program
* Stream abstraction
* No separate shim installation required
* Ships pre-built binaries for MacOS, Windows, Linux
* Proper program termination. No more zombie process
* Ability to close stdin and wait for output (with ports one can not selectively close stdin)


## Examples

```elixir
ExCmd.stream!(~w(curl ifconfig.co))
|> Enum.into("")
```

Binary as input

  ```elixir
  ExCmd.stream!(~w(cat), input: "Hello World")
  |> Enum.into("")
  # => "Hello World"
  ```

  ```elixir
  ExCmd.stream!(~w(base64), input: <<1, 2, 3, 4, 5>>)
  |> Enum.into("")
  # => "AQIDBAU=\n"
  ```

List of binary as input

  ```elixir
  ExCmd.stream!(~w(cat), input: ["Hello ", "World"])
  |> Enum.into("")
  # => "Hello World"
  ```

iodata as input

  ```elixir
  ExCmd.stream!(~w(base64), input: [<<1, 2,>>, [3], [<<4, 5>>]])
  |> Enum.into("")
  # => "AQIDBAU=\n"
  ```

If you want pipes and globs, you can spawn shell process and pass your
pipeline as argument

```elixir
cmd = "echo 'foo bar' | base64"
ExCmd.stream!(["sh", "-c", cmd])
|> Enum.into("")
# => "Zm9vIGJhcgo=\n"
```

Read [stream documentation](file:///Users/akash/repo/elixir/ex_cmd/doc/ExCmd.html#stream!/2) for information
about parameters.

**Check out [Exile](https://github.com/akash-akya/exile) which is an
alternative solution based on NIF without middleware overhead**

## Installation

```elixir
def deps do
  [
    {:ex_cmd, "~> x.x.x"}
  ]
end
```
