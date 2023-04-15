defmodule ExCmd.StreamTest do
  use ExUnit.Case, async: true

  test "simple stream input" do
    stream =
      1..10
      |> Stream.map(&to_string/1)
      |> Stream.take(5)

    assert "12345" =
             ExCmd.stream!(~w(cat), input: stream)
             |> Enum.into("")
  end

  test "resource stream input" do
    stream =
      Stream.resource(
        fn -> 0 end,
        fn last ->
          n = last + 1
          if n > 5, do: {:halt, nil}, else: {[to_string(n)], n}
        end,
        fn _ -> nil end
      )

    assert "12345" =
             ExCmd.stream!(~w(cat), input: stream)
             |> Enum.into("")
  end
end
