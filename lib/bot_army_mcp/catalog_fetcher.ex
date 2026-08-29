defmodule BotArmyMcp.CatalogFetcher do
  @moduledoc """
  Fetches external MCP tool catalogs from curated sources.

  Supports:
  - GitHub raw markdown (e.g. awesome-mcp-servers README tables)
  - GitHub repository listings (e.g. modelcontextprotocol/servers)
  - Custom JSON URLs

  Runs on a periodic schedule (default every 60 minutes) and feeds
  parsed entries into CatalogStore.
  """

  use GenServer
  require Logger

  alias BotArmyMcp.CatalogStore

  @default_interval_ms :timer.minutes(60)
  @github_raw "https://raw.githubusercontent.com"

  @sources [
    %{
      id: "awesome-mcp-servers",
      type: :github_markdown_table,
      url: "#{@github_raw}/punkpeye/awesome-mcp-servers/main/README.md",
      trust_tier: "community"
    },
    %{
      id: "mcp-official-servers",
      type: :github_repo_list,
      url: "https://api.github.com/repos/modelcontextprotocol/servers/contents/src",
      trust_tier: "official"
    }
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger an immediate fetch."
  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    immediate = Keyword.get(opts, :immediate_fetch, true)

    if immediate do
      Process.send_after(self(), :do_fetch, 5_000)
    end

    schedule_fetch(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:do_fetch, state) do
    fetch_all()
    {:noreply, state}
  end

  @impl true
  def handle_info(:scheduled_fetch, state) do
    fetch_all()
    schedule_fetch(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    fetch_all()
    {:noreply, state}
  end

  # Private

  defp schedule_fetch(interval) do
    Process.send_after(self(), :scheduled_fetch, interval)
  end

  defp fetch_all do
    Logger.info("[CatalogFetcher] Starting external catalog fetch")

    entries =
      @sources
      |> Enum.flat_map(fn source ->
        case fetch_source(source) do
          {:ok, items} ->
            items

          {:error, reason} ->
            Logger.warning("[CatalogFetcher] #{source.id} failed: #{inspect(reason)}")
            []
        end
      end)

    CatalogStore.upsert_external(entries)
    Logger.info("[CatalogFetcher] Fetched #{length(entries)} external tools")
  end

  defp fetch_source(%{type: :github_markdown_table, url: url, trust_tier: tier}) do
    case http_get(url) do
      {:ok, body} ->
        entries = parse_markdown_table(body, tier)
        {:ok, entries}

      error ->
        error
    end
  end

  defp fetch_source(%{type: :github_repo_list, url: url, trust_tier: tier}) do
    case http_get_json(url) do
      {:ok, items} when is_list(items) ->
        entries =
          items
          |> Enum.filter(fn item -> Map.get(item, "type") == "dir" end)
          |> Enum.map(fn item ->
            name = Map.get(item, "name", "")

            %{
              "slug" => "mcp-#{name}",
              "name" => name,
              "description" => "Official MCP server: #{name}",
              "url" => Map.get(item, "html_url", ""),
              "source" => "external",
              "trust_tier" => tier,
              "tags" => ["mcp", "official"],
              "install_type" => "npm",
              "install_hint" => "npm install @modelcontextprotocol/server-#{name}"
            }
          end)

        {:ok, entries}

      error ->
        error
    end
  end

  defp http_get(url) do
    case Req.get(url, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_get_json(url) do
    case http_get(url) do
      {:ok, body} when is_binary(body) -> Jason.decode(body)
      {:ok, body} -> {:ok, body}
      error -> error
    end
  end

  defp parse_markdown_table(markdown, trust_tier) do
    lines = String.split(markdown, "\n")

    # Find table header line with "|"
    table_lines =
      lines
      |> Enum.drop_while(fn line ->
        not String.starts_with?(String.trim(line), "|")
      end)
      |> Enum.take_while(fn line ->
        String.starts_with?(String.trim(line), "|")
      end)

    case table_lines do
      [_header, _separator | rows] ->
        rows
        |> Enum.map(&parse_table_row/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn row ->
          Map.merge(row, %{
            "source" => "external",
            "trust_tier" => trust_tier
          })
        end)

      _ ->
        []
    end
  end

  defp parse_table_row(line) do
    cells =
      line
      |> String.split("|")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case cells do
      [name, description | _rest] ->
        slug = slugify(name)

        %{
          "slug" => slug,
          "name" => name,
          "description" => description,
          "tags" => extract_tags(name, description),
          "install_type" => infer_install_type(name, description),
          "install_hint" => "See documentation for install instructions"
        }

      _ ->
        nil
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp extract_tags(name, description) do
    text = String.downcase(name <> " " <> description)

    tags =
      [
        {"browser", ["browser", "puppeteer", "playwright", "selenium"]},
        {"search", ["search", "google", "bing", "brave"]},
        {"database", ["database", "sql", "postgres", "sqlite"]},
        {"filesystem", ["file", "fs", "filesystem"]},
        {"git", ["git", "github"]},
        {"slack", ["slack"]},
        {"memory", ["memory", "sqlite", "persistent"]},
        {"terminal", ["terminal", "shell", "bash", "command"]},
        {"fetch", ["fetch", "http", "request", "curl"]}
      ]
      |> Enum.filter(fn {_tag, keywords} ->
        Enum.any?(keywords, &String.contains?(text, &1))
      end)
      |> Enum.map(&elem(&1, 0))

    ["mcp" | tags]
  end

  defp infer_install_type(name, desc) do
    text = String.downcase(name <> " " <> desc)

    cond do
      String.contains?(text, "npm") or String.contains?(text, "npx") -> "npm"
      String.contains?(text, "pip") or String.contains?(text, "python") -> "pip"
      String.contains?(text, "docker") -> "docker"
      String.contains?(text, "go ") or String.contains?(text, "golang") -> "go"
      true -> "unknown"
    end
  end
end
