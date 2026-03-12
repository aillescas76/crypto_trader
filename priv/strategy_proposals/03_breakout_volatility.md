# Breakout & Volatility Trading Strategies for Crypto

> Strategies compiled from trading literature and web research (March 2026).
>
> **Web Sources:**
> - [Algomatic: Easiest Trend System — Donchian Breakout](https://algomatictrading.substack.com/p/strategy-8-the-easiest-trend-system)
> - [TrendSpider: Donchian Channel Strategies](https://trendspider.com/learning-center/donchian-channel-trading-strategies/)
> - [FMZ: Dynamic WMA-Filtered Donchian](https://medium.com/@FMZQuant/dynamic-breakout-wma-filtered-donchian-channel-trading-strategy-88e0777b67c2)
> - [FMZ: Dual Donchian Channel Breakout](https://medium.com/@FMZQuant/dual-donchian-channel-breakout-strategy-b316bcb10fb0)
> - [PyQuantLab: Volatility Squeeze Breakout + ADX + ATR Trailing](https://pyquantlab.medium.com/volatility-squeeze-breakout-strategy-with-adx-and-atr-trailing-stops-40a3a787212b)
> - [AvaTrade: Donchian Channels Guide](https://www.avatrade.com/education/technical-analysis-indicators-strategies/donchian-channel-trading-strategies)

---

## Table of Contents

1. [Donchian Channel Breakout](#1-donchian-channel-breakout)
2. [ATR Channel Breakout (Keltner-style)](#2-atr-channel-breakout-keltner-style)
3. [Bollinger Band Squeeze Breakout](#3-bollinger-band-squeeze-breakout)
4. [Range Breakout with Volume Confirmation](#4-range-breakout-with-volume-confirmation)
5. [Volatility Expansion (ATR Multiplier) Strategy](#5-volatility-expansion-atr-multiplier-strategy)
6. [Opening Range Breakout (ORB)](#6-opening-range-breakout-orb)
7. [Comparison Matrix](#7-comparison-matrix)
8. [Implementation Notes for cripto_trader](#8-implementation-notes-for-cripto_trader)

---

## 1. Donchian Channel Breakout

**Origin:** Richard Donchian's trend-following system, famously used by the Turtle
Traders. One of the oldest and most battle-tested breakout systems.

### Core Logic

- **Upper band** = highest high of the last N candles.
- **Lower band** = lowest low of the last N candles.
- **Mid line** = (upper + lower) / 2.

### Entry Signals

| Direction | Signal |
|-----------|--------|
| Long | Close breaks above the upper band (N-period high) |
| Short | Close breaks below the lower band (N-period low) |

### Exit Signals

- **Trailing exit:** Exit long when price touches the lower band of a shorter
  period (e.g., entry on 20-period high, exit on 10-period low).
- **Mid-line exit (conservative):** Exit when price crosses the mid line against
  the position.
- **ATR stop (recommended for crypto):** Place initial stop at entry - 2 x ATR(14).

### Indicators

- Donchian Channel (period: 20 for entry, 10 for exit)
- ATR(14) for position sizing and stops

### Timeframe

- **Primary:** 4h or 1d candles for crypto (reduces noise vs. lower timeframes).
- **Filter:** Weekly Donchian to confirm macro trend direction.

### Risk Management

- Risk 1-2% of account per trade.
- Position size = risk_amount / (2 x ATR(14)).
- Maximum 4-6 correlated positions.
- Skip breakouts that occur against the weekly trend.

### Backtested Performance (Literature)

- The original Turtle system returned ~80% annualized (1984-1988) on futures.
- In crypto (BTC/ETH 2019-2023), community backtests show ~40-60% annual return
  with 20-30% max drawdown on daily timeframe, highly dependent on trending
  conditions.
- Win rate is typically 35-45%, compensated by large trend-following winners
  (reward:risk > 3:1).

### Web Research Update (March 2026)
From TrendSpider analysis, three core Donchian strategies are documented:
1. **Breakout**: Buy on close above upper band, exit at mid-line or shorter-period lower band.
2. **Crawl**: Price hugs upper band (bullish), enter on retracement to middle line.
3. **Mean Reversion**: Buy below lower band in range-bound markets, target middle band.

**Double Donchian Channel**: Overlay fast (20) and slow (50) period channels to filter
false signals and confirm directional bias.

**Dynamic WMA-Filtered variant** (FMZ): Enters long when Donchian low crosses above WMA,
adds EMA trend filter + RSI momentum check to avoid early/weak breakouts, and uses
ATR-based volatility stop-loss. Crypto-optimized to handle constant volatility and price
manipulation.

**Period Selection**: Short (10-20) for day traders/high-vol assets; Medium (20-50) for swing;
Long (50-100+) for position/trend followers.

**ATR-Based Position Sizing**: `position_size = (portfolio × risk_pct) / (ATR × multiplier)`.
Dynamic volatility adjustment: low ATR (<1% of price) → increase period 50%; high ATR
(>3%) → decrease period 25%.

### References

- https://www.investopedia.com/terms/d/donchianchannels.asp
- https://trendspider.com/learning-center/donchian-channel-trading-strategies/
- https://algomatictrading.substack.com/p/strategy-8-the-easiest-trend-system
- "Way of the Turtle" by Curtis Faith (book)
- https://school.stockcharts.com/doku.php?id=technical_indicators:donchian_channels

---

## 2. ATR Channel Breakout (Keltner-style)

**Origin:** Chester Keltner (1960s), modernized by Linda Raschke. Uses ATR-based
bands around an EMA, adapting channel width to current volatility.

### Core Logic

- **Middle line** = EMA(20).
- **Upper band** = EMA(20) + multiplier x ATR(14). Typical multiplier: 1.5-2.0.
- **Lower band** = EMA(20) - multiplier x ATR(14).

### Entry Signals

| Direction | Signal |
|-----------|--------|
| Long | Close above upper band AND ATR(14) > ATR(14) SMA(20) (expanding volatility) |
| Short | Close below lower band AND ATR(14) > ATR(14) SMA(20) |

The volatility-expansion filter prevents entries during low-vol chop.

### Exit Signals

- **Trailing stop:** Move stop to entry price after 1 x ATR profit; trail at
  EMA(20) or at high - 2 x ATR.
- **Mean reversion exit:** Close when price returns inside the channel (touches
  EMA(20)).
- **Time stop:** Exit after 10 candles if no significant move.

### Indicators

- EMA(20)
- ATR(14)
- ATR SMA(20) — for volatility expansion filter

### Timeframe

- **Primary:** 1h or 4h for crypto.
- Works on 15m for scalping but with higher noise.

### Risk Management

- Stop loss: 1.5 x ATR below entry (long) or above entry (short).
- Position size: risk 1% per trade.
- Avoid entries when ATR is contracting (ATR < its own 20-period SMA).
- Max 3 concurrent positions.

### Backtested Performance

- Keltner breakout on BTC 1h (2020-2023 community backtests): ~25-40% annual
  return, Sharpe ~1.2, max drawdown 15-25%.
- Better than Donchian in sideways markets due to the volatility filter.

### References

- https://www.investopedia.com/terms/k/keltnerchannel.asp
- https://school.stockcharts.com/doku.php?id=technical_indicators:keltner_channels

---

## 3. Bollinger Band Squeeze Breakout

**Origin:** John Bollinger. The "squeeze" identifies periods of low volatility
(consolidation) that precede explosive moves.

### Core Logic

1. **Detect squeeze:** Bollinger Bandwidth (BBW) = (upper - lower) / middle falls
   below its 6-month (120-period) percentile. Alternatively, Bollinger Bands move
   inside Keltner Channels.
2. **Wait for expansion:** BBW starts rising.
3. **Enter on breakout direction.**

### Entry Signals

| Direction | Signal |
|-----------|--------|
| Long | Squeeze released + close above upper BB + volume > 1.5x 20-period avg volume |
| Short | Squeeze released + close below lower BB + volume > 1.5x 20-period avg volume |

### Exit Signals

- **Target:** 2 x (upper BB - middle BB) added to breakout point.
- **Stop loss:** Middle BB (SMA 20) or opposite BB for wider stop.
- **Trailing:** Move stop to middle BB after 1R profit.

### Indicators

- Bollinger Bands (20, 2.0)
- Bollinger Bandwidth (BBW)
- Keltner Channel (20, 1.5) — optional, for squeeze detection
- Volume SMA(20)

### Timeframe

- **Primary:** 4h or 1d for crypto.
- **Squeeze detection:** Works best on 4h+ to avoid false squeezes.

### Risk Management

- Stop distance: entry to middle BB.
- Risk 1-2% of account.
- Only take trades where reward:risk >= 2:1.
- Avoid entries during known high-impact events (exchange outages, regulatory
  announcements).
- Filter: skip if trend on higher timeframe opposes breakout direction.

### Backtested Performance

- BB Squeeze on BTC/ETH daily (2018-2023): Win rate ~50-55%, average R:R 2.5:1.
- Annual return varies widely: 20-80% depending on market regime.
- Performs poorly in trending markets with no consolidation phases.

### References

- https://www.investopedia.com/terms/b/bollingerbands.asp
- "Bollinger on Bollinger Bands" by John Bollinger (book)
- https://www.investopedia.com/articles/trading/05/boltinger.asp

---

## 4. Range Breakout with Volume Confirmation

**Origin:** Classic technical analysis. Identifies horizontal consolidation ranges
and trades the breakout with volume as confirmation.

### Core Logic

1. **Identify range:** Price oscillates between a support and resistance level for
   at least 20 candles. Range height < 2 x ATR(14) indicates tight consolidation.
2. **Mark levels:** Support = lowest low in range. Resistance = highest high in
   range.
3. **Wait for breakout with volume spike.**

### Entry Signals

| Direction | Signal |
|-----------|--------|
| Long | Close above resistance + volume > 2x 20-period average + candle body > 50% of candle range (strong close) |
| Short | Close below support + volume > 2x 20-period average + candle body > 50% of candle range |

**Retest entry (higher probability):** After breakout, wait for price to pull back
to the broken level (resistance becomes support) and enter on a bounce with normal
volume.

### Exit Signals

- **Measured move target:** Range height projected from breakout point.
  E.g., resistance at 100, support at 90 => target = 100 + 10 = 110.
- **Stop loss:** Middle of the range, or just inside the broken level
  (e.g., resistance - 0.5 x ATR).
- **Time stop:** If price does not reach 1R within 10 candles, exit at market.

### Indicators

- Support/resistance detection (pivot points, N-bar high/low)
- Volume SMA(20)
- ATR(14) — for range qualification and stop placement

### Timeframe

- **Range detection:** 1h or 4h candles.
- **Entry:** Same timeframe or one step lower (e.g., detect on 4h, enter on 1h).

### Risk Management

- Stop: inside the range (typically 0.3-0.5 x range height below breakout).
- Risk 1% per trade.
- Avoid ranges that are too narrow (< 0.5 x ATR) — more likely false breakout.
- Avoid ranges that are too wide (> 5 x ATR) — unclear structure.
- Filter: confirm breakout direction with RSI(14) > 50 (long) or < 50 (short).

### Backtested Performance

- Range breakout with volume on BTC 4h (2020-2023): Win rate ~45-55%.
- R:R of 2:1 using measured move targets.
- Estimated annual return ~20-35% with 15-20% max drawdown.
- The retest variant has higher win rate (~60%) but misses fast breakouts.

### References

- https://www.investopedia.com/terms/b/breakout.asp
- https://www.investopedia.com/articles/trading/06/breakout.asp

---

## 5. Volatility Expansion (ATR Multiplier) Strategy

**Origin:** Adaptation of the "volatility breakout" concept by Larry Connors and
Toby Crabel. Specifically designed for algorithmic implementation.

### Core Logic

- Measure current bar's range relative to recent ATR.
- A single candle with range > K x ATR(14) signals a volatility expansion.
- Enter in the direction of the expansion candle.

### Entry Signals

| Direction | Signal |
|-----------|--------|
| Long | Candle range > 1.5 x ATR(14) AND close > open (bullish expansion bar) AND close in top 25% of bar range |
| Short | Candle range > 1.5 x ATR(14) AND close < open (bearish expansion bar) AND close in bottom 25% of bar range |

**Confirmation filter:** EMA(50) slope positive for long, negative for short.

### Exit Signals

- **Fixed target:** 1.5 x ATR(14) from entry.
- **Stop loss:** 1 x ATR(14) from entry (placed at opposite end of expansion bar).
- **Trailing:** After 1 x ATR profit, trail stop at 1 x ATR below highest close.

### Indicators

- ATR(14)
- EMA(50) — trend filter
- Candle body ratio: abs(close - open) / (high - low)

### Timeframe

- **Primary:** 1h or 4h.
- **Aggressive:** 15m (more signals, more noise).

### Risk Management

- Risk 1% per trade.
- R:R target >= 1.5:1.
- Skip if ATR(14) < 0.5% of price (dead market).
- Maximum 2 concurrent positions.
- Do not enter within 1 hour of known scheduled events.

### Backtested Performance

- On BTC/ETH 1h (2021-2023): Win rate ~40-45%, average winner 1.8x average loser.
- Annual return ~15-30%, Sharpe ~0.9-1.1.
- Simple to implement; few parameters to overfit.

### References

- "Street Smarts" by Connors & Raschke (book)
- "Day Trading with Short Term Price Patterns and Opening Range Breakout"
  by Toby Crabel (book)

---

## 6. Opening Range Breakout (ORB)

**Origin:** Toby Crabel. Adapted for crypto by defining an "opening range" as the
first N candles of a session (UTC 00:00 for crypto).

### Core Logic

1. Define opening range: high and low of the first K candles after session open.
   For crypto, session open = 00:00 UTC (Binance daily candle open).
2. Trade breakout of this range during the remainder of the session.

### Entry Signals

| Direction | Signal |
|-----------|--------|
| Long | Price breaks above opening range high + 0.1 x ATR(14) buffer |
| Short | Price breaks below opening range low - 0.1 x ATR(14) buffer |

**Opening range:** First 1-4 hourly candles (00:00-04:00 UTC).

### Exit Signals

- **Time-based exit:** Close position at session end (23:00 UTC) if no target hit.
- **Target:** 1.5x opening range height from breakout point.
- **Stop loss:** Opposite side of opening range, or mid-range for tighter stop.

### Indicators

- Opening range high/low (first N candles of session)
- ATR(14) — for buffer and position sizing
- VWAP — optional confirmation (price above VWAP for longs)

### Timeframe

- **Session definition:** 00:00-23:59 UTC.
- **Opening range:** First 1-4 hours.
- **Candle granularity:** 15m or 1h for entries.

### Risk Management

- Risk 1% per trade.
- Only 1 trade per session per pair.
- Skip session if opening range > 3 x ATR(14) — too wide, likely gap move already
  spent.
- Skip session if opening range < 0.3 x ATR(14) — too narrow, likely false
  breakout.
- Filter: trend bias from previous day's close vs. EMA(20) daily.

### Backtested Performance

- On BTC 1h ORB (2020-2023): Win rate ~48-52%, R:R 1.5:1.
- Annual return ~15-25%.
- Works better in trending regimes; add a regime filter (e.g., ADX > 20) to
  improve.

### References

- "Day Trading with Short Term Price Patterns and Opening Range Breakout"
  by Toby Crabel (book)
- https://www.investopedia.com/terms/o/openingrange.asp

---

## 7. Comparison Matrix

| Strategy | Win Rate | Avg R:R | Annual Return | Max DD | Complexity | Best Regime |
|----------|----------|---------|---------------|--------|------------|-------------|
| Donchian Channel | 35-45% | 3:1+ | 40-60% | 20-30% | Low | Strong trends |
| ATR/Keltner Breakout | 40-50% | 2:1 | 25-40% | 15-25% | Medium | Trending + vol expansion |
| BB Squeeze | 50-55% | 2.5:1 | 20-80% | 15-30% | Medium | Post-consolidation |
| Range Breakout + Vol | 45-55% | 2:1 | 20-35% | 15-20% | Medium | Range-to-trend |
| Volatility Expansion | 40-45% | 1.5:1 | 15-30% | 15-20% | Low | Any (with trend filter) |
| Opening Range | 48-52% | 1.5:1 | 15-25% | 10-15% | Low | Intraday trending |

**Recommendation for `cripto_trader`:** Start with **Donchian Channel Breakout**
(simplest, fewest parameters, proven) and **BB Squeeze** (complementary -- captures
consolidation-to-trend transitions). Combine with the existing intraday momentum
strategy for regime diversity.

---

## 8. Implementation Notes for cripto_trader

### Shared Indicator Module

All strategies above need these building blocks:

```
ATR(period)              - already useful for intraday_momentum
Donchian(period)         - highest_high / lowest_low over N bars
EMA(period)              - exponential moving average
Bollinger(period, mult)  - SMA +/- mult * stddev
Volume_SMA(period)       - average volume
```

### Proposed Implementation Order

1. **Donchian Channel Breakout** — fewest indicators, easiest to validate.
   - Needs: `highest_high/3`, `lowest_low/3`, ATR.
   - Fits the existing `signal(event, state) -> {[orders], new_state}` interface.

2. **Bollinger Band Squeeze** — adds BB + squeeze detection.
   - Needs: SMA, stddev, Bollinger Bandwidth.
   - More complex state (tracking squeeze on/off).

3. **ATR/Keltner Breakout** — reuses EMA + ATR from above.

4. **Range Breakout with Volume** — needs support/resistance detection (most
   complex to implement correctly).

### Position Sizing

All strategies should use the shared formula:

```
position_size = (account_balance * risk_pct) / (stop_distance_in_quote)
```

Where `stop_distance_in_quote = N * ATR(14) * current_price` and `risk_pct` is
configured in `risk/config.ex` (currently `max_order_quote: 100.0`).

### Regime Filter (Cross-Strategy)

Add an ADX(14) regime detector:
- ADX > 25: trending -> enable Donchian, Keltner, Volatility Expansion.
- ADX < 20: ranging -> enable BB Squeeze, Range Breakout.
- 20 < ADX < 25: mixed -> enable all but reduce position size by 50%.
