defmodule CriptoTrader.CandleDB.Candle do
  use Ecto.Schema
  import Ecto.Changeset

  @required [:symbol, :interval, :open_time, :open, :high, :low, :close]
  @optional [:close_time, :volume, :quote_volume, :trade_count, :taker_buy_volume, :taker_buy_quote]

  schema "candles" do
    field :symbol, :string
    field :interval, :string
    field :open_time, :integer
    field :close_time, :integer
    field :open, :decimal
    field :high, :decimal
    field :low, :decimal
    field :close, :decimal
    field :volume, :decimal
    field :quote_volume, :decimal
    field :trade_count, :integer
    field :taker_buy_volume, :decimal
    field :taker_buy_quote, :decimal

    timestamps(type: :utc_datetime)
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(normalize(attrs), @required ++ @optional)
    |> validate_required(@required)
  end

  # Rename Binance field names to DB column names.
  # Handles both atom and string keys; Map.put_new/3 means the first match wins.
  defp normalize(attrs) do
    attrs
    |> rename(:quote_asset_volume, :quote_volume)
    |> rename("quote_asset_volume", :quote_volume)
    |> rename(:number_of_trades, :trade_count)
    |> rename("number_of_trades", :trade_count)
    |> rename(:taker_buy_base_volume, :taker_buy_volume)
    |> rename("taker_buy_base_volume", :taker_buy_volume)
    |> rename(:taker_buy_quote_volume, :taker_buy_quote)
    |> rename("taker_buy_quote_volume", :taker_buy_quote)
    |> truncate_open_time()
  end

  # Truncate open_time to the nearest second (drop sub-second precision).
  # Binance candle open_times are always on exact interval boundaries
  # (e.g. 1h candles start on the hour), so millisecond precision adds
  # no information and causes spurious duplicates when the same candle
  # is inserted from multiple sources at slightly different wall-clock times.
  defp truncate_open_time(attrs) do
    case Map.fetch(attrs, :open_time) do
      {:ok, ms} when is_integer(ms) ->
        Map.put(attrs, :open_time, div(ms, 1_000) * 1_000)

      _ ->
        case Map.fetch(attrs, "open_time") do
          {:ok, ms} when is_integer(ms) ->
            Map.put(attrs, "open_time", div(ms, 1_000) * 1_000)

          _ ->
            attrs
        end
    end
  end

  defp rename(attrs, from, to) do
    case Map.pop(attrs, from) do
      {nil, _} -> attrs
      {val, rest} -> Map.put_new(rest, to, val)
    end
  end
end
