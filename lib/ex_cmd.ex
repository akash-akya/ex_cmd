defmodule ExCmd do
  alias ExCmd.Server

  @default_opts %{
    chunk_size: 65535,
    log: true
  }

  def stream(cmd, args, opts \\ %{}) do
    opts = Map.merge(opts, @default_opts)

    Stream.resource(
      fn ->
        server_opts = Map.drop(opts, [:chunk_size])
        {:ok, server} = Server.start_link(cmd, args, server_opts)
        server
      end,
      fn server ->
        Server.pull(server, opts[:chunk_size])
        |> case do
          {:done, [], 0} ->
            {:halt, server}

          {:done, data, 0} ->
            {data, server}

          {:done, _, status} ->
            raise "Abnormal command exit. status: #{status}"

          {:cont, data} ->
            {data, server}
        end
      end,
      fn server ->
        Server.stop(server)
      end
    )
  end
end
