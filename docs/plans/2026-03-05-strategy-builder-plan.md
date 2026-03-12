# Automated Strategy Builder — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add LLM-driven automated strategy creation with a Phoenix LiveView dashboard to the existing cripto_trader Elixir trading bot.

**Architecture:** Monolith Phoenix app added to the existing `cripto_trader` OTP application. New modules: indicator library, JSON strategy spec interpreter, Claude API client, Binance WebSocket, live strategy evaluator, and PostgreSQL persistence via Ecto. Existing modules (`Simulation.Runner`, `Trading.Robot`, `OrderManager`, `Risk`) remain unchanged.

**Tech Stack:** Elixir 1.19, Phoenix 1.7+ (LiveView), Ecto 3.x, PostgreSQL, TailwindCSS, Lightweight Charts (TradingView), Anthropic Claude API (via Req HTTP client).

---

## Phase 1: Indicator Library

Pure computation modules with zero dependencies on the rest of the system. Each indicator is a pure function: `([candle], params) -> [value]`. Candles use the existing `kline` type from `CriptoTrader.MarketData.Candles`.

### Task 1: SMA Indicator

**Files:**
- Create: `lib/cripto_trader/indicators/sma.ex`
- Create: `test/indicators/sma_test.exs`

**Step 1: Write the failing test**

```elixir
# test/indicators/sma_test.exs
defmodule CriptoTrader.Indicators.SMATest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Indicators.SMA

  describe "compute/2" do
    test "computes simple moving average for given period" do
      candles = [
        %{close: "10.0"},
        %{close: "20.0"},
        %{close: "30.0"},
        %{close: "40.0"},
        %{close: "50.0"}
      ]

      result = SMA.compute(candles, period: 3)

      assert result == [nil, nil, 20.0, 30.0, 40.0]
    end

    test "returns all nils when period exceeds candle count" do
      candles = [%{close: "10.0"}, %{close: "20.0"}]
      result = SMA.compute(candles, period: 5)

      assert result == [nil, nil]
    end

    test "period 1 returns the close prices" do
      candles = [%{close: "5.0"}, %{close: "15.0"}]
      result = SMA.compute(candles, period: 1)

      assert result == [5.0, 15.0]
    end

    test "handles string and number close values" do
      candles = [%{close: 10}, %{close: "20.0"}, %{close: 30.0}]
      result = SMA.compute(candles, period: 2)

      assert result == [nil, 15.0, 25.0]
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/indicators/sma_test.exs`
Expected: FAIL with "module CriptoTrader.Indicators.SMA is not available"

**Step 3: Write minimal implementation**

```elixir
# lib/cripto_trader/indicators/sma.ex
defmodule CriptoTrader.Indicators.SMA do
  @moduledoc "Simple Moving Average indicator."

  @spec compute([map()], keyword()) :: [float() | nil]
  def compute(candles, opts) do
    period = Keyword.fetch!(opts, :period)
    closes = Enum.map(candles, &parse_close/1)

    closes
    |> Enum.with_index()
    |> Enum.map(fn {_val, idx} ->
      if idx < period - 1 do
        nil
      else
        window = Enum.slice(closes, (idx - period + 1)..idx)
        Float.round(Enum.sum(window) / period, 8)
      end
    end)
  end

  defp parse_close(%{close: close}) when is_number(close), do: close * 1.0
  defp parse_close(%{close: close}) when is_binary(close) do
    {val, ""} = Float.parse(close)
    val
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/indicators/sma_test.exs`
Expected: 4 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/indicators/sma.ex test/indicators/sma_test.exs
git commit -m "feat: add SMA indicator module"
```

---

### Task 2: EMA Indicator

**Files:**
- Create: `lib/cripto_trader/indicators/ema.ex`
- Create: `test/indicators/ema_test.exs`

**Step 1: Write the failing test**

```elixir
# test/indicators/ema_test.exs
defmodule CriptoTrader.Indicators.EMATest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Indicators.EMA

  describe "compute/2" do
    test "computes EMA with correct smoothing factor" do
      # EMA(3): multiplier = 2/(3+1) = 0.5
      # candle 0: nil (not enough data)
      # candle 1: nil
      # candle 2: SMA(10,20,30) = 20.0 (seed)
      # candle 3: 40*0.5 + 20*0.5 = 30.0
      # candle 4: 50*0.5 + 30*0.5 = 40.0
      candles = [
        %{close: "10.0"},
        %{close: "20.0"},
        %{close: "30.0"},
        %{close: "40.0"},
        %{close: "50.0"}
      ]

      result = EMA.compute(candles, period: 3)

      assert result == [nil, nil, 20.0, 30.0, 40.0]
    end

    test "period 1 returns close prices" do
      candles = [%{close: "5.0"}, %{close: "15.0"}]
      result = EMA.compute(candles, period: 1)

      assert result == [5.0, 15.0]
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/indicators/ema_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

