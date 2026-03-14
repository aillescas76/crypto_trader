defmodule CriptoTraderWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :cripto_trader

  @session_options [store: :cookie, key: "_cripto_trader_key", signing_salt: "experiment_loop"]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/assets",
    from: {:phoenix, "priv/static"},
    gzip: false,
    only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/assets",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false,
    only: ~w(phoenix_live_view.min.js)

  plug Plug.Static,
    at: "/",
    from: :cripto_trader,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug CriptoTraderWeb.Router
end
