# Crypto Trading Strategy Proposals

> Researched: 2026-03-10
> For: cripto_trader (Elixir/OTP Binance spot bot)

## Files

| File | Category | Strategies |
|------|----------|------------|
| `01_momentum_trend.md` | Momentum & Trend Following | Dual EMA Crossover + RSI, Triple EMA, BB Momentum Breakout, MACD + ADX, Multi-TF RSI, Donchian Turtle |
| `02_mean_reversion.md` | Mean Reversion & Stat Arb | BB Classic, RSI Reversion, BB-RSI Confluence, Z-Score, Keltner Squeeze, Pairs Trading, Triangular Arb, Cross-Exchange Arb |
| `03_breakout_volatility.md` | Breakout & Volatility | Donchian Breakout, ATR/Keltner Breakout, BB Squeeze, Range Breakout + Volume, Volatility Expansion, Opening Range Breakout |
| `04_volume_orderflow.md` | Volume & Order Flow | VWAP Mean-Reversion, OBV Divergence, A/D Volume Spike, Volume Profile POC/VA, CVD Trend, Multi-Indicator Composite |
| `05_defi_onchain.md` | DeFi & On-Chain | Whale Tracking, Yield Arbitrage, Funding Rate Arb, DEX-CEX Arb, Grid Trading, Exchange Netflow, Hedged LP Farming |

## Top Picks for This Bot (Binance Spot, Candle-Based)

These strategies are **immediately implementable** with the existing architecture:

### Tier 1 — Low complexity, high compatibility
1. **BB-RSI Confluence Mean Reversion** — Two simple indicators, 1H candles, ~60-70% WR
2. **Donchian Channel Breakout** — Fewest parameters, proven trend-following, ~40-60% annual
3. **OBV Divergence Breakout** — OHLCV only, good R:R at 2:1, complements momentum
4. **Dual EMA Crossover + RSI** — Classic momentum, easy to implement and validate
5. **Grid Trading** — Excellent for range-bound markets (~70% of crypto market time)

### Tier 2 — Medium complexity
6. **VWAP Mean-Reversion** — Intraday scalping, Sharpe ~1.4
7. **BB Squeeze Breakout** — Post-consolidation captures, 2.5:1 R:R
8. **Volume Profile POC/VA** — Most robust across regimes, Sharpe ~1.5
9. **CVD Trend Following** — Catches institutional accumulation

### Tier 3 — Requires infrastructure changes
10. **Funding Rate Arbitrage** — Needs Futures API, but Sharpe 2.0-3.5
11. **Pairs Trading** — Needs multi-asset tracking, cointegration testing
12. **DEX-CEX Arbitrage** — Needs DEX integration, sub-second latency
13. **Whale Flow Momentum** — Needs external APIs (Nansen/Arkham)

## Key Performance Benchmarks (from web research)

| Strategy Type | Typical Sharpe | Annual Return | Max Drawdown |
|--------------|---------------|---------------|-------------|
| Mean reversion (BB+RSI) | 1.0-1.5 | 15-30% | 8-12% |
| Trend following (Donchian) | 0.8-1.2 | 40-60% | 20-30% |
| Volume composite | 1.5-1.7 | 20-40% | 6-10% |
| Funding rate arb | 2.0-3.5 | 12-50% | 2-5% |
| Grid trading | 1.2-1.8 | 15-30% | 10-15% |
| ML-based ensemble | 2.7-3.2 | 30-50% | 10-20% |

## Suggested Implementation Order

1. Build shared indicator module (`CriptoTrader.Indicators.*`)
2. Implement BB-RSI Confluence (complements existing IntradayMomentum)
3. Implement Donchian Channel Breakout (trend-following diversification)
4. Add regime detection (ADX filter) to switch between strategies
5. Implement Grid Trading for sideways markets
6. Build Volume Profile + VWAP for intraday edge

## Sources

### Web Research (March 2026)
- [FMZ: Multi-Factor Mean Reversion](https://www.fmz.com/lang/en/strategy/489893)
- [SSRN: BB Regimes in BTC/USDT](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5775962)
- [TrendSpider: Donchian Strategies](https://trendspider.com/learning-center/donchian-channel-trading-strategies/)
- [Algomatic: Donchian Breakout](https://algomatictrading.substack.com/p/strategy-8-the-easiest-trend-system)
- [Hedge Fund Alpha from Oct 2025 Cascade](https://navnoorbawa.substack.com/p/how-hedge-funds-basis-traders-and)
- [Algo Trading +47% in 2025](https://ratex.ai/blog/how-algorithmic-cryptocurrency-trading-boosted-profits-by-47-2025-data.nia/)
- [arXiv: Deep Learning VWAP for Crypto](https://arxiv.org/html/2502.13722v2)
- [CryptoQuant On-Chain Analytics](https://cryptoquant.com)
- [Cryptowisser: Advanced On-Chain Analysis](https://www.cryptowisser.com/guides/advanced-on-chain-analysis/)

### Books
- Bollinger, J. *Bollinger on Bollinger Bands* (2001)
- Chan, E. *Algorithmic Trading* (2013)
- Curtis Faith. *Way of the Turtle* (2007)
- Connors & Raschke. *Street Smarts* (1996)
- Prado, M.L. *Advances in Financial Machine Learning* (2018)
