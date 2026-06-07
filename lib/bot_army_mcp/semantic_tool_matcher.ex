defmodule BotArmyMcp.SemanticToolMatcher do
  @moduledoc """
  Semantic matching for MCP tools based on natural language queries.

  Scores and ranks tools by relevance to user queries using keyword-based matching.
  Supports scoring based on:
  - Subject name (weighted highest)
  - Tool description (weighted medium)
  - Schema properties (weighted lowest)

  Examples:
      iex> tools = [
      ...>   %{name: "gtd.task.create", description: "Create a task"},
      ...>   %{name: "gtd.task.list", description: "List all tasks"}
      ...> ]
      iex> BotArmyMcp.SemanticToolMatcher.find_tools(tools, "create task", limit: 1) |> Enum.map(fn t -> t.name end)
      ["gtd.task.create"]

  The scoring algorithm considers:
  1. Subject name tokens: matched words contribute 1.0 points each (highest priority)
  2. Description tokens: matched words contribute 0.5 points each
  3. Property names: matched words contribute 0.25 points each (lowest priority)
  """

  require Logger

  @weight_subject 1.0
  @weight_description 0.5
  @weight_properties 0.25
  @min_score 0.0

  @doc """
  Find tools matching a query, sorted by relevance score (descending).

  Returns list of tools with added `:score` field. Empty list if no matches.

  Options:
    - `:limit` - Maximum number of results to return (default: 10)
    - `:min_score` - Minimum relevance score to include (default: 0.0)
  """
  @spec find_tools(list(map()), binary(), Keyword.t()) :: list(map())
  def find_tools(tools, query, opts \\ [])

  def find_tools([], _query, _opts), do: []

  def find_tools(tools, query, opts) when is_list(tools) and is_binary(query) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, @min_score)

    tools
    |> Enum.map(fn tool ->
      score = score_tool(tool, query)
      Map.put(tool, :score, score)
    end)
    |> Enum.filter(fn tool -> tool.score >= min_score end)
    |> Enum.sort_by(fn tool -> -tool.score end)
    |> Enum.take(limit)
  end

  @doc """
  Score a single tool against a query.

  Returns a numeric score (0.0 or higher). Higher score means better match.
  """
  @spec score_tool(map(), binary()) :: float()
  def score_tool(tool, query) when is_map(tool) and is_binary(query) do
    query_tokens = tokenize(query)

    subject_score =
      tool
      |> Map.get(:name, "")
      |> tokenize()
      |> token_overlap(query_tokens)
      |> Kernel.*(weight_factor(:subject))

    description_score =
      tool
      |> Map.get(:description, "")
      |> tokenize()
      |> token_overlap(query_tokens)
      |> Kernel.*(weight_factor(:description))

    properties_score =
      case tool |> Map.get(:inputSchema) do
        nil ->
          0.0

        schema when is_map(schema) ->
          schema
          |> Map.get(:properties, %{})
          |> extract_property_names()
          |> token_overlap(query_tokens)
          |> Kernel.*(weight_factor(:properties))

        _ ->
          0.0
      end

    subject_score + description_score + properties_score
  end

  # Weight factors (relative to subject weight of 1.0)
  defp weight_factor(:subject), do: @weight_subject
  defp weight_factor(:description), do: @weight_description
  defp weight_factor(:properties), do: @weight_properties

  # Tokenize text into lowercase words, filtering empty strings
  defp tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[\s\-_.]+/)
    |> Enum.filter(&(String.length(&1) > 0))
  end

  defp tokenize(_), do: []

  # Count how many query tokens appear in the token set
  defp token_overlap(tokens, query_tokens) do
    query_set = MapSet.new(query_tokens)
    tokens = Enum.uniq(tokens)

    Enum.count(tokens, fn token ->
      MapSet.member?(query_set, token) || contains_substring?(token, query_tokens)
    end)
    |> to_float()
  end

  # Check if a token is a substring of any query token (for partial matches)
  defp contains_substring?(token, query_tokens) do
    Enum.any?(query_tokens, fn query_token ->
      String.length(token) >= 3 &&
        String.length(query_token) >= 3 &&
        (String.contains?(token, query_token) || String.contains?(query_token, token))
    end)
  end

  # Extract property names from schema properties object
  defp extract_property_names(properties) when is_map(properties) do
    properties
    |> Map.keys()
    |> Enum.map(fn key ->
      if is_binary(key), do: key, else: key |> Atom.to_string()
    end)
  end

  defp extract_property_names(_), do: []

  defp to_float(num) when is_integer(num), do: num / 1.0
  defp to_float(num) when is_float(num), do: num
end
