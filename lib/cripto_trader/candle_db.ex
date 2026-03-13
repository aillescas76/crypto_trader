defmodule CriptoTrader.CandleDB do
  @moduledoc """
  Public interface to the candle history database.

  All candle reads and writes go through this module. The underlying Repo and
  schema are private implementation details — do not call them directly.

  Decimal fields (open, high, low, close, volume, etc.) are returned as
  `Decimal` structs, not floats. Use `Decimal.to_float/1` if float
  arithmetic is required downstream.
  """

  import Ecto.Query

  alias CriptoTrader.CandleDB.{Candle, Repo}

  @doc """
  Bulk upsert candles. Accepts raw Binance maps from any source (archive,
  REST, or live feed) — field normalisation is handled internally.

  On conflict on `(symbol, interval, open_time)`, all fields except `id` and
  `inserted_at` are updated. Invalid candles are skipped silently.

  Returns `{:ok, count}` where count is rows inserted or updated.
  """
  @spec insert_candles([map()]) :: {:ok, integer()} | {:error, term()}
  def insert_candles([]), do: {:ok, 0}

  def insert_candles(candles) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      candles
      |> Enum.map(&to_row(&1, now))
      |> Enum.reject(&is_nil/1)

    if rows == [] do
      {:ok, 0}
    else
      {count, _} =
        Repo.insert_all(
          Candle,
          rows,
          on_conflict: {:replace_all_except, [:id, :inserted_at]},
          conflict_target: [:symbol, :interval, :open_time]
        )

      {:ok, count}
    end
  end

  @doc """
  Returns candles for the last `days` calendar days for the given symbol
  and interval, ordered by `open_time` ascending.
  """
  @spec recent(String.t(), String.t(), [{:days, integer()}]) :: [Candle.t()]
  def recent(symbol, interval, days: n) do
    cutoff_ms =
      DateTime.utc_now()
      |> DateTime.add(-n * 86_400, :second)
      |> DateTime.to_unix(:millisecond)

    Repo.all(
      from c in Candle,
        where:
          c.symbol == ^symbol and
            c.interval == ^interval and
            c.open_time >= ^cutoff_ms,
        order_by: [asc: c.open_time]
    )
  end

  @doc """
  Returns candles in the closed interval `[from_ms, to_ms]` (Unix ms),
  ordered by `open_time` ascending.
  """
  @spec range(String.t(), String.t(), integer(), integer()) :: [Candle.t()]
  def range(symbol, interval, from_ms, to_ms) do
    Repo.all(
      from c in Candle,
        where:
          c.symbol == ^symbol and
            c.interval == ^interval and
            c.open_time >= ^from_ms and
            c.open_time <= ^to_ms,
        order_by: [asc: c.open_time]
    )
  end

  # -- Private --

  defp to_row(raw, now) do
    cs = Candle.changeset(raw)

    if cs.valid? do
      cs
      |> Ecto.Changeset.apply_changes()
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
      |> Map.merge(%{inserted_at: now, updated_at: now})
    else
      nil
    end
  end
end