```elixir
# lib/cripto_trader/indicators/ema.ex
defmodule CriptoTrader.Indicators.EMA do
  @moduledoc "Exponential Moving Average indicator."

  @spec compute([map()], keyword()) :: [float() | nil]
  def compute(candles, opts) do
    period = Keyword.fetch!(opts, :period)
    closes = Enum.map(candles, &parse_close/1)
    multiplier = 2.0 / (period + 1)

    {result_rev, _} =
      closes
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {close, idx}, {acc, prev_ema} ->
        cond do
          idx < period - 1 ->
            {[nil | acc], nil}

          idx == period - 1 ->
            seed = Enum.slice(closes, 0..(idx)) |> Enum.sum() |> Kernel./(period)
            seed = Float.round(seed, 8)
            {[seed | acc], seed}

          true ->
            ema = Float.round(close * multiplier + prev_ema * (1 - multiplier), 8)
            {[ema | acc], ema}
        end
      end)

    Enum.reverse(result_rev)
  end

  defp parse_close(%{close: close}) when is_number(close), do: close * 1.0
  defp parse_close(%{close: close}) when is_binary(close) do
    {val, ""} = Float.parse(close)
    val
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/indicators/ema_test.exs`
Expected: 2 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/indicators/ema.ex test/indicators/ema_test.exs
git commit -m "feat: add EMA indicator module"
```

---

### Task 3: RSI Indicator

**Files:**
- Create: `lib/cripto_trader/indicators/rsi.ex`
- Create: `test/indicators/rsi_test.exs`

**Step 1: Write the failing test**

```elixir
# test/indicators/rsi_test.exs
defmodule CriptoTrader.Indicators.RSITest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Indicators.RSI

  describe "compute/2" do
    test "computes RSI with standard 14-period" do
      # 15 candles needed for first RSI with period 14
      candles = Enum.map(1..15, fn i -> %{close: "#{i * 10.0}"} end)

      result = RSI.compute(candles, period: 14)

      # First 13 should be nil, index 14 should have a value
      assert Enum.take(result, 13) == List.duplicate(nil, 13)
      # Monotonically rising prices → RSI should be 100
      assert List.last(result) == 100.0
    end

    test "returns 0 when all moves are down" do
      candles = Enum.map(15..1//-1, fn i -> %{close: "#{i * 10.0}"} end)

      result = RSI.compute(candles, period: 14)

      assert List.last(result) == 0.0
    end

    test "returns around 50 for alternating prices" do
      # Alternating up/down by same amount
      candles = Enum.map(1..15, fn i ->
        if rem(i, 2) == 0, do: %{close: "110.0"}, else: %{close: "100.0"}
      end)

      result = RSI.compute(candles, period: 14)
      rsi = List.last(result)

      assert rsi != nil
      assert rsi > 40.0 and rsi < 60.0
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/indicators/rsi_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

```elixir
# lib/cripto_trader/indicators/rsi.ex
defmodule CriptoTrader.Indicators.RSI do
  @moduledoc "Relative Strength Index indicator (Wilder's smoothing)."

  @spec compute([map()], keyword()) :: [float() | nil]
  def compute(candles, opts) do
    period = Keyword.fetch!(opts, :period)
    closes = Enum.map(candles, &parse_close/1)
    changes = [nil | Enum.zip(closes, tl(closes)) |> Enum.map(fn {prev, cur} -> cur - prev end)]

    {result_rev, _} =
      changes
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {change, idx}, {acc, prev_state} ->
        cond do
          idx < period ->
            {[nil | acc], nil}

          idx == period ->
            window = Enum.slice(changes, 1..period)
            avg_gain = window |> Enum.filter(&(&1 > 0)) |> avg(period)
            avg_loss = window |> Enum.filter(&(&1 < 0)) |> Enum.map(&abs/1) |> avg(period)
            rsi = calc_rsi(avg_gain, avg_loss)
            {[rsi | acc], {avg_gain, avg_loss}}

          true ->
            {prev_avg_gain, prev_avg_loss} = prev_state
            gain = if change > 0, do: change, else: 0.0
            loss = if change < 0, do: abs(change), else: 0.0
            avg_gain = (prev_avg_gain * (period - 1) + gain) / period
            avg_loss = (prev_avg_loss * (period - 1) + loss) / period
            rsi = calc_rsi(avg_gain, avg_loss)
            {[rsi | acc], {avg_gain, avg_loss}}
        end
      end)

    Enum.reverse(result_rev)
  end

  defp calc_rsi(_avg_gain, 0.0), do: 100.0
  defp calc_rsi(0.0, _avg_loss), do: 0.0
  defp calc_rsi(avg_gain, avg_loss) do
    rs = avg_gain / avg_loss
    Float.round(100.0 - 100.0 / (1.0 + rs), 8)
  end

  defp avg([], _period), do: 0.0
  defp avg(values, period), do: Enum.sum(values) / period

  defp parse_close(%{close: close}) when is_number(close), do: close * 1.0
  defp parse_close(%{close: close}) when is_binary(close) do
    {val, ""} = Float.parse(close)
    val
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/indicators/rsi_test.exs`
Expected: 3 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/indicators/rsi.ex test/indicators/rsi_test.exs
git commit -m "feat: add RSI indicator module"
```

---

### Task 4: MACD Indicator

**Files:**
- Create: `lib/cripto_trader/indicators/macd.ex`
- Create: `test/indicators/macd_test.exs`

**Step 1: Write the failing test**

```elixir
# test/indicators/macd_test.exs
defmodule CriptoTrader.Indicators.MACDTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Indicators.MACD

  describe "compute/2" do
    test "returns {macd_line, signal_line, histogram} tuples" do
      # Need at least 26 candles for default MACD(12,26,9)
      candles = Enum.map(1..35, fn i -> %{close: "#{i * 10.0}"} end)

      result = MACD.compute(candles, fast: 12, slow: 26, signal: 9)

      assert is_list(result)
      assert length(result) == 35

      # First 25 should be all-nil tuples (need 26 candles for slow EMA)
      {macd, sig, hist} = List.last(result)
      assert is_float(macd)
      assert is_float(sig)
      assert is_float(hist)
    end

    test "histogram equals macd minus signal" do
      candles = Enum.map(1..35, fn i -> %{close: "#{50 + i * 2.0}"} end)

      result = MACD.compute(candles, fast: 12, slow: 26, signal: 9)

      result
      |> Enum.reject(fn {m, s, _h} -> is_nil(m) or is_nil(s) end)
      |> Enum.each(fn {macd, signal, histogram} ->
        assert_in_delta histogram, macd - signal, 0.0001
      end)
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/indicators/macd_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

```elixir
# lib/cripto_trader/indicators/macd.ex
defmodule CriptoTrader.Indicators.MACD do
  @moduledoc "Moving Average Convergence Divergence indicator."

  alias CriptoTrader.Indicators.EMA

  @spec compute([map()], keyword()) :: [{float() | nil, float() | nil, float() | nil}]
  def compute(candles, opts) do
    fast_period = Keyword.get(opts, :fast, 12)
    slow_period = Keyword.get(opts, :slow, 26)
    signal_period = Keyword.get(opts, :signal, 9)

    fast_ema = EMA.compute(candles, period: fast_period)
    slow_ema = EMA.compute(candles, period: slow_period)

    macd_line =
      Enum.zip(fast_ema, slow_ema)
      |> Enum.map(fn
        {nil, _} -> nil
        {_, nil} -> nil
        {f, s} -> Float.round(f - s, 8)
      end)

    signal_line = ema_over_values(macd_line, signal_period)

    Enum.zip([macd_line, signal_line])
    |> Enum.map(fn
      {nil, _} -> {nil, nil, nil}
      {_, nil} -> {nil, nil, nil}
      {m, s} -> {m, s, Float.round(m - s, 8)}
    end)
  end

  defp ema_over_values(values, period) do
    multiplier = 2.0 / (period + 1)

    {result_rev, _} =
      values
      |> Enum.reduce({[], {0, [], nil}}, fn val, {acc, {non_nil_count, seed_acc, prev_ema}} ->
        case val do
          nil ->
            {[nil | acc], {non_nil_count, seed_acc, prev_ema}}

          v ->
            count = non_nil_count + 1

            cond do
              count < period ->
                {[nil | acc], {count, [v | seed_acc], nil}}

              count == period ->
                seed = Enum.sum([v | seed_acc]) / period
                seed = Float.round(seed, 8)
                {[seed | acc], {count, [], seed}}

              true ->
                ema = Float.round(v * multiplier + prev_ema * (1 - multiplier), 8)
                {[ema | acc], {count, [], ema}}
            end
        end
      end)

    Enum.reverse(result_rev)
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/indicators/macd_test.exs`
Expected: 2 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/indicators/macd.ex test/indicators/macd_test.exs
git commit -m "feat: add MACD indicator module"
```

---

### Task 5: Bollinger Bands Indicator

**Files:**
- Create: `lib/cripto_trader/indicators/bb.ex`
- Create: `test/indicators/bb_test.exs`

**Step 1: Write the failing test**

```elixir
# test/indicators/bb_test.exs
defmodule CriptoTrader.Indicators.BBTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Indicators.BB

  describe "compute/2" do
    test "returns {upper, middle, lower} tuples" do
      candles = [
        %{close: "10.0"},
        %{close: "20.0"},
        %{close: "30.0"},
        %{close: "40.0"},
        %{close: "50.0"}
      ]

      result = BB.compute(candles, period: 3, std_dev: 2)

      assert length(result) == 5
      assert Enum.at(result, 0) == {nil, nil, nil}
      assert Enum.at(result, 1) == {nil, nil, nil}

      {upper, middle, lower} = Enum.at(result, 2)
      assert middle == 20.0
      assert upper > middle
      assert lower < middle
      assert_in_delta upper - middle, middle - lower, 0.0001
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/indicators/bb_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

```elixir
# lib/cripto_trader/indicators/bb.ex
defmodule CriptoTrader.Indicators.BB do
  @moduledoc "Bollinger Bands indicator."

  @spec compute([map()], keyword()) :: [{float() | nil, float() | nil, float() | nil}]
  def compute(candles, opts) do
    period = Keyword.get(opts, :period, 20)
    num_std = Keyword.get(opts, :std_dev, 2)
    closes = Enum.map(candles, &parse_close/1)

    closes
    |> Enum.with_index()
    |> Enum.map(fn {_val, idx} ->
      if idx < period - 1 do
        {nil, nil, nil}
      else
        window = Enum.slice(closes, (idx - period + 1)..idx)
        middle = Enum.sum(window) / period
        variance = Enum.reduce(window, 0.0, fn v, acc -> acc + (v - middle) * (v - middle) end) / period
        std = :math.sqrt(variance)

        {
          Float.round(middle + num_std * std, 8),
          Float.round(middle, 8),
          Float.round(middle - num_std * std, 8)
        }
      end
    end)
  end

  defp parse_close(%{close: close}) when is_number(close), do: close * 1.0
  defp parse_close(%{close: close}) when is_binary(close) do
    {val, ""} = Float.parse(close)
    val
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/indicators/bb_test.exs`
Expected: 1 test, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/indicators/bb.ex test/indicators/bb_test.exs
git commit -m "feat: add Bollinger Bands indicator module"
```

---

### Task 6: ATR Indicator

**Files:**
- Create: `lib/cripto_trader/indicators/atr.ex`
- Create: `test/indicators/atr_test.exs`

**Step 1: Write the failing test**

```elixir
# test/indicators/atr_test.exs
defmodule CriptoTrader.Indicators.ATRTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Indicators.ATR

  describe "compute/2" do
    test "computes ATR using true range" do
      candles = [
        %{high: "12.0", low: "8.0", close: "10.0"},
        %{high: "15.0", low: "9.0", close: "14.0"},
        %{high: "16.0", low: "11.0", close: "13.0"},
        %{high: "18.0", low: "12.0", close: "17.0"}
      ]

      result = ATR.compute(candles, period: 3)

      assert length(result) == 4
      assert Enum.at(result, 0) == nil
      assert Enum.at(result, 1) == nil
      # First ATR is average of first 3 true ranges
      assert is_float(Enum.at(result, 2))
      assert is_float(Enum.at(result, 3))
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/indicators/atr_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

```elixir
# lib/cripto_trader/indicators/atr.ex
defmodule CriptoTrader.Indicators.ATR do
  @moduledoc "Average True Range indicator."

  @spec compute([map()], keyword()) :: [float() | nil]
  def compute(candles, opts) do
    period = Keyword.fetch!(opts, :period)

    true_ranges =
      candles
      |> Enum.with_index()
      |> Enum.map(fn {candle, idx} ->
        high = parse_num(candle, :high, "high")
        low = parse_num(candle, :low, "low")

        if idx == 0 do
          high - low
        else
          prev_close = parse_num(Enum.at(candles, idx - 1), :close, "close")
          Enum.max([high - low, abs(high - prev_close), abs(low - prev_close)])
        end
      end)

    {result_rev, _} =
      true_ranges
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {tr, idx}, {acc, prev_atr} ->
        cond do
          idx < period - 1 ->
            {[nil | acc], nil}

          idx == period - 1 ->
            seed = Enum.slice(true_ranges, 0..idx) |> Enum.sum() |> Kernel./(period)
            {[Float.round(seed, 8) | acc], seed}

          true ->
            atr = (prev_atr * (period - 1) + tr) / period
            {[Float.round(atr, 8) | acc], atr}
        end
      end)

    Enum.reverse(result_rev)
  end

  defp parse_num(candle, atom_key, string_key) do
    val = Map.get(candle, atom_key) || Map.get(candle, string_key)

    case val do
      n when is_number(n) -> n * 1.0
      s when is_binary(s) ->
        {f, ""} = Float.parse(s)
        f
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/indicators/atr_test.exs`
Expected: 1 test, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/indicators/atr.ex test/indicators/atr_test.exs
git commit -m "feat: add ATR indicator module"
```

---

### Task 7: Volume Indicator

**Files:**
- Create: `lib/cripto_trader/indicators/vol.ex`
- Create: `test/indicators/vol_test.exs`

**Step 1: Write the failing test**

```elixir
# test/indicators/vol_test.exs
defmodule CriptoTrader.Indicators.VOLTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Indicators.VOL

  describe "compute/2" do
    test "returns {raw_volume, volume_ma} tuples" do
      candles = [
        %{volume: "100.0"},
        %{volume: "200.0"},
        %{volume: "300.0"},
        %{volume: "400.0"}
      ]

      result = VOL.compute(candles, period: 3)

      assert length(result) == 4
      assert Enum.at(result, 0) == {100.0, nil}
      assert Enum.at(result, 1) == {200.0, nil}
      assert Enum.at(result, 2) == {300.0, 200.0}
      assert Enum.at(result, 3) == {400.0, 300.0}
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/indicators/vol_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

```elixir
# lib/cripto_trader/indicators/vol.ex
defmodule CriptoTrader.Indicators.VOL do
  @moduledoc "Volume analysis indicator (raw volume + moving average)."

  @spec compute([map()], keyword()) :: [{float(), float() | nil}]
  def compute(candles, opts) do
    period = Keyword.get(opts, :period, 20)
    volumes = Enum.map(candles, &parse_volume/1)

    volumes
    |> Enum.with_index()
    |> Enum.map(fn {vol, idx} ->
      if idx < period - 1 do
        {vol, nil}
      else
        window = Enum.slice(volumes, (idx - period + 1)..idx)
        ma = Float.round(Enum.sum(window) / period, 8)
        {vol, ma}
      end
    end)
  end

  defp parse_volume(candle) do
    val = Map.get(candle, :volume) || Map.get(candle, "volume")

    case val do
      n when is_number(n) -> n * 1.0
      s when is_binary(s) ->
        {f, ""} = Float.parse(s)
        f
      nil -> 0.0
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/indicators/vol_test.exs`
Expected: 1 test, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/indicators/vol.ex test/indicators/vol_test.exs
git commit -m "feat: add Volume indicator module"
```

---

### Task 8: Indicator Registry

A lookup module so the spec interpreter can resolve indicator types by name.

**Files:**
- Create: `lib/cripto_trader/indicators/registry.ex`
- Create: `test/indicators/registry_test.exs`

**Step 1: Write the failing test**

```elixir
# test/indicators/registry_test.exs
defmodule CriptoTrader.Indicators.RegistryTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.Indicators.Registry

  describe "get/1" do
    test "returns module for known indicators" do
      assert {:ok, CriptoTrader.Indicators.SMA} = Registry.get("sma")
      assert {:ok, CriptoTrader.Indicators.EMA} = Registry.get("ema")
      assert {:ok, CriptoTrader.Indicators.RSI} = Registry.get("rsi")
      assert {:ok, CriptoTrader.Indicators.MACD} = Registry.get("macd")
      assert {:ok, CriptoTrader.Indicators.BB} = Registry.get("bb")
      assert {:ok, CriptoTrader.Indicators.ATR} = Registry.get("atr")
      assert {:ok, CriptoTrader.Indicators.VOL} = Registry.get("vol")
    end

    test "is case-insensitive" do
      assert {:ok, CriptoTrader.Indicators.SMA} = Registry.get("SMA")
      assert {:ok, CriptoTrader.Indicators.RSI} = Registry.get("Rsi")
    end

    test "returns error for unknown indicator" do
      assert {:error, :unknown_indicator} = Registry.get("unknown")
    end
  end

  describe "list/0" do
    test "returns all supported indicator names" do
      names = Registry.list()
      assert "sma" in names
      assert "rsi" in names
      assert length(names) == 7
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/indicators/registry_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

```elixir
# lib/cripto_trader/indicators/registry.ex
defmodule CriptoTrader.Indicators.Registry do
  @moduledoc "Resolves indicator type names to modules."

  @indicators %{
    "sma" => CriptoTrader.Indicators.SMA,
    "ema" => CriptoTrader.Indicators.EMA,
    "rsi" => CriptoTrader.Indicators.RSI,
    "macd" => CriptoTrader.Indicators.MACD,
    "bb" => CriptoTrader.Indicators.BB,
    "atr" => CriptoTrader.Indicators.ATR,
    "vol" => CriptoTrader.Indicators.VOL
  }

  @spec get(String.t()) :: {:ok, module()} | {:error, :unknown_indicator}
  def get(name) do
    case Map.fetch(@indicators, String.downcase(name)) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_indicator}
    end
  end

  @spec list() :: [String.t()]
  def list, do: Map.keys(@indicators)
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/indicators/registry_test.exs`
Expected: 3 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/indicators/registry.ex test/indicators/registry_test.exs
git commit -m "feat: add indicator registry module"
```

---

## Phase 2: Strategy Spec Parser & Expression Engine

### Task 9: Condition Expression Tokenizer

The expression language (e.g., `"sma_fast > sma_slow AND rsi < 30"`) needs a tokenizer and evaluator.

**Files:**
- Create: `lib/cripto_trader/strategy_spec/expression.ex`
- Create: `test/strategy_spec/expression_test.exs`

**Step 1: Write the failing test**

```elixir
# test/strategy_spec/expression_test.exs
defmodule CriptoTrader.StrategySpec.ExpressionTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.StrategySpec.Expression

  describe "evaluate/2" do
    test "evaluates simple comparison" do
      bindings = %{"sma_fast" => 100.0, "sma_slow" => 90.0}
      assert Expression.evaluate("sma_fast > sma_slow", bindings) == {:ok, true}
      assert Expression.evaluate("sma_fast < sma_slow", bindings) == {:ok, false}
    end

    test "evaluates AND conditions" do
      bindings = %{"sma_fast" => 100.0, "sma_slow" => 90.0, "rsi" => 25.0}
      assert Expression.evaluate("sma_fast > sma_slow AND rsi < 30", bindings) == {:ok, true}
      assert Expression.evaluate("sma_fast > sma_slow AND rsi > 30", bindings) == {:ok, false}
    end

    test "evaluates OR conditions" do
      bindings = %{"rsi" => 75.0}
      assert Expression.evaluate("rsi > 70 OR rsi < 30", bindings) == {:ok, true}
      assert Expression.evaluate("rsi > 80 OR rsi < 30", bindings) == {:ok, false}
    end

    test "evaluates comparisons with constants" do
      bindings = %{"close" => 50000.0}
      assert Expression.evaluate("close >= 50000", bindings) == {:ok, true}
      assert Expression.evaluate("close == 50000", bindings) == {:ok, true}
      assert Expression.evaluate("close != 50000", bindings) == {:ok, false}
    end

    test "evaluates arithmetic expressions" do
      bindings = %{"close" => 100.0, "atr" => 5.0}
      assert Expression.evaluate("close - atr * 2 > 80", bindings) == {:ok, true}
    end

    test "evaluates cross_above function" do
      bindings = %{"sma_fast" => 100.0, "sma_slow" => 95.0}
      prev_bindings = %{"sma_fast" => 90.0, "sma_slow" => 95.0}

      assert Expression.evaluate("cross_above(sma_fast, sma_slow)", bindings, prev_bindings) ==
               {:ok, true}
    end

    test "evaluates cross_below function" do
      bindings = %{"sma_fast" => 90.0, "sma_slow" => 95.0}
      prev_bindings = %{"sma_fast" => 100.0, "sma_slow" => 95.0}

      assert Expression.evaluate("cross_below(sma_fast, sma_slow)", bindings, prev_bindings) ==
               {:ok, true}
    end

    test "returns error for unknown variable" do
      assert {:error, {:unknown_variable, "unknown"}} =
               Expression.evaluate("unknown > 5", %{})
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/strategy_spec/expression_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

```elixir
# lib/cripto_trader/strategy_spec/expression.ex
defmodule CriptoTrader.StrategySpec.Expression do
  @moduledoc "Parses and evaluates strategy condition expressions."

  @spec evaluate(String.t(), map(), map()) :: {:ok, boolean()} | {:error, term()}
  def evaluate(expr, bindings, prev_bindings \\ %{}) do
    with {:ok, tokens} <- tokenize(expr),
         {:ok, ast} <- parse(tokens) do
      eval_ast(ast, bindings, prev_bindings)
    end
  end

  # Tokenizer

  defp tokenize(expr) do
    tokens =
      expr
      |> String.trim()
      |> do_tokenize([])

    case tokens do
      {:error, reason} -> {:error, reason}
      tokens -> {:ok, Enum.reverse(tokens)}
    end
  end

  defp do_tokenize("", acc), do: acc
  defp do_tokenize(" " <> rest, acc), do: do_tokenize(rest, acc)
  defp do_tokenize("AND" <> rest, acc), do: do_tokenize(rest, [:and | acc])
  defp do_tokenize("OR" <> rest, acc), do: do_tokenize(rest, [:or | acc])
  defp do_tokenize("NOT" <> rest, acc), do: do_tokenize(rest, [:not | acc])
  defp do_tokenize(">=" <> rest, acc), do: do_tokenize(rest, [:gte | acc])
  defp do_tokenize("<=" <> rest, acc), do: do_tokenize(rest, [:lte | acc])
  defp do_tokenize("!=" <> rest, acc), do: do_tokenize(rest, [:neq | acc])
  defp do_tokenize("==" <> rest, acc), do: do_tokenize(rest, [:eq | acc])
  defp do_tokenize(">" <> rest, acc), do: do_tokenize(rest, [:gt | acc])
  defp do_tokenize("<" <> rest, acc), do: do_tokenize(rest, [:lt | acc])
  defp do_tokenize("+" <> rest, acc), do: do_tokenize(rest, [:plus | acc])
  defp do_tokenize("-" <> rest, acc), do: do_tokenize(rest, [:minus | acc])
  defp do_tokenize("*" <> rest, acc), do: do_tokenize(rest, [:mul | acc])
  defp do_tokenize("/" <> rest, acc), do: do_tokenize(rest, [:div | acc])
  defp do_tokenize("(" <> rest, acc), do: do_tokenize(rest, [:lparen | acc])
  defp do_tokenize(")" <> rest, acc), do: do_tokenize(rest, [:rparen | acc])
  defp do_tokenize("," <> rest, acc), do: do_tokenize(rest, [:comma | acc])

  defp do_tokenize(<<c, _::binary>> = str, acc) when c in ?0..?9 do
    {num_str, rest} = take_number(str)
    {val, ""} = Float.parse(num_str)
    do_tokenize(rest, [{:number, val} | acc])
  end

  defp do_tokenize(<<c, _::binary>> = str, acc) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {ident, rest} = take_ident(str)

    case ident do
      "cross_above" -> do_tokenize(rest, [{:func, :cross_above} | acc])
      "cross_below" -> do_tokenize(rest, [{:func, :cross_below} | acc])
      "AND" -> do_tokenize(rest, [:and | acc])
      "OR" -> do_tokenize(rest, [:or | acc])
      "NOT" -> do_tokenize(rest, [:not | acc])
      _ -> do_tokenize(rest, [{:ident, ident} | acc])
    end
  end

  defp do_tokenize(str, _acc), do: {:error, {:unexpected_char, str}}

  defp take_number(str) do
    {chars, rest} =
      str
      |> String.graphemes()
      |> Enum.split_while(fn c -> c =~ ~r/[0-9.]/ end)

    {Enum.join(chars), Enum.join(rest)}
  end

  defp take_ident(str) do
    {chars, rest} =
      str
      |> String.graphemes()
      |> Enum.split_while(fn c -> c =~ ~r/[a-zA-Z0-9_]/ end)

    {Enum.join(chars), Enum.join(rest)}
  end

  # Parser (recursive descent: or_expr > and_expr > comparison > arithmetic > primary)

  defp parse(tokens) do
    case parse_or(tokens) do
      {:ok, ast, []} -> {:ok, ast}
      {:ok, _ast, rest} -> {:error, {:unexpected_tokens, rest}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens) do
      parse_or_rest(left, rest)
    end
  end

  defp parse_or_rest(left, [:or | rest]) do
    with {:ok, right, rest2} <- parse_and(rest) do
      parse_or_rest({:or, left, right}, rest2)
    end
  end

  defp parse_or_rest(left, rest), do: {:ok, left, rest}

  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_comparison(tokens) do
      parse_and_rest(left, rest)
    end
  end

  defp parse_and_rest(left, [:and | rest]) do
    with {:ok, right, rest2} <- parse_comparison(rest) do
      parse_and_rest({:and, left, right}, rest2)
    end
  end

  defp parse_and_rest(left, rest), do: {:ok, left, rest}

  defp parse_comparison(tokens) do
    with {:ok, left, rest} <- parse_additive(tokens) do
      case rest do
        [op | rest2] when op in [:gt, :lt, :gte, :lte, :eq, :neq] ->
          with {:ok, right, rest3} <- parse_additive(rest2) do
            {:ok, {op, left, right}, rest3}
          end

        _ ->
          {:ok, left, rest}
      end
    end
  end

  defp parse_additive(tokens) do
    with {:ok, left, rest} <- parse_multiplicative(tokens) do
      parse_additive_rest(left, rest)
    end
  end

  defp parse_additive_rest(left, [op | rest]) when op in [:plus, :minus] do
    with {:ok, right, rest2} <- parse_multiplicative(rest) do
      parse_additive_rest({op, left, right}, rest2)
    end
  end

  defp parse_additive_rest(left, rest), do: {:ok, left, rest}

  defp parse_multiplicative(tokens) do
    with {:ok, left, rest} <- parse_primary(tokens) do
      parse_multiplicative_rest(left, rest)
    end
  end

  defp parse_multiplicative_rest(left, [op | rest]) when op in [:mul, :div] do
    with {:ok, right, rest2} <- parse_primary(rest) do
      parse_multiplicative_rest({op, left, right}, rest2)
    end
  end

  defp parse_multiplicative_rest(left, rest), do: {:ok, left, rest}

  defp parse_primary([{:number, val} | rest]), do: {:ok, {:lit, val}, rest}
  defp parse_primary([{:ident, name} | rest]), do: {:ok, {:var, name}, rest}

  defp parse_primary([{:func, func_name}, :lparen | rest]) do
    with {:ok, arg1, [:comma | rest2]} <- parse_or(rest),
         {:ok, arg2, [:rparen | rest3]} <- parse_or(rest2) do
      {:ok, {:call, func_name, [arg1, arg2]}, rest3}
    end
  end

  defp parse_primary([:lparen | rest]) do
    with {:ok, expr, [:rparen | rest2]} <- parse_or(rest) do
      {:ok, expr, rest2}
    end
  end

  defp parse_primary([:not | rest]) do
    with {:ok, expr, rest2} <- parse_primary(rest) do
      {:ok, {:not, expr}, rest2}
    end
  end

  defp parse_primary(tokens), do: {:error, {:unexpected_token, tokens}}

  # Evaluator

  defp eval_ast({:lit, val}, _bindings, _prev), do: {:ok, val}

  defp eval_ast({:var, name}, bindings, _prev) do
    case Map.fetch(bindings, name) do
      {:ok, val} -> {:ok, val}
      :error -> {:error, {:unknown_variable, name}}
    end
  end

  defp eval_ast({:and, left, right}, b, p) do
    with {:ok, l} <- eval_ast(left, b, p),
         {:ok, r} <- eval_ast(right, b, p) do
      {:ok, to_bool(l) and to_bool(r)}
    end
  end

  defp eval_ast({:or, left, right}, b, p) do
    with {:ok, l} <- eval_ast(left, b, p),
         {:ok, r} <- eval_ast(right, b, p) do
      {:ok, to_bool(l) or to_bool(r)}
    end
  end

  defp eval_ast({:not, expr}, b, p) do
    with {:ok, val} <- eval_ast(expr, b, p) do
      {:ok, not to_bool(val)}
    end
  end

  defp eval_ast({op, left, right}, b, p) when op in [:gt, :lt, :gte, :lte, :eq, :neq] do
    with {:ok, l} <- eval_ast(left, b, p),
         {:ok, r} <- eval_ast(right, b, p) do
      result =
        case op do
          :gt -> l > r
          :lt -> l < r
          :gte -> l >= r
          :lte -> l <= r
          :eq -> l == r
          :neq -> l != r
        end

      {:ok, result}
    end
  end

  defp eval_ast({op, left, right}, b, p) when op in [:plus, :minus, :mul, :div] do
    with {:ok, l} <- eval_ast(left, b, p),
         {:ok, r} <- eval_ast(right, b, p) do
      result =
        case op do
          :plus -> l + r
          :minus -> l - r
          :mul -> l * r
          :div -> l / r
        end

      {:ok, result}
    end
  end

  defp eval_ast({:call, :cross_above, [a_ast, b_ast]}, bindings, prev_bindings) do
    with {:ok, a_now} <- eval_ast(a_ast, bindings, prev_bindings),
         {:ok, b_now} <- eval_ast(b_ast, bindings, prev_bindings),
         {:ok, a_prev} <- eval_ast(a_ast, prev_bindings, prev_bindings),
         {:ok, b_prev} <- eval_ast(b_ast, prev_bindings, prev_bindings) do
      {:ok, a_prev <= b_prev and a_now > b_now}
    end
  end

  defp eval_ast({:call, :cross_below, [a_ast, b_ast]}, bindings, prev_bindings) do
    with {:ok, a_now} <- eval_ast(a_ast, bindings, prev_bindings),
         {:ok, b_now} <- eval_ast(b_ast, bindings, prev_bindings),
         {:ok, a_prev} <- eval_ast(a_ast, prev_bindings, prev_bindings),
         {:ok, b_prev} <- eval_ast(b_ast, prev_bindings, prev_bindings) do
      {:ok, a_prev >= b_prev and a_now < b_now}
    end
  end

  defp to_bool(true), do: true
  defp to_bool(false), do: false
  defp to_bool(n) when is_number(n), do: n != 0
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/strategy_spec/expression_test.exs`
Expected: 8 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/strategy_spec/expression.ex test/strategy_spec/expression_test.exs
git commit -m "feat: add condition expression parser and evaluator"
```

---

### Task 10: Strategy Spec Parser & Validator

Validates a JSON strategy spec and produces a structured Elixir map.

**Files:**
- Create: `lib/cripto_trader/strategy_spec/parser.ex`
- Create: `test/strategy_spec/parser_test.exs`

**Step 1: Write the failing test**

```elixir
# test/strategy_spec/parser_test.exs
defmodule CriptoTrader.StrategySpec.ParserTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.StrategySpec.Parser

  @valid_spec %{
    "version" => "1.0",
    "name" => "test_strategy",
    "description" => "A test",
    "symbols" => ["BTCUSDT"],
    "interval" => "15m",
    "indicators" => [
      %{"type" => "sma", "period" => 9, "source" => "close", "as" => "sma_fast"},
      %{"type" => "sma", "period" => 21, "source" => "close", "as" => "sma_slow"}
    ],
    "entry_rules" => [
      %{"condition" => "sma_fast > sma_slow", "action" => "BUY"}
    ],
    "exit_rules" => [
      %{"condition" => "sma_fast < sma_slow", "action" => "SELL"}
    ],
    "risk" => %{
      "position_size_pct" => 0.02,
      "stop_loss_pct" => 0.03
    }
  }

  describe "parse/1" do
    test "parses a valid spec" do
      assert {:ok, parsed} = Parser.parse(@valid_spec)
      assert parsed.name == "test_strategy"
      assert parsed.symbols == ["BTCUSDT"]
      assert length(parsed.indicators) == 2
      assert length(parsed.entry_rules) == 1
      assert length(parsed.exit_rules) == 1
    end

    test "rejects spec with unknown indicator type" do
      spec = put_in(@valid_spec, ["indicators"], [
        %{"type" => "unknown", "period" => 5, "source" => "close", "as" => "x"}
      ])

      assert {:error, {:unknown_indicator, "unknown"}} = Parser.parse(spec)
    end

    test "rejects spec with missing required fields" do
      assert {:error, {:missing_field, "name"}} = Parser.parse(Map.delete(@valid_spec, "name"))
      assert {:error, {:missing_field, "symbols"}} = Parser.parse(Map.delete(@valid_spec, "symbols"))
      assert {:error, {:missing_field, "indicators"}} = Parser.parse(Map.delete(@valid_spec, "indicators"))
    end

    test "rejects spec with invalid condition expression" do
      spec = put_in(@valid_spec, ["entry_rules"], [
        %{"condition" => "!!! invalid", "action" => "BUY"}
      ])

      assert {:error, _} = Parser.parse(spec)
    end

    test "rejects spec with empty symbols" do
      spec = Map.put(@valid_spec, "symbols", [])
      assert {:error, {:invalid_field, "symbols"}} = Parser.parse(spec)
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/strategy_spec/parser_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

```elixir
# lib/cripto_trader/strategy_spec/parser.ex
defmodule CriptoTrader.StrategySpec.Parser do
  @moduledoc "Validates and parses JSON strategy specs into structured Elixir maps."

  alias CriptoTrader.Indicators.Registry
  alias CriptoTrader.StrategySpec.Expression

  @required_fields ["name", "symbols", "indicators", "entry_rules", "exit_rules"]

  @spec parse(map()) :: {:ok, map()} | {:error, term()}
  def parse(spec) when is_map(spec) do
    with :ok <- validate_required_fields(spec),
         :ok <- validate_symbols(spec["symbols"]),
         {:ok, indicators} <- validate_indicators(spec["indicators"]),
         {:ok, entry_rules} <- validate_rules(spec["entry_rules"], "entry_rules"),
         {:ok, exit_rules} <- validate_rules(spec["exit_rules"], "exit_rules") do
      {:ok,
       %{
         version: spec["version"] || "1.0",
         name: spec["name"],
         description: spec["description"] || "",
         symbols: spec["symbols"],
         interval: spec["interval"] || "15m",
         indicators: indicators,
         entry_rules: entry_rules,
         exit_rules: exit_rules,
         risk: parse_risk(spec["risk"] || %{})
       }}
    end
  end

  defp validate_required_fields(spec) do
    case Enum.find(@required_fields, fn f -> is_nil(spec[f]) end) do
      nil -> :ok
      field -> {:error, {:missing_field, field}}
    end
  end

  defp validate_symbols(symbols) when is_list(symbols) and length(symbols) > 0, do: :ok
  defp validate_symbols(_), do: {:error, {:invalid_field, "symbols"}}

  defp validate_indicators(indicators) when is_list(indicators) do
    Enum.reduce_while(indicators, {:ok, []}, fn ind, {:ok, acc} ->
      type = ind["type"]

      case Registry.get(type || "") do
        {:ok, module} ->
          parsed = %{
            type: type,
            module: module,
            period: ind["period"],
            source: ind["source"] || "close",
            as: ind["as"] || type,
            opts: Map.drop(ind, ["type", "source", "as"])
          }

          {:cont, {:ok, acc ++ [parsed]}}

        {:error, :unknown_indicator} ->
          {:halt, {:error, {:unknown_indicator, type}}}
      end
    end)
  end

  defp validate_rules(rules, _name) when is_list(rules) do
    Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, acc} ->
      condition = rule["condition"] || ""
      action = rule["action"] || ""

      # Validate the expression parses (use dummy bindings)
      case Expression.evaluate(condition, %{}, %{}) do
        {:ok, _} ->
          {:cont, {:ok, acc ++ [%{condition: condition, action: String.upcase(action)}]}}

        {:error, {:unknown_variable, _}} ->
          # Variables are validated at runtime, not parse time
          {:cont, {:ok, acc ++ [%{condition: condition, action: String.upcase(action)}]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_condition, condition, reason}}}
      end
    end)
  end

  defp parse_risk(risk) do
    %{
      position_size_pct: risk["position_size_pct"] || 0.02,
      stop_loss_pct: risk["stop_loss_pct"],
      take_profit_pct: risk["take_profit_pct"],
      max_open_positions: risk["max_open_positions"] || 10,
      min_candle_volume: risk["min_candle_volume"],
      max_fill_ratio: risk["max_fill_ratio"] || 0.05,
      slippage_model: risk["slippage_model"] || "linear"
    }
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/strategy_spec/parser_test.exs`
Expected: 5 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/strategy_spec/parser.ex test/strategy_spec/parser_test.exs
git commit -m "feat: add strategy spec parser and validator"
```

---

### Task 11: Strategy Spec Interpreter

Converts a parsed spec into a `strategy_fun` compatible with `Simulation.Runner`.

**Files:**
- Create: `lib/cripto_trader/strategy_spec/interpreter.ex`
- Create: `test/strategy_spec/interpreter_test.exs`

**Step 1: Write the failing test**

```elixir
# test/strategy_spec/interpreter_test.exs
defmodule CriptoTrader.StrategySpec.InterpreterTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.StrategySpec.{Interpreter, Parser}

  @spec %{
    "name" => "test_sma_cross",
    "symbols" => ["BTCUSDT"],
    "interval" => "15m",
    "indicators" => [
      %{"type" => "sma", "period" => 3, "source" => "close", "as" => "sma_fast"},
      %{"type" => "sma", "period" => 5, "source" => "close", "as" => "sma_slow"}
    ],
    "entry_rules" => [%{"condition" => "sma_fast > sma_slow", "action" => "BUY"}],
    "exit_rules" => [%{"condition" => "sma_fast < sma_slow", "action" => "SELL"}],
    "risk" => %{"position_size_pct" => 0.1}
  }

  describe "build_strategy_fun/1" do
    test "returns a 2-arity function" do
      {:ok, parsed} = Parser.parse(@spec)
      {:ok, strategy_fun, initial_state} = Interpreter.build_strategy_fun(parsed)

      assert is_function(strategy_fun, 2)
      assert is_map(initial_state)
    end

    test "strategy produces BUY when entry condition is met" do
      {:ok, parsed} = Parser.parse(@spec)
      {:ok, strategy_fun, initial_state} = Interpreter.build_strategy_fun(parsed)

      # Build candle history where sma_fast(3) > sma_slow(5)
      # Prices: 10, 20, 30, 40, 100 → sma3 of last 3 = (40+100+?), sma5 = avg(all)
      candles = [
        %{open_time: 1000, close: "10.0", volume: "100.0"},
        %{open_time: 2000, close: "20.0", volume: "100.0"},
        %{open_time: 3000, close: "30.0", volume: "100.0"},
        %{open_time: 4000, close: "40.0", volume: "100.0"},
        %{open_time: 5000, close: "100.0", volume: "100.0"}
      ]

      # Feed candles one by one
      {_orders, state} =
        Enum.reduce(Enum.take(candles, 4), {[], initial_state}, fn candle, {_o, s} ->
          event = %{symbol: "BTCUSDT", interval: "15m", open_time: candle.open_time, candle: candle}
          strategy_fun.(event, s)
        end)

      # 5th candle: sma_fast(3)=(30+40+100)/3=56.67, sma_slow(5)=(10+20+30+40+100)/5=40
      # sma_fast > sma_slow → BUY
      event = %{symbol: "BTCUSDT", interval: "15m", open_time: 5000, candle: List.last(candles)}
      {orders, _state} = strategy_fun.(event, state)

      buy_orders = Enum.filter(orders, &(&1.side == "BUY"))
      assert length(buy_orders) > 0
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/strategy_spec/interpreter_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

```elixir
# lib/cripto_trader/strategy_spec/interpreter.ex
defmodule CriptoTrader.StrategySpec.Interpreter do
  @moduledoc """
  Converts a parsed strategy spec into a `strategy_fun` for Simulation.Runner.

  The returned function maintains a candle history buffer per symbol,
  computes indicators on each new candle, and evaluates entry/exit rules.
  """

  alias CriptoTrader.StrategySpec.Expression

  @spec build_strategy_fun(map()) :: {:ok, function(), map()}
  def build_strategy_fun(parsed_spec) do
    initial_state = %{
      candle_history: %{},
      prev_bindings: %{},
      positions: %{}
    }

    strategy_fun = fn event, state ->
      evaluate_event(event, state, parsed_spec)
    end

    {:ok, strategy_fun, initial_state}
  end

  defp evaluate_event(event, state, spec) do
    symbol = event.symbol
    candle = event.candle

    # Update candle history for this symbol
    history = Map.get(state.candle_history, symbol, [])
    max_lookback = max_period(spec.indicators) + 5
    updated_history = Enum.take([candle | history], max_lookback) |> Enum.reverse()

    # Compute indicators
    case compute_indicators(updated_history, spec.indicators) do
      {:ok, bindings} ->
        # Add candle fields to bindings
        bindings =
          bindings
          |> Map.put("close", parse_num(candle, :close, "close"))
          |> Map.put("open", parse_num(candle, :open, "open"))
          |> Map.put("high", parse_num(candle, :high, "high"))
          |> Map.put("low", parse_num(candle, :low, "low"))
          |> Map.put("volume", parse_num(candle, :volume, "volume"))

        prev_bindings = Map.get(state.prev_bindings, symbol, bindings)
        has_position = Map.get(state.positions, symbol, false)

        # Evaluate rules
        orders =
          cond do
            not has_position ->
              evaluate_rules(spec.entry_rules, bindings, prev_bindings, symbol, spec.risk)

            has_position ->
              evaluate_rules(spec.exit_rules, bindings, prev_bindings, symbol, spec.risk)

            true ->
              []
          end

        # Update position tracking
        new_positions =
          Enum.reduce(orders, state.positions, fn order, acc ->
            case order.side do
              "BUY" -> Map.put(acc, symbol, true)
              "SELL" -> Map.delete(acc, symbol)
            end
          end)

        new_state = %{
          state
          | candle_history: Map.put(state.candle_history, symbol, Enum.reverse(updated_history)),
            prev_bindings: Map.put(state.prev_bindings, symbol, bindings),
            positions: new_positions
        }

        {orders, new_state}

      {:error, _} ->
        # Not enough data for indicators yet
        new_state = %{
          state
          | candle_history: Map.put(state.candle_history, symbol, Enum.reverse(updated_history))
        }

        {[], new_state}
    end
  end

  defp compute_indicators(candles, indicator_defs) do
    Enum.reduce_while(indicator_defs, {:ok, %{}}, fn ind, {:ok, acc} ->
      opts = indicator_opts(ind)
      result = ind.module.compute(candles, opts)

      case List.last(result) do
        nil ->
          {:halt, {:error, :insufficient_data}}

        value ->
          bound_value = extract_indicator_value(value)
          {:cont, {:ok, Map.put(acc, ind.as, bound_value)}}
      end
    end)
  end

  defp indicator_opts(%{type: "macd"} = ind) do
    [
      fast: ind.opts["fast"] || 12,
      slow: ind.opts["slow"] || 26,
      signal: ind.opts["signal"] || 9
    ]
  end

  defp indicator_opts(%{type: "bb"} = ind) do
    [period: ind.period || 20, std_dev: ind.opts["std_dev"] || 2]
  end

  defp indicator_opts(ind) do
    [period: ind.period || 14]
  end

  defp extract_indicator_value({upper, _middle, _lower}), do: upper
  defp extract_indicator_value({macd, _signal, _hist}), do: macd
  defp extract_indicator_value({raw, _ma}), do: raw
  defp extract_indicator_value(value) when is_number(value), do: value

  defp evaluate_rules(rules, bindings, prev_bindings, symbol, risk) do
    Enum.flat_map(rules, fn rule ->
      case Expression.evaluate(rule.condition, bindings, prev_bindings) do
        {:ok, true} ->
          quantity = (risk.position_size_pct || 0.02) * 1.0
          [%{symbol: symbol, side: rule.action, quantity: quantity}]

        _ ->
          []
      end
    end)
  end

  defp max_period(indicators) do
    indicators
    |> Enum.map(fn ind ->
      case ind.type do
        "macd" -> max(ind.opts["slow"] || 26, ind.opts["signal"] || 9) + (ind.opts["slow"] || 26)
        _ -> ind.period || 14
      end
    end)
    |> Enum.max(fn -> 14 end)
  end

  defp parse_num(candle, atom_key, string_key) do
    val = Map.get(candle, atom_key) || Map.get(candle, string_key)

    case val do
      n when is_number(n) -> n * 1.0
      s when is_binary(s) ->
        case Float.parse(s) do
          {f, _} -> f
          :error -> 0.0
        end
      _ -> 0.0
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/strategy_spec/interpreter_test.exs`
Expected: 2 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/strategy_spec/interpreter.ex test/strategy_spec/interpreter_test.exs
git commit -m "feat: add strategy spec interpreter (spec -> strategy_fun)"
```

---

### Task 12: Integration Test — Spec through Simulation Runner

Verify end-to-end: JSON spec → parse → interpret → run through `Simulation.Runner`.

**Files:**
- Create: `test/strategy_spec/integration_test.exs`

**Step 1: Write the integration test**

```elixir
# test/strategy_spec/integration_test.exs
defmodule CriptoTrader.StrategySpec.IntegrationTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.StrategySpec.{Parser, Interpreter}
  alias CriptoTrader.Simulation.Runner

  test "JSON spec runs through Simulation.Runner end-to-end" do
    spec = %{
      "name" => "integration_test_strategy",
      "symbols" => ["BTCUSDT"],
      "interval" => "15m",
      "indicators" => [
        %{"type" => "sma", "period" => 3, "source" => "close", "as" => "sma_fast"},
        %{"type" => "sma", "period" => 5, "source" => "close", "as" => "sma_slow"}
      ],
      "entry_rules" => [%{"condition" => "sma_fast > sma_slow", "action" => "BUY"}],
      "exit_rules" => [%{"condition" => "sma_fast < sma_slow", "action" => "SELL"}],
      "risk" => %{"position_size_pct" => 0.01}
    }

    {:ok, parsed} = Parser.parse(spec)
    {:ok, strategy_fun, initial_state} = Interpreter.build_strategy_fun(parsed)

    # Generate candles: uptrend then downtrend
    candles =
      (Enum.map(1..10, fn i -> %{open_time: i * 1000, close: "#{50 + i * 5}.0", volume: "1000.0", open: "50.0", high: "#{55 + i * 5}.0", low: "#{45 + i * 5}.0"} end) ++
       Enum.map(11..20, fn i -> %{open_time: i * 1000, close: "#{150 - i * 5}.0", volume: "1000.0", open: "100.0", high: "#{155 - i * 5}.0", low: "#{145 - i * 5}.0"} end))

    {:ok, result} =
      Runner.run(
        symbols: ["BTCUSDT"],
        interval: "15m",
        candles_by_symbol: %{"BTCUSDT" => candles},
        strategy_fun: strategy_fun,
        strategy_state: initial_state,
        trading_mode: :paper,
        include_trade_log: true
      )

    assert result.summary.events_processed == 20
    assert is_float(result.summary.pnl)
    assert is_float(result.summary.win_rate)
    assert is_list(result.trade_log)
  end
end
```

**Step 2: Run test**

Run: `mix test test/strategy_spec/integration_test.exs`
Expected: 1 test, 0 failures

**Step 3: Commit**

```bash
git add test/strategy_spec/integration_test.exs
git commit -m "test: add spec-to-runner integration test (AC-9)"
```

---

## Phase 3: Volume-Aware Order Filtering

### Task 13: Volume Filter Module

**Files:**
- Create: `lib/cripto_trader/strategy_spec/volume_filter.ex`
- Create: `test/strategy_spec/volume_filter_test.exs`

**Step 1: Write the failing test**

```elixir
# test/strategy_spec/volume_filter_test.exs
defmodule CriptoTrader.StrategySpec.VolumeFilterTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.StrategySpec.VolumeFilter

  describe "filter/3" do
    test "passes order when volume is sufficient" do
      order = %{symbol: "BTCUSDT", side: "BUY", quantity: 0.01}
      candle = %{volume: "1000.0", close: "50000.0"}
      risk = %{min_candle_volume: 100.0, max_fill_ratio: 0.05}

      assert {:ok, filtered, context} = VolumeFilter.filter(order, candle, risk)
      assert filtered.quantity == 0.01
      assert context.skipped == false
    end

    test "skips order when candle volume below minimum" do
      order = %{symbol: "BTCUSDT", side: "BUY", quantity: 0.01}
      candle = %{volume: "5.0", close: "50000.0"}
      risk = %{min_candle_volume: 100.0, max_fill_ratio: 0.05}

      assert {:skip, context} = VolumeFilter.filter(order, candle, risk)
      assert context.skipped == true
      assert context.reason == :low_volume
    end

    test "reduces quantity when exceeding fill ratio" do
      order = %{symbol: "BTCUSDT", side: "BUY", quantity: 10.0}
      candle = %{volume: "100.0", close: "50000.0"}
      risk = %{min_candle_volume: nil, max_fill_ratio: 0.05}

      assert {:ok, filtered, context} = VolumeFilter.filter(order, candle, risk)
      # Max allowed: 100 * 0.05 = 5.0
      assert filtered.quantity == 5.0
      assert context.original_quantity == 10.0
    end

    test "passes through when no volume constraints" do
      order = %{symbol: "BTCUSDT", side: "BUY", quantity: 1.0}
      candle = %{volume: "100.0", close: "50000.0"}
      risk = %{min_candle_volume: nil, max_fill_ratio: nil}

      assert {:ok, filtered, _context} = VolumeFilter.filter(order, candle, risk)
      assert filtered.quantity == 1.0
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/strategy_spec/volume_filter_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

```elixir
# lib/cripto_trader/strategy_spec/volume_filter.ex
defmodule CriptoTrader.StrategySpec.VolumeFilter do
  @moduledoc "Filters and adjusts orders based on candle volume for realistic execution."

  @spec filter(map(), map(), map()) ::
          {:ok, map(), map()} | {:skip, map()}
  def filter(order, candle, risk) do
    volume = parse_volume(candle)
    min_volume = risk[:min_candle_volume]
    max_fill_ratio = risk[:max_fill_ratio]

    context = %{
      candle_volume: volume,
      original_quantity: order.quantity,
      fill_ratio: if(volume > 0, do: order.quantity / volume, else: 1.0),
      slippage_estimate: 0.0,
      skipped: false,
      reason: nil
    }

    cond do
      min_volume && volume < min_volume ->
        {:skip, %{context | skipped: true, reason: :low_volume}}

      max_fill_ratio && volume > 0 && order.quantity / volume > max_fill_ratio ->
        adjusted_qty = Float.round(volume * max_fill_ratio, 8)
        adjusted_order = %{order | quantity: adjusted_qty}

        {:ok, adjusted_order,
         %{context | fill_ratio: max_fill_ratio, original_quantity: order.quantity}}

      true ->
        {:ok, order, context}
    end
  end

  defp parse_volume(candle) do
    val = Map.get(candle, :volume) || Map.get(candle, "volume")

    case val do
      n when is_number(n) -> n * 1.0
      s when is_binary(s) ->
        case Float.parse(s) do
          {f, _} -> f
          :error -> 0.0
        end
      _ -> 0.0
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/strategy_spec/volume_filter_test.exs`
Expected: 4 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/strategy_spec/volume_filter.ex test/strategy_spec/volume_filter_test.exs
git commit -m "feat: add volume-aware order filter (AC-20)"
```

---

## Phase 4: Phoenix + Ecto Bootstrap

### Task 14: Add Phoenix, Ecto, and Related Dependencies

**Files:**
- Modify: `mix.exs`

**Step 1: Update mix.exs deps**

Add to deps in `mix.exs`:

```elixir
{:phoenix, "~> 1.7"},
{:phoenix_ecto, "~> 4.5"},
{:ecto_sql, "~> 3.12"},
{:postgrex, ">= 0.0.0"},
{:phoenix_html, "~> 4.1"},
{:phoenix_live_view, "~> 1.0"},
{:phoenix_live_dashboard, "~> 0.8"},
{:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
{:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
{:heroicons, github: "tailwindlabs/heroicons", tag: "v2.1.1", sparse: "optimized", app: false, compile: false, depth: 1},
{:bcrypt_elixir, "~> 3.0"},
{:dns_cluster, "~> 0.1.1"}
```

**Step 2: Fetch deps**

Run: `mix deps.get`
Expected: All deps resolve

**Step 3: Commit**

```bash
git add mix.exs mix.lock
git commit -m "deps: add Phoenix, Ecto, LiveView, and related dependencies"
```

---

### Task 15: Phoenix Application Scaffold

Generate the Phoenix web layer structure. Since we're adding to an existing OTP app, we manually create the necessary files.

**Files:**
- Create: `lib/cripto_trader_web.ex` (web module macro)
- Create: `lib/cripto_trader_web/endpoint.ex`
- Create: `lib/cripto_trader_web/router.ex`
- Create: `lib/cripto_trader_web/components/layouts.ex`
- Create: `lib/cripto_trader_web/components/layouts/root.html.heex`
- Create: `lib/cripto_trader_web/components/layouts/app.html.heex`
- Create: `lib/cripto_trader/repo.ex`
- Modify: `lib/cripto_trader/application.ex` (add Repo + Endpoint to supervision tree)
- Modify: `config/config.exs` (add Phoenix + Ecto config)
- Create: `config/dev.exs`
- Create: `config/test.exs`
- Create: `config/prod.exs`

> **Note:** This task is larger than typical. The implementer should scaffold these files using `mix phx.new` as a reference for correct boilerplate structure, then adapt to the existing `cripto_trader` app. The key modifications are:

**Step 1: Create Repo module**

```elixir
# lib/cripto_trader/repo.ex
defmodule CriptoTrader.Repo do
  use Ecto.Repo,
    otp_app: :cripto_trader,
    adapter: Ecto.Adapters.Postgres
end
```

**Step 2: Create web module**

```elixir
# lib/cripto_trader_web.ex
defmodule CriptoTraderWeb do
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: CriptoTraderWeb.Layouts]
      import Plug.Conn
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {CriptoTraderWeb.Layouts, :app}
      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent
      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.Controller, only: [get_csrf_token: 0, view_module: 1, view_template: 1]
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.LiveView.Helpers
      alias Phoenix.LiveView.JS
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
```

**Step 3: Create Endpoint, Router, Layouts (standard Phoenix boilerplate)**

Follow standard Phoenix 1.7 structure. See Phoenix docs for exact boilerplate.

**Step 4: Update application.ex supervision tree**

Add to children list:
```elixir
CriptoTrader.Repo,
{Phoenix.PubSub, name: CriptoTrader.PubSub},
CriptoTraderWeb.Endpoint
```

**Step 5: Add database config to config files**

```elixir
# config/dev.exs
config :cripto_trader, CriptoTrader.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cripto_trader_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
```

**Step 6: Create and migrate database**

Run: `mix ecto.create`
Expected: Database created

**Step 7: Verify Phoenix starts**

Run: `mix phx.server`
Expected: Server starts on port 4000

**Step 8: Commit**

```bash
git add -A
git commit -m "feat: bootstrap Phoenix + Ecto into existing OTP app"
```

---

### Task 16: Database Migrations

Create Ecto migrations for all tables from the design document.

**Files:**
- Create: `priv/repo/migrations/TIMESTAMP_create_users.exs`
- Create: `priv/repo/migrations/TIMESTAMP_create_strategies.exs`
- Create: `priv/repo/migrations/TIMESTAMP_create_backtest_results.exs`
- Create: `priv/repo/migrations/TIMESTAMP_create_strategy_performance.exs`
- Create: `priv/repo/migrations/TIMESTAMP_create_trade_history.exs`
- Create: `priv/repo/migrations/TIMESTAMP_create_ai_requests.exs`

**Step 1: Generate migrations**

Run: `mix ecto.gen.migration create_users` (and so on for each table)

**Step 2: Write migration code**

Follow the schema defined in Section 8 of the design document. Use `jsonb` for spec, trade_log, equity_curve, config, preferences, volume_context columns. Create enum types for strategy_status, generation_method, ai_request_type.

**Step 3: Run migrations**

Run: `mix ecto.migrate`
Expected: All migrations run successfully

**Step 4: Commit**

```bash
git add priv/repo/migrations/
git commit -m "feat: add database migrations for all tables"
```

---

### Task 17: Ecto Schemas

**Files:**
- Create: `lib/cripto_trader/strategies/strategy.ex`
- Create: `lib/cripto_trader/strategies/backtest_result.ex`
- Create: `lib/cripto_trader/strategies/strategy_performance.ex`
- Create: `lib/cripto_trader/strategies/trade_history.ex`
- Create: `lib/cripto_trader/accounts/user.ex`
- Create: `lib/cripto_trader/ai/ai_request.ex`

Follow standard Ecto schema patterns. Each schema maps to its database table with `field`, `belongs_to`, `has_many` associations. Strategy has `parent_id` self-referential FK.

**Step 1: Write schemas matching the migration columns**

**Step 2: Write basic context modules**

- Create: `lib/cripto_trader/strategies.ex` (context for CRUD operations)
- Create: `lib/cripto_trader/accounts.ex` (context for user auth)

**Step 3: Run tests**

Run: `mix test`
Expected: All existing tests still pass

**Step 4: Commit**

```bash
git add lib/cripto_trader/strategies/ lib/cripto_trader/accounts/ lib/cripto_trader/ai/
git commit -m "feat: add Ecto schemas and context modules"
```

---

## Phase 5: Claude API Client

### Task 18: AI Client Module

**Files:**
- Create: `lib/cripto_trader/ai/client.ex`
- Create: `test/ai/client_test.exs`

**Step 1: Write the failing test**

```elixir
# test/ai/client_test.exs
defmodule CriptoTrader.AI.ClientTest do
  use ExUnit.Case, async: true

  alias CriptoTrader.AI.Client

  describe "generate_strategy/2" do
    test "returns a valid strategy spec from mock response" do
      mock_request_fn = fn _req ->
        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "name" => "create_strategy_spec",
                 "input" => %{
                   "name" => "test_strategy",
                   "symbols" => ["BTCUSDT"],
                   "interval" => "15m",
                   "indicators" => [
                     %{"type" => "sma", "period" => 9, "source" => "close", "as" => "sma_fast"}
                   ],
                   "entry_rules" => [
                     %{"condition" => "sma_fast > 50000", "action" => "BUY"}
                   ],
                   "exit_rules" => [
                     %{"condition" => "sma_fast < 50000", "action" => "SELL"}
                   ],
                   "risk" => %{"position_size_pct" => 0.02}
                 }
               }
             ]
           }
         }}
      end

      goal = "Trade BTCUSDT on 15m using SMA crossover"

      assert {:ok, spec} =
               Client.generate_strategy(goal, %{},
                 request_fn: mock_request_fn,
                 api_key: "test-key"
               )

      assert spec["name"] == "test_strategy"
      assert spec["symbols"] == ["BTCUSDT"]
    end

    test "returns error when API fails" do
      mock_request_fn = fn _req -> {:error, :timeout} end

      assert {:error, _} =
               Client.generate_strategy("test", %{},
                 request_fn: mock_request_fn,
                 api_key: "test-key"
               )
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/ai/client_test.exs`
Expected: FAIL

**Step 3: Write minimal implementation**

The client calls Claude API with tool_use to get structured JSON output. Uses the existing `Req` library (already a dep). The tool definition includes the full strategy spec JSON schema so Claude returns valid structured output.

Key functions:
- `generate_strategy(goal, constraints, opts)` → `{:ok, spec_map}`
- `improve_strategy(current_spec, backtest_results, opts)` → `{:ok, new_spec_map}`
- `explain_strategy(spec, opts)` → `{:ok, explanation_string}`

API key from `ANTHROPIC_API_KEY` env var, model from `CLAUDE_MODEL` env var (default `claude-sonnet-4-6`).

**Step 4: Run test to verify it passes**

Run: `mix test test/ai/client_test.exs`
Expected: 2 tests, 0 failures

**Step 5: Commit**

```bash
git add lib/cripto_trader/ai/client.ex test/ai/client_test.exs
git commit -m "feat: add Claude API client for strategy generation (AC-5)"
```

---

## Phase 6: Binance WebSocket & Live Evaluator

### Task 19: Binance WebSocket Client

**Files:**
- Create: `lib/cripto_trader/market_data/websocket.ex`
- Create: `test/market_data/websocket_test.exs`

GenServer that connects to Binance kline WebSocket streams and broadcasts candle close events via PubSub. Uses the `websock_client` library (add to deps).

Add dep: `{:websock_adapter, "~> 0.5"}` and `{:mint_web_socket, "~> 1.0"}`

Key behaviors:
- Subscribe to `{symbol, interval}` pairs
- Reconnect with exponential backoff on disconnect
- Broadcast on PubSub topic `"market:{symbol}:{interval}"` when a candle closes (`k.x == true` in Binance WebSocket payload)

**Step 1-5:** Test with mock WebSocket, implement GenServer, commit.

```bash
git commit -m "feat: add Binance WebSocket client for real-time kline data (AC-16)"
```

---

### Task 20: Live Strategy Evaluator

**Files:**
- Create: `lib/cripto_trader/strategy/live_evaluator.ex`
- Create: `lib/cripto_trader/strategy/supervisor.ex`
- Create: `test/strategy/live_evaluator_test.exs`

GenServer per active strategy that:
1. Subscribes to `"market:{symbol}:{interval}"` PubSub topics
2. Maintains candle history buffer
3. Computes indicators + evaluates spec rules on each candle close
4. Applies volume filter
5. Broadcasts signal to `"signal:strategy_{id}"` before order execution
6. Routes orders to `OrderManager`

`CriptoTrader.Strategy.Supervisor` is a `DynamicSupervisor` that starts/stops `LiveEvaluator` processes.

**Step 1-5:** Test with mock PubSub events, implement GenServer, commit.

```bash
git commit -m "feat: add live strategy evaluator with real-time signal emission (AC-17)"
```

---

## Phase 7: Strategy State Machine

### Task 21: Strategy State Machine Module

**Files:**
- Create: `lib/cripto_trader/strategies/state_machine.ex`
- Create: `test/strategies/state_machine_test.exs`

Pure function: `transition(strategy, action, context) -> {:ok, new_status} | {:error, reason}`

Implements all transition rules and guards from the design doc Section 9.

**Step 1-5:** Test all valid transitions + guard violations, implement, commit.

```bash
git commit -m "feat: add strategy lifecycle state machine (AC-11)"
```

---

## Phase 8: LiveView Pages

### Task 22: Strategy Dashboard Page

**Files:**
- Create: `lib/cripto_trader_web/live/strategy_live/index.ex`
- Create: `lib/cripto_trader_web/live/strategy_live/index.html.heex`

Card grid with status filters, "Generate New Strategy" button.

---

### Task 23: Strategy Generator Page

**Files:**
- Create: `lib/cripto_trader_web/live/strategy_live/new.ex`
- Create: `lib/cripto_trader_web/live/strategy_live/new.html.heex`

Goal form → triggers AI generation → shows spinner → redirects to detail.

---

### Task 24: Strategy Detail Page

**Files:**
- Create: `lib/cripto_trader_web/live/strategy_live/show.ex`
- Create: `lib/cripto_trader_web/live/strategy_live/show.html.heex`

Tabs: Overview, Backtest, Performance, Comparison. Equity curve chart via Lightweight Charts JS hook.

---

### Task 25: Trading Monitor Page

**Files:**
- Create: `lib/cripto_trader_web/live/trading_live/monitor.ex`
- Create: `lib/cripto_trader_web/live/trading_live/monitor.html.heex`

Real-time signal feed via PubSub. Active strategies with live PnL. Kill switch button.

---

### Task 26: Trade History Page

**Files:**
- Create: `lib/cripto_trader_web/live/history_live/index.ex`
- Create: `lib/cripto_trader_web/live/history_live/index.html.heex`

Paginated table with filters. CSV export.

---

### Task 27: Settings Page

**Files:**
- Create: `lib/cripto_trader_web/live/settings_live/index.ex`
- Create: `lib/cripto_trader_web/live/settings_live/index.html.heex`

API key management, risk defaults, AI budget display.

---

### Task 28: User Authentication

**Files:**
- Create: `lib/cripto_trader_web/live/user_live/login.ex`
- Modify: `lib/cripto_trader_web/router.ex`

Use `bcrypt_elixir` for password hashing. Session-based auth. Protect all `/strategies`, `/trading`, `/history`, `/settings` routes.

---

## Phase 9: Performance Tracking

### Task 29: Performance Tracker Module

**Files:**
- Create: `lib/cripto_trader/performance/tracker.ex`
- Create: `test/performance/tracker_test.exs`

Computes daily rollup metrics from `trade_history` records and stores to `strategy_performance` table.

Metrics: PnL, win rate, max drawdown, Sharpe ratio, Sortino ratio, profit factor, avg win/loss, volume-skipped signal count.

**Step 1-5:** Test metric computation with known trade sequences, implement, commit.

```bash
git commit -m "feat: add daily performance tracker (AC-22)"
```

---

## Phase 10: Final Integration & Acceptance

### Task 30: Wire Everything Together

- Update router with all routes
- Add PubSub broadcasts in all event-producing modules
- Verify all 24 acceptance criteria pass
- Run full test suite

Run: `mix test`
Expected: All tests pass

```bash
git commit -m "feat: complete strategy builder integration"
```

---

## Dependency Order

```
Phase 1 (Tasks 1-8): Indicator Library         — no dependencies
Phase 2 (Tasks 9-12): Spec Engine               — depends on Phase 1
Phase 3 (Task 13): Volume Filter                — no dependencies
Phase 4 (Tasks 14-17): Phoenix + DB Bootstrap   — no dependencies
Phase 5 (Task 18): Claude API Client            — depends on Phase 2 (for spec validation)
Phase 6 (Tasks 19-20): WebSocket + Evaluator    — depends on Phases 1, 2, 3, 4
Phase 7 (Task 21): State Machine                — depends on Phase 4
Phase 8 (Tasks 22-28): LiveView Pages           — depends on Phases 4, 5, 6, 7
Phase 9 (Task 29): Performance Tracker          — depends on Phase 4
Phase 10 (Task 30): Final Integration           — depends on all

Parallelizable: Phase 1 + Phase 3 + Phase 4 can run concurrently.
```
