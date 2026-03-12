defmodule CriptoTraderWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CriptoTraderWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", CriptoTraderWeb do
    pipe_through :browser

    live "/", ExperimentsLive.Feed
    live "/findings", ExperimentsLive.Findings
    live "/feedback", ExperimentsLive.Feedback
  end
end
