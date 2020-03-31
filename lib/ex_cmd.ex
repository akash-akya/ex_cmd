defmodule ExCmd do
  require Logger

  @default_opts %{log: false}
  def stream!(cmd, args \\ [], opts \\ %{}) do
    opts = Map.merge(opts, @default_opts)
    ExCmd.Stream.__build__(cmd, args, opts)
  end
end
