// Phoenix and LiveView are loaded as UMD globals from their .min.js files.
// Phoenix 1.7 exposes window.Phoenix = { Socket, Channel, ... }
// PhoenixLiveView 1.x exposes window.LiveView = { LiveSocket, ... }

const { Socket } = window.Phoenix;
const { LiveSocket } = window.LiveView;

const Hooks = {};

Hooks.CandleChart = {
  mounted() {
    const symbol = this.el.dataset.symbol;

    const chart = LightweightCharts.createChart(this.el, {
      width: this.el.offsetWidth,
      height: this.el.offsetHeight || 320,
      layout: {
        background: { color: "#0d1117" },
        textColor: "#8b949e",
        fontSize: 11,
      },
      grid: {
        vertLines: { color: "#161b22" },
        horzLines: { color: "#161b22" },
      },
      timeScale: {
        borderColor: "#21262d",
        timeVisible: true,
        secondsVisible: false,
        fixLeftEdge: true,
      },
      rightPriceScale: {
        borderColor: "#21262d",
        scaleMargins: { top: 0.1, bottom: 0.1 },
      },
      crosshair: {
        mode: LightweightCharts.CrosshairMode.Normal,
      },
    });

    const candleSeries = chart.addCandlestickSeries({
      upColor: "#3fb950",
      downColor: "#f85149",
      borderUpColor: "#3fb950",
      borderDownColor: "#f85149",
      wickUpColor: "#3fb950",
      wickDownColor: "#f85149",
    });

    this._chart = chart;
    this._candleSeries = candleSeries;

    this._resizeObserver = new ResizeObserver(() => {
      chart.applyOptions({
        width: this.el.offsetWidth,
        height: this.el.offsetHeight || 320,
      });
    });
    this._resizeObserver.observe(this.el);

    this.handleEvent(`candle_update:${symbol}`, ({ candles, markers }) => {
      if (candles && candles.length > 0) {
        candleSeries.setData(candles);
      }

      if (markers && markers.length > 0) {
        const chartMarkers = markers.map((m) => ({
          time: m.time,
          position: m.side === "BUY" ? "belowBar" : "aboveBar",
          color: m.side === "BUY" ? "#3fb950" : "#f85149",
          shape: m.side === "BUY" ? "arrowUp" : "arrowDown",
          text: m.label,
        }));
        // lightweight-charts requires markers sorted by time ascending
        chartMarkers.sort((a, b) => a.time - b.time);
        candleSeries.setMarkers(chartMarkers);
      } else {
        candleSeries.setMarkers([]);
      }
    });

    // Request initial data from the server
    this.pushEvent("chart_ready", { symbol });
  },

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect();
    if (this._chart) this._chart.remove();
  },
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

liveSocket.connect();
window.liveSocket = liveSocket;
