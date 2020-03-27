defmodule ExCmd.FIFOTest do
  use ExUnit.Case
  alias ExCmd.FIFO

  setup do
    Temp.track!()
    dir = Temp.mkdir!()
    %{path: Temp.path!(%{basedir: dir})}
  end

  test "create", %{path: path} do
    FIFO.create(path)
    stat = File.stat!(path)
    assert stat.type == :other
    assert stat.access == :read_write
  end
end
