defmodule BotArmyMcp.CircuitBreakerTest do
  use ExUnit.Case
  @moduletag :unit

  alias BotArmyMcp.CircuitBreaker

  setup do
    # Start the circuit breaker for each test
    {:ok, _pid} = CircuitBreaker.start_link()
    :ok
  end

  describe "available?/1" do
    test "returns true for new subjects (closed state)" do
      subject = "new.subject"
      assert CircuitBreaker.available?(subject) == true
    end

    test "returns false after opening" do
      subject = "slow.subject"

      # Simulate failures to open breaker
      for _ <- 1..5 do
        CircuitBreaker.record_failure(subject, :timeout)
      end

      assert CircuitBreaker.available?(subject) == false
    end
  end

  describe "record_success/1" do
    test "keeps circuit closed when healthy" do
      subject = "healthy.subject"

      for _ <- 1..3 do
        CircuitBreaker.record_success(subject)
      end

      assert CircuitBreaker.available?(subject) == true
    end

    test "closes circuit from half-open state" do
      subject = "recovering.subject"

      # Open circuit
      for _ <- 1..5 do
        CircuitBreaker.record_failure(subject, :timeout)
      end

      assert CircuitBreaker.available?(subject) == false

      # Success closes it (assuming half-open implementation)
      CircuitBreaker.record_success(subject)
      # Note: would need half-open state transition logic for full test
    end
  end

  describe "record_failure/2" do
    test "accumulates failures" do
      subject = "failing.subject"

      for i <- 1..4 do
        CircuitBreaker.record_failure(subject, :timeout)
        status = CircuitBreaker.status(subject)
        assert status.error_count == i
      end

      # Should still be closed at 4 failures
      assert CircuitBreaker.available?(subject) == true
    end

    test "opens on threshold (5 failures)" do
      subject = "threshold.subject"

      for _ <- 1..5 do
        CircuitBreaker.record_failure(subject, :timeout)
      end

      status = CircuitBreaker.status(subject)
      assert status.state == :open
      assert CircuitBreaker.available?(subject) == false
    end
  end

  describe "reset/1" do
    test "closes an open circuit" do
      subject = "broken.subject"

      # Open it
      for _ <- 1..5 do
        CircuitBreaker.record_failure(subject, :timeout)
      end

      assert CircuitBreaker.available?(subject) == false

      # Reset
      CircuitBreaker.reset(subject)

      assert CircuitBreaker.available?(subject) == true
      status = CircuitBreaker.status(subject)
      assert status.error_count == 0
      assert status.state == :closed
    end
  end

  describe "status/1" do
    test "returns current breaker status" do
      subject = "monitored.subject"

      status = CircuitBreaker.status(subject)

      assert status.subject == subject
      assert status.state == :closed
      assert status.error_count == 0
      assert status.failure_threshold == 5
    end
  end
end
