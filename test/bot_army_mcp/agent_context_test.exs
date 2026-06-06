defmodule BotArmyMcp.AgentContextTest do
  use ExUnit.Case
  @moduletag :unit

  alias BotArmyMcp.AgentContext

  describe "create/0" do
    test "creates new agent context with unique session ID" do
      ctx1 = AgentContext.create()
      ctx2 = AgentContext.create()

      assert ctx1.session_id != ctx2.session_id
      assert ctx1.call_count == 0
      assert ctx1.created_at
    end
  end

  describe "build_envelope/3" do
    test "builds request envelope with agent context" do
      ctx = AgentContext.create()
      tool_name = "gtd.task.list"
      arguments = %{"limit" => 10}

      envelope = AgentContext.build_envelope(ctx, tool_name, arguments)

      assert envelope["command"] == arguments
      assert envelope["agent_context"]["session_id"] == ctx.session_id
      assert envelope["agent_context"]["source"] == "claude_code"
      assert envelope["agent_context"]["tool_name"] == tool_name
      assert envelope["agent_context"]["call_sequence"] == 1
    end
  end

  describe "register_call/1" do
    test "increments call sequence number" do
      ctx = AgentContext.create()

      ctx1 = AgentContext.register_call(ctx)
      assert ctx1.call_count == 1

      ctx2 = AgentContext.register_call(ctx1)
      assert ctx2.call_count == 2

      # Envelope reflects updated sequence
      envelope = AgentContext.build_envelope(ctx2, "test.subject", %{})
      assert envelope["agent_context"]["call_sequence"] == 3
    end
  end

  describe "with_user_context/3" do
    test "associates task with agent session" do
      ctx = AgentContext.create()
      task_id = "task-123"
      metadata = %{"focus_area" => "project_x"}

      ctx_with_user = AgentContext.with_user_context(ctx, task_id, metadata)

      assert ctx_with_user.user_context.task_id == task_id
      assert ctx_with_user.user_context.metadata == metadata
      assert ctx_with_user.user_context.set_at
    end
  end

  describe "clear_user_context/1" do
    test "removes user context" do
      ctx = AgentContext.create()
      ctx_with_user = AgentContext.with_user_context(ctx, "task-123", %{})

      assert Map.has_key?(ctx_with_user, :user_context)

      ctx_cleared = AgentContext.clear_user_context(ctx_with_user)
      assert not Map.has_key?(ctx_cleared, :user_context)
    end
  end

  describe "summary/1" do
    test "returns session summary" do
      ctx = AgentContext.create()
      ctx = AgentContext.register_call(ctx)

      summary = AgentContext.summary(ctx)

      assert summary.session_id == ctx.session_id
      assert summary.created_at == ctx.created_at
      assert summary.calls_made == 1
      assert summary.has_user_context == false
    end
  end
end
