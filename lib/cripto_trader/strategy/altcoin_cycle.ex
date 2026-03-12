defmodule CriptoTrader.Strategy.AltcoinCycle do
  @moduledoc """
  Macro cycle strategy: uses BTC's cycle phase as entry/exit signal while
  deploying capital into altcoins.

  BTC (identified by `btc_symbol`) runs the same 3-phase state machine as
  CycleAth but never generates orders. When BTC drops below `entry_ath`,
  a buy signal is set and each altcoin buys on its own next candle.

  Each altcoin independently trails from its own peak using `alt_trail_pct`.
  When BTC fires its exit signal, any remaining alt positions are sold
  immediately on their next event.

  Usage:
    AltcoinCycle.new_state(symbols,
      entry_ath: 20_000.0,
      initial_ath: 69_044.0,
      trail_pct: 0.25,
      alt_trail_pct: 0.35,
      quote_per_trade: 10_000.0
    )
  """

  @default_trail_pct 0.25
  @default_alt_trail_pct 0.35
  @default_quote_per_trade 1_000.0
  @default_btc_symbol "BTCUSDC"

  @type btc_phase :: :watching | :in_position | :trailing | :exited

  @type alt_position :: %{quantity: float(), peak: float()}

  @type state :: %{
          entry_ath: float(),
          initial_ath: float(),
          trail_pct: float(),
          alt_trail_pct: float(),
          quote_per_trade: float(),
          btc_symbol: String.t(),
          alt_symbols: MapSet.t(),
          btc_phase: btc_phase(),
          btc_ath_seen: float(),
          btc_trail_high: float(),
          buy_signal: boolean(),
          btc_exit_signal: boolean(),
          alt_positions: %{optional(String.t()) => alt_position()}
        }

  @spec new_state([String.t()], keyword()) :: state()
  def new_state(symbols, opts \\ []) do
    btc_symbol = Keyword.get(opts, :btc_symbol, @default_btc_symbol)
    alt_symbols = symbols |> Enum.reject(&(&1 == btc_symbol)) |> MapSet.new()

    %{
      entry_ath: Keyword.get(opts, :entry_ath, 0.0),
      initial_ath: Keyword.get(opts, :initial_ath, 0.0),
      trail_pct: Keyword.get(opts, :trail_pct, @default_trail_pct),
      alt_trail_pct: Keyword.get(opts, :alt_trail_pct, @default_alt_trail_pct),
      quote_per_trade: Keyword.get(opts, :quote_per_trade, @default_quote_per_trade),
      btc_symbol: btc_symbol,
      alt_symbols: alt_symbols,
      btc_phase: :watching,
      btc_ath_seen: Keyword.get(opts, :initial_ath, 0.0),
      btc_trail_high: 0.0,
      buy_signal: false,
      btc_exit_signal: false,
      alt_positions: %{}
    }
  end

  @spec signal(map(), state()) :: {[map()], state()}
  def signal(%{symbol: symbol, candle: candle}, state) do
    close = parse_number(candle[:close] || candle["close"])

    if close <= 0 do
      {[], state}
    else
      cond do
        symbol == state.btc_symbol ->
          handle_btc(close, state)

        MapSet.member?(state.alt_symbols, symbol) ->
          handle_alt(symbol, close, state)

        true ->
          {[], state}
      end
    end
  end

  def signal(_event, state), do: {[], state}

  # --- BTC state machine (no orders emitted) ---

  defp handle_btc(close, state) do
    prev_ath_seen = state.btc_ath_seen
    state = %{state | btc_ath_seen: max(state.btc_ath_seen, close)}

    state =
      case state.btc_phase do
        :watching ->
          if state.entry_ath > 0 && close < state.entry_ath do
            %{state | btc_phase: :in_position, buy_signal: true}
          else
            state
          end

        :in_position ->
          if close > state.initial_ath && close > prev_ath_seen do
            %{state | btc_phase: :trailing, btc_trail_high: close}
          else
            state
          end

        :trailing ->
          new_trail_high = max(state.btc_trail_high, close)
          state = %{state | btc_trail_high: new_trail_high}

          if close < new_trail_high * (1.0 - state.trail_pct) do
            %{state | btc_phase: :exited, btc_exit_signal: true}
          else
            state
          end

        :exited ->
          state
      end

    {[], state}
  end

  # --- Altcoin logic ---

  defp handle_alt(symbol, close, state) do
    already_in = Map.has_key?(state.alt_positions, symbol)

    cond do
      state.btc_exit_signal && already_in ->
        sell_alt(symbol, state)

      state.btc_exit_signal ->
        # BTC has exited — no new buys
        {[], state}

      already_in ->
        update_alt_trailing(symbol, close, state)

      state.buy_signal ->
        buy_alt(symbol, close, state)

      true ->
        {[], state}
    end
  end

  defp buy_alt(symbol, close, state) do
    quantity = state.quote_per_trade / close
    order = %{symbol: symbol, side: "BUY", quantity: quantity}
    new_positions = Map.put(state.alt_positions, symbol, %{quantity: quantity, peak: close})
    {[order], %{state | alt_positions: new_positions}}
  end

  defp update_alt_trailing(symbol, close, state) do
    position = state.alt_positions[symbol]
    new_peak = max(position.peak, close)
    updated_position = %{position | peak: new_peak}

    if close < new_peak * (1.0 - state.alt_trail_pct) do
      sell_alt(symbol, %{state | alt_positions: Map.put(state.alt_positions, symbol, updated_position)})
    else
      new_positions = Map.put(state.alt_positions, symbol, updated_position)
      {[], %{state | alt_positions: new_positions}}
    end
  end

  defp sell_alt(symbol, state) do
    case Map.fetch(state.alt_positions, symbol) do
      {:ok, position} ->
        order = %{symbol: symbol, side: "SELL", quantity: position.quantity}
        new_positions = Map.delete(state.alt_positions, symbol)
        {[order], %{state | alt_positions: new_positions}}

      :error ->
        {[], state}
    end
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
