# Mean Reversion & Statistical Arbitrage Strategy Proposals

> Strategies compiled from quantitative trading literature, academic papers,
> and web research (March 2026). Live source URLs verified where possible.
>
> **Web Sources:**
> - [FMZ Multi-Factor Mean Reversion (StochRSI + BB)](https://www.fmz.com/lang/en/strategy/489893)
> - [SSRN: BB under Varying Market Regimes in BTC/USDT](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5775962)
> - [Stoic.ai Mean Reversion Guide](https://stoic.ai/blog/mean-reversion-trading-how-i-profit-from-crypto-market-overreactions/)
> - [QuantInsti Mean Reversion Building Blocks](https://blog.quantinsti.com/mean-reversion-strategies-introduction-building-blocks/)
> - [TradingView BTC Mean Reversion Script](https://www.tradingview.com/script/95JBkzXV-BTC-Mean-Reversion-RSI-Bollinger/)
> - [FMZ BB + ATR Dynamic Stop-Loss](https://www.fmz.com/lang/en/strategy/473125)
> - [EzAlgo: 6 Mean Reverting Strategies for 2025](https://www.ezalgo.ai/blog/mean-reverting-trading-strategies/)
> - [Reinforcement Learning for BTC Strategy Selection (2025)](https://www.tandfonline.com/doi/full/10.1080/23322039.2025.2594873)

---

## Table of Contents

1. [Bollinger Band Mean Reversion](#1-bollinger-band-mean-reversion)
2. [RSI Mean Reversion with Confirmation](#2-rsi-mean-reversion-with-confirmation)
3. [Bollinger + RSI Confluence Strategy](#3-bollinger--rsi-confluence-strategy)
4. [Z-Score Mean Reversion](#4-z-score-mean-reversion)
5. [Keltner Channel Squeeze Reversion](#5-keltner-channel-squeeze-reversion)
6. [Pairs Trading (Cointegration-Based Statistical Arbitrage)](#6-pairs-trading-cointegration-based-statistical-arbitrage)
7. [Triangular Crypto Arbitrage](#7-triangular-crypto-arbitrage)
8. [Cross-Exchange Statistical Arbitrage](#8-cross-exchange-statistical-arbitrage)
9. [Implementation Priority & Recommendations](#9-implementation-priority--recommendations)

---

## 1. Bollinger Band Mean Reversion

### Strategy Name
BB Mean Reversion (Classic)

### Core Logic
Price tends to revert to its moving average after touching or crossing Bollinger Band extremes. When price drops below the lower band, it is statistically extended and likely to revert upward; when it exceeds the upper band, it is extended and likely to revert downward.

### Entry Signals
- **Long entry:** Close crosses below lower Bollinger Band (SMA(20) - 2*StdDev) and the next candle closes back inside the bands.
- **Short/exit:** Close crosses above upper Bollinger Band (SMA(20) + 2*StdDev) and the next candle closes back inside.
- **Confirmation candle:** Wait for the re-entry candle (close back inside bands) to avoid catching falling knives.

### Exit Signals
- **Take profit:** Price reaches the middle band (SMA 20) -- this is the "mean" target.
- **Extended target:** Price reaches the opposite band (for aggressive traders).
- **Time-based exit:** If price hasn't reached target within N candles (e.g., 20 candles on the same timeframe), close the position.

### Indicators Used
- Simple Moving Average (SMA), period 20
- Standard Deviation, period 20
- Bollinger Bands (upper = SMA + 2*SD, lower = SMA - 2*SD)

### Timeframe
- **Primary:** 1H candles (best balance of signal frequency vs. noise for crypto)
- **Also viable:** 4H, 15m (shorter = more noise, longer = fewer signals)

### Risk Management
- **Stop loss:** 1.5x ATR(14) below entry, or close below lower band by more than 1 standard deviation (3-sigma event = trend, not reversion).
- **Position sizing:** Risk 1-2% of portfolio per trade.
- **Filter:** Do not trade when Bollinger Band Width (BBW) is expanding rapidly -- indicates trending, not ranging.
- **Max concurrent positions:** Limit to 3-5 across portfolio.

### Backtested Performance (Literature)
- Win rate: ~55-65% in ranging markets.
- Risk-reward: ~1:1.2 targeting the middle band.
- Sharpe ratio: ~0.8-1.2 on 1H BTC/USDT (2021-2024 range-bound periods).
- **Caveat:** Significantly underperforms in strong trends; must be paired with a trend filter.

### Web Research Update (March 2026)
From FMZ Quant Strategy #489893: A multi-factor system combining Stochastic RSI (length 14,
%K smoothing 3, %D smoothing 3) with BB (20, 2.0) on 5-min candles uses entry thresholds of
StochRSI < 0.1 for longs and > 0.9 for shorts, with exits at 0.2 and 0.8 respectively.
The original implementation **lacks functional stop-loss** — ATR-based stops must be added.

From SSRN paper (2025): Bollinger Bands mean reversion **outperforms breakout in ranging
regimes** but significantly underperforms during trending regimes on BTC/USDT. Regime
detection (e.g., ADX filter) is essential for production use.

### Sources
- Bollinger, J. (2001). *Bollinger on Bollinger Bands*. McGraw-Hill.
- https://www.investopedia.com/terms/b/bollingerbands.asp
- https://www.fmz.com/lang/en/strategy/489893
- https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5775962
- Connors, L. & Alvarez, C. (2009). *Short Term Trading Strategies That Work*. TradingMarkets.

---

## 2. RSI Mean Reversion with Confirmation

### Strategy Name
RSI Oversold/Overbought Reversion

### Core Logic
RSI (Relative Strength Index) measures momentum on a 0-100 scale. Extreme readings (below 30 = oversold, above 70 = overbought) indicate price has moved too far too fast and is statistically likely to revert. The key improvement over naive RSI is waiting for the RSI itself to cross back through the threshold (confirmation).

### Entry Signals
- **Long entry:** RSI(14) drops below 30, then crosses back above 30 on the next candle.
- **Aggressive variant:** RSI(2) drops below 10, crosses back above 10 (Larry Connors' approach -- higher frequency, works well in crypto).
- **Short/exit:** RSI(14) rises above 70, then crosses back below 70.

### Exit Signals
- **Take profit:** RSI reaches 50 (neutral zone) -- exit the full position.
- **Scaled exit:** Exit 50% at RSI 50, remaining 50% at RSI 65.
- **Stop loss triggered:** If RSI makes a new low below 20 after entry (oversold deepening = likely trend).

### Indicators Used
- RSI (period 14 for standard, period 2 for Connors variant)
- Optional: SMA(200) as trend filter (only take long RSI signals when price > SMA 200)

### Timeframe
- **RSI(14):** 1H or 4H candles.
- **RSI(2):** 1H candles or even 15m for more signals.
- **Connors RSI(2):** Originally designed for daily bars on equities; crypto 1H bars approximate daily equity volatility.

### Risk Management
- **Stop loss:** Fixed percentage (2-3%) below entry price.
- **Trend filter:** Only take long signals when price is above SMA(200); only take short/sell signals when below SMA(200). This single filter dramatically improves performance.
- **Consecutive down days:** Connors' research shows buying after 3+ consecutive down closes with RSI(2) < 10 has the highest win rate.
- **Position sizing:** 1-2% risk per trade.

### Backtested Performance (Literature)
- **RSI(2) < 10 → buy:** Win rate 75-85% on S&P 500 daily (Connors, 2009). In crypto 1H, reported ~65-75% win rate due to higher volatility.
- **Average holding period:** 3-5 candles.
- **Risk-reward:** ~1:0.8 (high win rate compensates for slightly negative R:R).
- **Key risk:** Large losers during regime change (ranging to trending).

### Sources
- Connors, L. & Alvarez, C. (2009). *Short Term Trading Strategies That Work*. TradingMarkets.
- Wilder, J.W. (1978). *New Concepts in Technical Trading Systems*. Trend Research.
- https://www.investopedia.com/terms/r/rsi.asp
- https://school.stockcharts.com/doku.php?id=technical_indicators:relative_strength_index_rsi

---

## 3. Bollinger + RSI Confluence Strategy

### Strategy Name
BB-RSI Confluence Mean Reversion

### Core Logic
Combines Bollinger Bands and RSI to filter false signals. A mean reversion signal is only valid when BOTH indicators agree, dramatically reducing false entries in trending markets.

### Entry Signals
- **Long entry:** Price closes below lower Bollinger Band (20, 2) AND RSI(14) < 30. Enter when the next candle closes back inside the lower band AND RSI crosses back above 30.
- **Short/exit:** Price closes above upper Bollinger Band AND RSI(14) > 70. Enter short / exit long when next candle closes back inside AND RSI crosses back below 70.

### Exit Signals
- **Primary target:** Price reaches the middle Bollinger Band (SMA 20).
- **Secondary target:** RSI reaches 50.
- **Exit trigger:** Whichever target is hit first.
- **Time stop:** 30 candles max holding period.

### Indicators Used
- Bollinger Bands (SMA 20, 2 StdDev)
- RSI (period 14)
- Optional: Volume confirmation (volume spike > 1.5x average on the entry candle adds confidence)

### Timeframe
- **Optimal:** 1H candles for crypto spot trading.
- **Alternative:** 4H for lower frequency, higher conviction.

### Risk Management
- **Stop loss:** Close below lower BB by more than 1 additional standard deviation (i.e., price < SMA - 3*StdDev).
- **Position sizing:** 1% portfolio risk per trade.
- **Volatility filter:** Skip signals when BB Width percentile > 80th (market is trending, not reverting).
- **Correlation filter:** If BTC is in strong trend (ADX > 25), reduce position sizes on altcoins by 50%.

### Backtested Performance (Literature)
- Win rate: ~60-70% (higher than either indicator alone).
- Sharpe ratio: ~1.0-1.5 on 1H BTC/USDT ranging periods.
- Max drawdown: ~8-12% (vs. 15-20% for BB-only).
- **Critical insight:** The confluence filter reduces trade frequency by ~40% but improves risk-adjusted returns significantly.

### Sources
- Bollinger, J. (2001). *Bollinger on Bollinger Bands*. McGraw-Hill.
- https://www.tradingview.com/scripts/bollingerrsi/
- Kaufman, P. (2013). *Trading Systems and Methods* (5th ed.). Wiley.

---

## 4. Z-Score Mean Reversion

### Strategy Name
Z-Score Spread Reversion

### Core Logic
Calculate the z-score of the current price relative to a rolling window. The z-score measures how many standard deviations the price is from its rolling mean. When the z-score exceeds a threshold (e.g., +/- 2.0), the price is statistically extreme and likely to revert.

### Entry Signals
- **Long entry:** Z-score < -2.0 (price is 2 standard deviations below the rolling mean).
- **Short/exit:** Z-score > +2.0 (price is 2 standard deviations above the rolling mean).
- **Z-score calculation:** `z = (price - SMA(N)) / StdDev(N)` where N is typically 20-50.

### Exit Signals
- **Mean target:** Z-score returns to 0 (price at the mean).
- **Partial exit:** Close 50% at z = -0.5 (for longs), remainder at z = 0.
- **Stop loss:** Z-score reaches -3.0 (for longs) -- this indicates a structural break, not mean reversion.

### Indicators Used
- Rolling SMA (period 20-50)
- Rolling Standard Deviation (same period)
- Z-Score (derived)

### Timeframe
- **Works across timeframes:** 15m to 4H.
- **Sweet spot for crypto:** 1H with a 30-period lookback.

### Risk Management
- **Structural break detection:** If z-score stays below -2.0 for more than 10 consecutive candles, close the position (the "mean" has likely shifted).
- **Dynamic mean:** Some implementations use EMA instead of SMA to allow the mean to adapt faster.
- **Maximum positions:** 3 concurrent z-score trades.
- **Sector exposure:** Never have more than 50% of portfolio in correlated assets (e.g., multiple L1 tokens).

### Backtested Performance (Literature)
- Win rate: ~58-65%.
- Average trade duration: 8-15 candles.
- Sharpe ratio: ~0.9-1.3.
- Works best on large-cap crypto (BTC, ETH) where mean reversion is more reliable than small-caps.

### Sources
- Chan, E. (2009). *Quantitative Trading*. Wiley.
- Chan, E. (2013). *Algorithmic Trading: Winning Strategies and Their Rationale*. Wiley.
- https://www.quantstart.com/articles/Basics-of-Statistical-Mean-Reversion-Testing/

---

## 5. Keltner Channel Squeeze Reversion

### Strategy Name
Keltner-BB Squeeze Mean Reversion

### Core Logic
When Bollinger Bands contract inside Keltner Channels (the "squeeze"), volatility is compressing. When the squeeze releases, price tends to make a sharp directional move. This strategy trades the reversion AFTER the initial squeeze breakout fails (false breakout).

### Entry Signals
- **Squeeze detection:** Bollinger Bands (20, 2) are inside Keltner Channels (20, 1.5 ATR).
- **Breakout:** Price breaks above upper Keltner Channel.
- **Failed breakout (reversion entry):** Within 3 candles of breakout, price falls back inside the Keltner Channel. Enter short / exit long.
- **Mirror logic for downside:** False breakdown below lower Keltner = long entry.

### Exit Signals
- **Target:** Middle line (EMA 20).
- **Stop loss:** New high/low beyond the failed breakout candle.

### Indicators Used
- Bollinger Bands (SMA 20, 2 StdDev)
- Keltner Channels (EMA 20, 1.5x ATR 14)
- ATR (14) for stop placement

### Timeframe
- **1H or 4H candles.** Squeeze events on shorter timeframes produce too much noise.

### Risk Management
- **Only trade after confirmed squeeze release** (at least 1 candle outside Keltner).
- **Stop loss:** 1 ATR beyond the extreme of the breakout candle.
- **Skip if ADX > 30** at time of breakout (strong trend = breakout likely real, not false).

### Backtested Performance (Literature)
- Lower trade frequency (1-3 signals per week per asset on 1H).
- Win rate on false breakout trades: ~55-60%.
- Risk-reward: ~1:1.5 (better R:R than pure BB strategies).

### Sources
- Carter, J.F. (2012). *Mastering the Trade* (2nd ed.). McGraw-Hill. (TTM Squeeze indicator)
- https://www.investopedia.com/terms/k/keltnerchannel.asp
- https://school.stockcharts.com/doku.php?id=technical_indicators:keltner_channels

---

## 6. Pairs Trading (Cointegration-Based Statistical Arbitrage)

### Strategy Name
Crypto Pairs Trading via Cointegration

### Core Logic
Identify two cryptocurrencies whose prices are cointegrated (they share a long-run equilibrium relationship). When the spread between them deviates from its mean, go long the underperformer and short the outperformer, expecting convergence.

### Pair Selection
Candidates for cointegrated crypto pairs:
- **BTC/ETH** -- historically strong cointegration (same macro drivers)
- **ETH/SOL** -- L1 competition, correlated but diverge short-term
- **BNB/SOL** -- exchange/L1 token correlation
- **LINK/UNI** -- DeFi infrastructure tokens

Use the **Engle-Granger two-step test** or **Johansen test** to verify cointegration on a rolling 90-day window. Re-test weekly; pairs can lose cointegration.

### Entry Signals
- Compute the **spread:** `spread = price_A - beta * price_B` (where beta is the hedge ratio from OLS regression).
- Compute the **z-score of the spread:** `z = (spread - mean(spread)) / std(spread)` over a 30-60 period window.
- **Long spread (buy A, sell B):** Z-score < -2.0.
- **Short spread (sell A, buy B):** Z-score > +2.0.

### Exit Signals
- **Mean reversion:** Z-score returns to 0.
- **Partial exit:** At z = -0.5 / +0.5.
- **Stop loss:** Z-score reaches +/- 3.0 (spread diverging further = possible cointegration breakdown).

### Indicators Used
- OLS Regression (for hedge ratio / beta)
- Engle-Granger or Johansen cointegration test
- Rolling z-score of spread
- Half-life of mean reversion (from Ornstein-Uhlenbeck process fitting)

### Timeframe
- **Spread calculation:** 1H candles.
- **Lookback for z-score:** 30-60 periods.
- **Cointegration test window:** 90 days (retested weekly).
- **Average trade duration:** 12-48 hours.

### Risk Management
- **Dollar neutral:** Ensure long and short legs are equal in dollar terms.
- **Cointegration health check:** If ADF test p-value > 0.05, close all positions and stop trading the pair until cointegration is re-established.
- **Maximum spread deviation:** If z-score exceeds 4.0, force close -- the relationship has likely broken.
- **Rolling hedge ratio:** Recalculate beta every 5 days to avoid drift.
- **Slippage budget:** Crypto pairs trading requires 2 legs; account for 2x slippage.

### Backtested Performance (Literature)
- **BTC/ETH pair:** Sharpe ratio ~1.5-2.0 in 2021-2023 range-bound periods.
- **Win rate:** ~65-75% (spread mean reversion is more reliable than single-asset).
- **Annual return:** ~15-30% with conservative sizing.
- **Key risk:** Cointegration breakdown during major market events (e.g., ETH merge, regulatory news).

### Implementation Note for This Project
Since the bot currently only does spot trading on Binance, "shorting" a leg would need to be simulated by simply not holding it (long-only pairs trading: go long the underperformer, stay flat on the outperformer). This reduces effectiveness but is still viable.

### Sources
- Vidyamurthy, G. (2004). *Pairs Trading: Quantitative Methods and Analysis*. Wiley.
- Chan, E. (2013). *Algorithmic Trading*. Wiley. (Chapter on pairs trading)
- Gatev, E., Goetzmann, W.N., & Rouwenhorst, K.G. (2006). "Pairs Trading: Performance of a Relative-Value Arbitrage Rule." *Review of Financial Studies*.
- https://www.quantstart.com/articles/Pairs-Trading-A-Market-Neutral-Trading-Strategy/
- https://hudsonthames.org/an-introduction-to-pairs-trading/

---

## 7. Triangular Crypto Arbitrage

### Strategy Name
Triangular Arbitrage on Binance Spot

### Core Logic
Exploit pricing inefficiencies across three trading pairs that form a triangle. For example: BTC/USDT, ETH/BTC, ETH/USDT. If the implied cross-rate differs from the actual rate, execute three simultaneous trades to capture the spread.

### Entry Signals
- **Calculate implied rate:** `implied_ETH_USDT = ETH_BTC_price * BTC_USDT_price`.
- **Compare to actual:** `actual_ETH_USDT_price`.
- **Arbitrage opportunity:** If `|implied - actual| / actual > threshold` (typically > 0.15% to cover fees).
- **Direction:** If implied > actual, buy ETH/USDT, sell ETH/BTC, sell BTC/USDT. If implied < actual, reverse.

### Exit Signals
- All three legs execute simultaneously (or as close to simultaneously as possible). No exit management needed -- it is a one-shot trade.

### Indicators Used
- Real-time order book data (best bid/ask on all three pairs)
- Fee calculation (Binance spot: 0.1% maker/taker, or 0.075% with BNB)
- Slippage estimation from order book depth

### Timeframe
- **Sub-second to seconds.** This is a latency-sensitive strategy.
- **Not suitable for candle-based simulation** -- requires real-time WebSocket order book data.

### Risk Management
- **Minimum profit threshold:** Only execute if net profit after 3x fees > 0.05%.
- **Execution risk:** All three legs must fill. Use IOC (Immediate-Or-Cancel) orders.
- **Capital requirement:** Requires holding inventory in all three assets.
- **Frequency:** Opportunities last milliseconds in liquid markets; more frequent in less liquid pairs.

### Backtested Performance (Literature)
- **Profit per trade:** Very small (0.01-0.10%).
- **Frequency:** Varies; more opportunities during high-volatility periods.
- **Annual return:** Highly dependent on execution speed and capital.
- **Sharpe ratio:** Can be very high (>3.0) due to near-zero variance per trade.
- **Reality check:** Professional HFT firms dominate this space. Retail bots can still find opportunities on less liquid pairs.

### Implementation Note for This Project
This strategy would require significant infrastructure changes (WebSocket order book feeds, sub-second execution). Not recommended as an immediate implementation target but documented for completeness.

### Sources
- https://www.investopedia.com/terms/t/triangulararbitrage.asp
- Makarov, I. & Schoar, A. (2020). "Trading and Arbitrage in Cryptocurrency Markets." *Journal of Financial Economics*.

---

## 8. Cross-Exchange Statistical Arbitrage

### Strategy Name
Cross-Exchange Spread Arbitrage

### Core Logic
The same asset (e.g., BTC/USDT) trades at slightly different prices on different exchanges. Monitor the spread between exchanges and trade when the spread exceeds a threshold based on historical spread distribution.

### Entry Signals
- **Compute spread:** `spread = price_exchange_A - price_exchange_B`.
- **Z-score:** Calculate z-score of the spread over a rolling 1000-tick or 4H window.
- **Entry:** Z-score > 2.0 (buy on cheaper exchange, sell on more expensive).

### Exit Signals
- **Spread convergence:** Z-score returns to 0.
- **Time limit:** If spread hasn't converged in 1 hour, close both legs.

### Risk Management
- **Transfer risk:** Avoid needing to transfer crypto between exchanges (maintain balances on both).
- **Fee awareness:** Must profit after fees on both exchanges.
- **Withdrawal/deposit delays:** This is not arbitrage if you need to move funds.

### Implementation Note for This Project
Requires multi-exchange integration. Currently the project only connects to Binance. Documented for future reference.

### Sources
- Makarov, I. & Schoar, A. (2020). "Trading and Arbitrage in Cryptocurrency Markets." *Journal of Financial Economics*.
- https://www.quantconnect.com/docs/v2/research-environment/applying-research/crypto-arbitrage

---

## 9. Implementation Priority & Recommendations

Based on the project's current architecture (Elixir/OTP, Binance spot, candle-based simulation, `signal(event, state) -> {[orders], new_state}` interface):

### Tier 1 -- Implement First (Low complexity, high compatibility)

| Strategy | Why | Effort |
|----------|-----|--------|
| **BB-RSI Confluence (#3)** | Two simple indicators, works on 1H candles, fits existing signal interface perfectly | Small |
| **RSI Mean Reversion (#2)** | Single indicator, very well-documented, easy to backtest | Small |
| **Z-Score Reversion (#4)** | Straightforward math, no external dependencies | Small |

### Tier 2 -- Implement Second (Medium complexity)

| Strategy | Why | Effort |
|----------|-----|--------|
| **Keltner Squeeze (#5)** | Requires ATR + Keltner channels but logic is clean | Medium |
| **Pairs Trading (#6)** | Requires tracking 2 assets simultaneously, cointegration testing; long-only variant is feasible | Medium-Large |

### Tier 3 -- Future / Requires Infrastructure Changes

| Strategy | Why | Effort |
|----------|-----|--------|
| **Triangular Arb (#7)** | Needs real-time order book, sub-second execution | Large |
| **Cross-Exchange (#8)** | Needs multi-exchange integration | Large |

### Suggested First Implementation: BB-RSI Confluence (#3)

**Rationale:**
1. Combines two well-understood indicators for higher-quality signals.
2. Parameters are intuitive and well-documented in literature.
3. Fits perfectly into the existing `signal/2` interface -- state holds rolling SMA, StdDev, and RSI values.
4. Can be simulated with the existing candle archive infrastructure.
5. Complements the existing IntradayMomentum strategy (momentum + mean reversion = diversification).

**State structure sketch:**
```
%{
  window: 20,           # SMA/BB lookback
  rsi_period: 14,       # RSI lookback
  bb_mult: 2.0,         # BB standard deviation multiplier
  prices: %{},          # symbol => [last N closes] (ring buffer)
  rsi_state: %{},       # symbol => {avg_gain, avg_loss}
  positions: %{},       # symbol => %{entry_price, quantity}
  quote_per_trade: 100.0,
  stop_loss_pct: 0.03
}
```
