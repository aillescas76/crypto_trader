defmodule CriptoTraderWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Cripto Trader — Experiment Loop</title>
        <script src="https://unpkg.com/lightweight-charts@4.2.0/dist/lightweight-charts.standalone.production.js"></script>
        <style>
          * { box-sizing: border-box; }
          body { font-family: monospace; background: #0d1117; color: #c9d1d9; margin: 0; padding: 0; }
          nav { background: #161b22; padding: 12px 24px; border-bottom: 1px solid #30363d; }
          nav a { color: #58a6ff; text-decoration: none; margin-right: 24px; }
          nav a:hover { text-decoration: underline; }
          main { padding: 24px; max-width: 1200px; margin: 0 auto; }
          h1 { color: #f0f6fc; font-size: 1.4em; }
          table { width: 100%; border-collapse: collapse; }
          th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid #21262d; }
          th { background: #161b22; color: #8b949e; font-weight: bold; }
          tr:hover td { background: #161b22; }
          .badge-pending { color: #d29922; }
          .badge-running { color: #388bfd; }
          .badge-passed  { color: #3fb950; }
          .badge-failed  { color: #f85149; }
          .badge-error   { color: #f85149; }
          .pass { color: #3fb950; }
          .fail { color: #f85149; }
          textarea { width: 100%; background: #161b22; color: #c9d1d9; border: 1px solid #30363d; padding: 8px; border-radius: 4px; font-family: monospace; }
          input[type=text] { background: #161b22; color: #c9d1d9; border: 1px solid #30363d; padding: 6px 10px; border-radius: 4px; font-family: monospace; }
          button { background: #238636; color: #fff; border: none; padding: 8px 16px; border-radius: 4px; cursor: pointer; font-family: monospace; }
          button:hover { background: #2ea043; }
          .finding { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 16px; margin-bottom: 12px; }
          .tag { background: #21262d; color: #8b949e; padding: 2px 8px; border-radius: 3px; font-size: 0.85em; margin-right: 4px; }
          .feedback-entry { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 12px; margin-bottom: 8px; }
          .ack { opacity: 0.5; }
          .session-panel { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 12px 16px; margin-bottom: 20px; }
          .session-in_progress { border-color: #388bfd; }
          .session-completed { border-color: #3fb950; }
          .session-header { display: flex; align-items: center; gap: 16px; flex-wrap: wrap; }
          .session-badge { font-weight: bold; font-size: 0.85em; }
          .session-badge-in_progress { color: #388bfd; }
          .session-badge-completed { color: #3fb950; }
          .session-badge-idle { color: #8b949e; }
          .session-step { color: #c9d1d9; font-size: 0.9em; }
          .session-progress { color: #8b949e; font-size: 0.8em; letter-spacing: 0.05em; margin-left: auto; }
          .session-hypothesis { margin-top: 10px; font-size: 0.9em; line-height: 1.5; }
        </style>
      </head>
      <body>
        <nav>
          <a href="/">Feed</a>
          <a href="/findings">Findings</a>
          <a href="/feedback">Feedback</a>
          <a href="/session">Session</a>
          <a href="/investigations">Investigations</a>
          <a href="/live-sim">Live Sim</a>
          <a href="/market">Market</a>
        </nav>
        <main>
          <%= @inner_content %>
        </main>
        <script src="/assets/phoenix.min.js"></script>
        <script src="/assets/phoenix_live_view.min.js"></script>
        <script src="/assets/app.js"></script>
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <%= @inner_content %>
    """
  end
end
