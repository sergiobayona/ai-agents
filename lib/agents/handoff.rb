# frozen_string_literal: true

module Agents
  # A special tool that enables agents to transfer conversations to other specialized agents.
  # Handoffs are implemented as tools (following OpenAI's pattern) because this allows
  # the LLM to naturally decide when to transfer based on the conversation context.
  #
  # ## How Handoffs Work
  # 1. Agent A is configured with handoff_agents: [Agent B, Agent C]
  # 2. This automatically creates HandoffTool instances for B and C
  # 3. The LLM can call these tools like any other tool
  # 4. The tool signals the handoff through context
  # 5. The Runner detects this and switches to the new agent
  #
  # ## Loop Prevention
  # The library prevents infinite handoff loops by processing only the first handoff
  # tool call in any LLM response. This is handled automatically by the Chat class
  # which detects handoff tools and processes them separately from regular tools.
  #
  # ## Why Tools Instead of Instructions
  # Using tools for handoffs has several advantages:
  # - LLMs reliably use tools when appropriate
  # - Clear schema tells the LLM when each handoff is suitable
  # - No parsing of free text needed
  # - Works consistently across different LLM providers
  #
  # @example Basic handoff setup
  #   billing_agent = Agent.new(name: "Billing", instructions: "Handle payments")
  #   support_agent = Agent.new(name: "Support", instructions: "Technical help")
  #
  #   triage = Agent.new(
  #     name: "Triage",
  #     instructions: "Route users to the right team",
  #     handoff_agents: [billing_agent, support_agent]
  #   )
  #   # Creates tools: handoff_to_billing, handoff_to_support
  #
  # @example How the LLM sees it
  #   # User: "I can't pay my bill"
  #   # LLM thinks: "This is a payment issue, I should transfer to billing"
  #   # LLM calls: handoff_to_billing()
  #   # Runner switches to billing_agent for the next turn
  #
  # @example Multiple handoff handling
  #   # Single LLM response with multiple handoff calls:
  #   # Call 1: handoff_to_support() -> Processed and executed
  #   # Call 2: handoff_to_billing() -> Ignored (only first handoff processed)
  #   # Result: Only transfers to Support Agent
  # Configuration helpers for agent handoffs.
  #
  # Use {Agents::Handoff.to} when wiring handoffs to attach per-edge overrides
  # (custom transfer message, tool description, tool name) to a target agent.
  #
  # @example Custom transfer message
  #   triage.register_handoffs(
  #     billing,
  #     Agents::Handoff.to(support, message: "Connecting you with support.")
  #   )
  #
  # @example Dynamic message via Proc
  #   Agents::Handoff.to(
  #     sales,
  #     message: ->(ctx) { "Hi #{ctx.run_context.context.dig(:state, :name)}, sales here." }
  #   )
  module Handoff
    # Immutable description of one handoff edge. `agent` is the target;
    # `message`, `description`, and `name` are optional overrides applied to
    # the generated {Agents::HandoffTool}.
    Target = Struct.new(:agent, :message, :description, :name, keyword_init: true) do
      # Normalize an argument from {Agents::Agent#register_handoffs} into a Target.
      def self.from(value)
        return value if value.is_a?(Target)

        new(agent: value).freeze
      end
    end

    # Build a handoff Target with optional overrides.
    #
    # @param agent [Agents::Agent] The target agent for this handoff edge.
    # @param message [String, Proc, nil] Custom string injected into the tool
    #   response (and the receiving agent's history). Procs receive the
    #   {Agents::ToolContext} at perform time.
    # @param description [String, nil] Override the LLM-facing tool description.
    # @param name [String, nil] Override the generated tool name.
    # @return [Target] A frozen Target value object.
    def self.to(agent, message: nil, description: nil, name: nil)
      Target.new(agent: agent, message: message, description: description, name: name).freeze
    end
  end

  # Auto-generated tool that performs an agent-to-agent handoff. One instance is
  # built per {Agents::Handoff::Target} registered on the source agent; calling it
  # records `:pending_handoff` in context and halts so {Agents::Runner} can switch
  # agents on the next turn.
  class HandoffTool < Tool
    attr_reader :target_agent

    def initialize(target_agent, message: nil, description: nil, name: nil)
      @target_agent = target_agent
      @message = message
      @tool_name = name || "handoff_to_#{Helpers::NameNormalizer.to_tool_name(target_agent.name)}"
      @tool_description = description || "Transfer conversation to #{target_agent.name}"

      super()
    end

    # Override the auto-generated name to use our specific name
    def name
      @tool_name
    end

    # Override the description
    def description
      @tool_description
    end

    # Use RubyLLM's halt mechanism to stop continuation after handoff
    # Store handoff info in context for Runner to detect and process
    def perform(tool_context)
      # Store handoff information in context for Runner to detect
      # TODO: The following is a race condition that needs to be addressed in future versions
      # If multiple handoff tools execute concurrently, they overwrite each other's pending_handoff data.
      tool_context.run_context.context[:pending_handoff] = {
        target_agent: @target_agent,
        timestamp: Time.now
      }

      halt(resolve_message(tool_context))
    end

    # NOTE: RubyLLM will handle schema generation internally when needed
    # Handoff tools have no parameters, which RubyLLM will detect automatically

    private

    def resolve_message(tool_context)
      case @message
      when nil
        "I'll transfer you to #{@target_agent.name} who can better assist you with this."
      when Proc
        @message.call(tool_context)
      else
        @message.to_s
      end
    end
  end
end
