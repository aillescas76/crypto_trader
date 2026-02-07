import Config

if config_env() in [:dev, :test] do
  path = Path.expand("../.env", __DIR__)

  if File.exists?(path) do
    path
    |> File.stream!()
    |> Enum.each(fn line ->
      line = String.trim(line)

      cond do
        line == "" ->
          :ok

        String.starts_with?(line, "#") ->
          :ok

        true ->
          case String.split(line, "=", parts: 2) do
            [key, value] ->
              key = String.trim(key)

              value =
                String.trim(value) |> String.trim_leading("\"") |> String.trim_trailing("\"")

              if key != "" and System.get_env(key) in [nil, ""] do
                System.put_env(key, value)
              end

            _ ->
              :ok
          end
      end
    end)
  end
end
