# ExCmd

ExCmd is an Elixir library to run and communicate with external programs.

ExCmd is built around the idea of streaming data through external program. Think streaming video through `ffmpeg` command and receiving the output back. ExCmd tries to solve this along with [odu](https://github.com/akash-akya/odu).

*Note: ExCmd is still work-in-progress. Expect breaking changes*

### Why not use built-in ports?
* Unlike beam ports, ExCmd puts back pressure on external program
* Proper program termination. No more zombie process
* Ability to close stdin and wait for output (with ports one can not selectively close stdin)

If all you want is to run a command with no communication, then just sticking with `System.cmd` is better option.

### Why not use NIF?
These are essentially same as "why use port over NIF"
* **Safety:** Failures in external command or ExCmd doesn't bring whole VM down
* **Scheduling:** ExCmd plays well with the beam scheduler, you don't have to worry about blocking scheduler
* **Ease:** It is easier to work with an Elixir library than to understanding NIF
* **Ergonomics:** ExCmd can be thought as just linking your beam processes and external program with good old pipes


## Usage

1. Install [odu](https://github.com/akash-akya/odu) and make sure its in you path
2. Use ExCmd
