Odu
====

Odu is a middleware program which helps with talking to external programs from Elixir or Erlang.

Port implementation in beam has several limitation when it comes to spawning external command and communicating with it. Limitations such as no back-pressure to external command, ability wait to output after closing stdin (when port is closed, beam closes both stdin and stdout), possibility of zombie proccess.

Odu is based on [goon](https://github.com/alco/goon) by [Alexei Sholik](https://github.com/alco).
