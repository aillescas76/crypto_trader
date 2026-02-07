defmodule CriptoTrader.OrderManagerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CriptoTrader.OrderManager

  setup do
    previous_trading_mode = Application.get_env(:cripto_trader, :trading_mode)

    if is_nil(Process.whereis(CriptoTrader.Paper.Orders)) do
      start_supervised!(CriptoTrader.Paper.Orders)
    end

    Application.put_env(:cripto_trader, :trading_mode, :live)

    on_exit(fn ->
      if is_nil(previous_trading_mode) do
        Application.delete_env(:cripto_trader, :trading_mode)
      else
        Application.put_env(:cripto_trader, :trading_mode, previous_trading_mode)
      end
    end)

    :ok
  end

  test "allows per-call paper override even when global mode is live" do
    {result, log} =
      with_log(fn ->
        OrderManager.place_order(
          %{symbol: "BTCUSDT", side: "BUY", type: "MARKET", quantity: 1.0, price: 10.0},
          trading_mode: :paper,
          risk_config: %CriptoTrader.Risk.Config{max_order_quote: 1_000.0}
        )
      end)

    assert {:ok, order} = result

    assert order.symbol == "BTCUSDT"
    assert order.side == "BUY"
    assert order.status == "FILLED"
    assert log =~ "\"event\":\"order_submitted\""
    assert log =~ "\"symbol\":\"BTCUSDT\""
    assert log =~ "\"trading_mode\":\"paper\""
  end

  test "returns error on invalid per-call trading mode" do
    {result, log} =
      with_log(fn ->
        OrderManager.place_order(
          %{symbol: "BTCUSDT", side: "BUY", type: "MARKET", quantity: 1.0, price: 10.0},
          trading_mode: :sandbox
        )
      end)

    assert {:error, :invalid_trading_mode} = result
    assert log =~ "\"event\":\"order_rejected\""
    assert log =~ "\"phase\":\"pre_submit\""
    assert log =~ "\"reason\":\"invalid_trading_mode\""
  end

  test "logs risk rejections with structured reason" do
    {result, log} =
      with_log(fn ->
        OrderManager.place_order(
          %{symbol: "BTCUSDT", side: "BUY", type: "MARKET", quantity: 2.0, price: 10.0},
          trading_mode: :paper,
          risk_config: %CriptoTrader.Risk.Config{max_order_quote: 5.0}
        )
      end)

    assert {:error, {:risk, :max_order_quote}} = result
    assert log =~ "\"event\":\"order_rejected\""
    assert log =~ "\"phase\":\"risk\""
    assert log =~ "\"reason\":\"max_order_quote\""
  end
end
