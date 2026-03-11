defmodule CriptoTrader.Strategy.CycleDca do
  @moduledoc """
  Macro cycle DCA strategy: splits the buy into N tranches as price falls
  through the previous cycle ATH zone. Each level is a multiplier of
  prev_ath (e.g. [1.0, 0.85, 0.70] = at prev_ath, -15%, -30%).

  **Exit:** Trailing stop activates once close >= avg_entry * multiplier.
  Total position (all tranches) is sold at once on trailing stop.
  """

  @default_multiplier 2.0
  @default_trail_pct 0.20
  @default_quote_per_trade 1000.0
  @default_dca_levels [1.0, 0.85, 0.70]

  @type tranche :: %{entry_price: float(), quantity: float()}

  @type sym_state :: %{
          phase: :watching | :in_position | :trailing,
          entries_done: non_neg_integer(),
          tranches: [tranche()],
          trail_high: float() | nil
        }

  @type state :: %{
          multiplier: float(),
          trail_pct: float(),
          quote_per_trade: float(),
          dca_levels: [float()],
          ath: %{optional(String.t()) => float()},
          prev_ath: %{optional(String.t()) => float()},
          per_symbol: %{optional(String.t()) => sym_state()}
        }

  @spec new_state([String.t()], keyword()) :: state()
  def new_state(_symbols, opts \\ []) do
    %{
      multiplier: Keyword.get(opts, :multiplier, @default_multiplier),
      trail_pct: Keyword.get(opts, :trail_pct, @default_trail_pct),
      quote_per_trade: Keyword.get(opts, :quote_per_trade, @default_quote_per_trade),
      dca_levels: Keyword.get(opts, :dca_levels, @default_dca_levels),
      ath: %{},
      prev_ath: %{},
      per_symbol: %{}
    }
  end

  @spec signal(map(), state()) :: {[map()], state()}
  def signal(%{symbol: symbol, candle: candle}, state) do
    close = parse_number(candle[:close] || candle["close"])

    if close <= 0 do
      {[], state}
    else
      state = update_ath(symbol, close, state)
      evaluate(symbol, close, state)
    end
  end

  def signal(_event, state), do: {[], state}

  defp update_ath(symbol, close, state) do
    current_ath = Map.get(state.ath, symbol)

    cond do
      current_ath == nil ->
        %{state | ath: Map.put(state.ath, symbol, close)}

      close > current_ath ->
        state
        |> Map.update!(:ath, &Map.put(&1, symbol, close))
        |> Map.update!(:prev_ath, &Map.put(&1, symbol, current_ath))

      true ->
        state
    end
  end

  defp get_sym(state, symbol) do
    Map.get(state.per_symbol, symbol, %{
      phase: :watching,
      entries_done: 0,
      tranches: [],
      trail_high: nil
    })
  end

  defp put_sym(state, symbol, ss) do
    Map.update!(state, :per_symbol, &Map.put(&1, symbol, ss))
  end

  defp evaluate(symbol, close, state) do
    prev_ath = Map.get(state.prev_ath, symbol)
    ss = get_sym(state, symbol)

    case ss.phase do
      :watching ->
        maybe_dca_buy(symbol, close, prev_ath, state, ss)

      :in_position ->
        # Check next DCA level first
        {orders, state} = maybe_dca_buy(symbol, close, prev_ath, state, ss)
        # Re-read sym_state after potential buy
        ss2 = get_sym(state, symbol)
        avg = avg_entry_price(ss2.tranches)

        if avg > 0 && close >= avg * state.multiplier do
          ss3 = %{ss2 | phase: :trailing, trail_high: close}
          {orders, put_sym(state, symbol, ss3)}
        else
          {orders, state}
        end

      :trailing ->
        trail_high = ss.trail_high || close
        new_trail = max(trail_high, close)
        state = put_sym(state, symbol, %{ss | trail_high: new_trail})

        if close < new_trail * (1.0 - state.trail_pct) do
          sell_all(symbol, close, state)
        else
          {[], state}
        end
    end
  end

  defp maybe_dca_buy(symbol, close, prev_ath, state, ss) do
    idx = ss.entries_done

    if prev_ath == nil || idx >= length(state.dca_levels) do
      {[], state}
    else
      level_mult = Enum.at(state.dca_levels, idx)
      trigger = prev_ath * level_mult

      if close <= trigger do
        tranche_quote = state.quote_per_trade / length(state.dca_levels)
        quantity = tranche_quote / close
        order = %{symbol: symbol, side: "BUY", quantity: quantity}
        new_tranche = %{entry_price: close, quantity: quantity}
        new_ss = %{ss | phase: :in_position, entries_done: idx + 1, tranches: [new_tranche | ss.tranches]}
        {[order], put_sym(state, symbol, new_ss)}
      else
        {[], state}
      end
    end
  end

  defp sell_all(symbol, _close, state) do
    ss = get_sym(state, symbol)
    total_qty = ss.tranches |> Enum.map(& &1.quantity) |> Enum.sum()

    if total_qty > 0 do
      order = %{symbol: symbol, side: "SELL", quantity: total_qty}
      new_ss = %{ss | phase: :watching, entries_done: 0, tranches: [], trail_high: nil}
      {[order], put_sym(state, symbol, new_ss)}
    else
      {[], state}
    end
  end

  defp avg_entry_price([]), do: 0.0

  defp avg_entry_price(tranches) do
    total_cost = Enum.sum(Enum.map(tranches, fn t -> t.entry_price * t.quantity end))
    total_qty = Enum.sum(Enum.map(tranches, & &1.quantity))
    if total_qty > 0, do: total_cost / total_qty, else: 0.0
  end

  defp parse_number(value) when is_float(value), do: value
  defp parse_number(value) when is_integer(value), do: value * 1.0

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {num, _} -> num
      :error -> 0.0
    end
  end

  defp parse_number(_), do: 0.0
end
