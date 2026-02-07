defmodule CriptoTrader.RiskTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Risk
  alias CriptoTrader.Risk.Config

  test "blocks when circuit breaker is active" do
    config = %Config{circuit_breaker: true}

    assert {:error, {:risk, :circuit_breaker}} = Risk.check_order(%{}, config, %{})
  end

  test "blocks when drawdown exceeds max" do
    config = %Config{max_drawdown_pct: 0.2}

    assert {:error, {:risk, :max_drawdown}} =
             Risk.check_order(%{}, config, %{drawdown_pct: 0.25})
  end

  test "blocks when order quote exceeds max" do
    config = %Config{max_order_quote: 100.0}
    order = %{quantity: 2, price: 60}

    assert {:error, {:risk, :max_order_quote}} = Risk.check_order(order, config, %{})
  end

  test "allows when within limits" do
    config = %Config{max_order_quote: 100.0, max_drawdown_pct: 0.2}
    order = %{quantity: 1, price: 50}

    assert :ok = Risk.check_order(order, config, %{drawdown_pct: 0.1})
  end
end
