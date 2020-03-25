defmodule ExCmd do
  alias ExCmd.Server
  require Logger

  @default_opts %{log: true}

  def stream(stream, cmd, args, opts \\ %{}) do
    opts = Map.merge(opts, @default_opts)

    stream
    |> Stream.transform(
      fn ->
        Server.start_server(cmd, args, opts)
      end,
      fn data, server ->
        with :ok <- Server.write(server, data),
             {:ok, data} <- Server.read(server) do
          {[data], server}
        else
          :eof ->
            {:halt, server}

          error ->
            Logger.warn(error)
            raise error
        end
      end,
      fn server ->
        # always close stdin before stoping
        Server.close_input(server)
        Server.stop(server)
      end
    )
  end
end
