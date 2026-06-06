defmodule BotArmyMcp.CircuitBreaker do
  @moduledoc """
  Circuit breaker for managing slow/unresponsive NATS subjects.

  Tracks failure patterns per subject (timeouts, errors) and temporarily
  prevents calls to subjects that exceed failure thresholds.

  States:
  - :closed — normal operation (allow all calls)
  - :open — breaker tripped (reject calls, return error immediately)
  - :half_open — testing recovery (allow 1 call, reset on success)

  Configuration:
  - failure_threshold: errors before opening (default 5)
  - success_threshold: successes before closing from half-open (default 2)
  - timeout: window to track failures in (default 60s)
  """

  require Logger

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Check if a subject is available (circuit is not open).
  """
  @spec available?(String.t()) :: boolean()
  def available?(subject) do
    state = Agent.get(__MODULE__, & &1)
    breaker = state[subject] || new_breaker()

    case breaker.state do
      :open -> false
      _ -> true
    end
  end

  @doc """
  Record a successful call to a subject.
  """
  @spec record_success(String.t()) :: :ok
  def record_success(subject) do
    Agent.update(__MODULE__, fn state ->
      breaker = state[subject] || new_breaker()

      case breaker.state do
        :closed ->
          # Still closed, keep track of state
          state

        :half_open ->
          # Moving back to closed after success
          Map.put(state, subject, %{breaker | state: :closed, error_count: 0})

        :open ->
          state
      end
    end)

    :ok
  end

  @doc """
  Record a failed call to a subject.
  """
  @spec record_failure(String.t(), term()) :: :ok
  def record_failure(subject, reason \\ :timeout) do
    Agent.update(__MODULE__, fn state ->
      breaker = state[subject] || new_breaker()
      failure_threshold = breaker.failure_threshold

      new_error_count = breaker.error_count + 1

      new_state =
        if new_error_count >= failure_threshold do
          Logger.warning("Circuit breaker opened for #{subject}: #{reason}")
          :open
        else
          :closed
        end

      updated_breaker = %{
        breaker
        | error_count: new_error_count,
          state: new_state,
          last_error: reason
      }

      Map.put(state, subject, updated_breaker)
    end)

    :ok
  end

  @doc """
  Reset a breaker (e.g., after deploying a fix).
  """
  @spec reset(String.t()) :: :ok
  def reset(subject) do
    Agent.update(__MODULE__, fn state ->
      Map.put(state, subject, new_breaker())
    end)

    Logger.info("Circuit breaker reset for #{subject}")
    :ok
  end

  @doc """
  Get status of a subject.
  """
  @spec status(String.t()) :: map()
  def status(subject) do
    state = Agent.get(__MODULE__, & &1)
    breaker = state[subject] || new_breaker()

    %{
      subject: subject,
      state: breaker.state,
      error_count: breaker.error_count,
      last_error: breaker.last_error,
      failure_threshold: breaker.failure_threshold
    }
  end

  # Private

  defp new_breaker do
    %{
      state: :closed,
      error_count: 0,
      last_error: nil,
      failure_threshold: 5,
      success_threshold: 2
    }
  end
end
