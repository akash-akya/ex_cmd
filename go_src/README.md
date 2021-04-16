Odu
====

Odu is a middleware program which helps with talking to external programs from Elixir or Erlang.

Port implementation in beam has several limitation when it comes to spawning external command and communicating with it. Limitations such as no back-pressure to external command, ability wait to output after closing stdin (when port is closed, beam closes both stdin and stdout), possibility of zombie proccess. Odu together [ExCmd](https://github.com/akash-akya/ex_cmd) tries to fix these issues.

Odu is based on [goon](https://github.com/alco/goon) by [Alexei Sholik](https://github.com/alco).

## Usage

Put odu somewhere in your `PATH` (or into the directory that will become the current
working directory of your application) and use [ExCmd](https://github.com/akash-akya/ex_cmd) Elixir library

## Building from source

```sh
$ go build
```

## License

This software is licensed under [the MIT license](LICENSE).
