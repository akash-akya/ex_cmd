defmodule ExCmd do
  alias ExCmd.ProcServer
  require Logger

  @default_opts %{log: false}
  def stream(stream, cmd, args \\ [], opts \\ %{}) do
    opts = Map.merge(opts, @default_opts)

    stream
    |> Stream.transform(
      fn ->
        {:ok, server} = ProcServer.start_link(cmd, args, opts)
        server
      end,
      fn data, server ->
        with :ok <- ProcServer.write(server, data),
             {:ok, data} <- ProcServer.read(server) do
          {[data], server}
        else
          :eof ->
            case ProcServer.status(server) do
              {:done, 0} -> {:halt, server}
              {:done, status} -> raise "command exited with status: #{status}"
            end

          error ->
            Logger.warn(error)
            raise error
        end
      end,
      fn server ->
        # always close stdin before stoping to give the command chance to exit properly
        ProcServer.close_input(server)
        ProcServer.stop(server)
      end
    )
  end
end
