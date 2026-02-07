defmodule CriptoTrader.Strategy.AlternatingTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Strategy.Alternating

  test "alternates buy and sell independently per symbol" do
    state_0 = Alternating.new_state(["BTCUSDT", "ETHUSDT"], 0.5)

    {orders_1, state_1} = Alternating.signal(%{symbol: "BTCUSDT"}, state_0)
    {orders_2, state_2} = Alternating.signal(%{symbol: "ETHUSDT"}, state_1)
    {orders_3, state_3} = Alternating.signal(%{symbol: "BTCUSDT"}, state_2)
    {orders_4, _state_4} = Alternating.signal(%{symbol: "ETHUSDT"}, state_3)

    assert [%{symbol: "BTCUSDT", side: "BUY", quantity: 0.5}] = orders_1
    assert [%{symbol: "ETHUSDT", side: "BUY", quantity: 0.5}] = orders_2
    assert [%{symbol: "BTCUSDT", side: "SELL", quantity: 0.5}] = orders_3
    assert [%{symbol: "ETHUSDT", side: "SELL", quantity: 0.5}] = orders_4
  end

  test "returns no orders when event symbol is missing" do
    state = Alternating.new_state(["BTCUSDT"], 0.25)
    assert {[], ^state} = Alternating.signal(%{open_time: 1_000}, state)
  end
end
