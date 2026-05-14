# frozen_string_literal: true

require_relative "../../lib/agents"

RSpec.describe Agents::HandoffTool do
  let(:target_agent) { instance_double(Agents::Agent, name: "Support Agent") }
  let(:handoff_tool) { described_class.new(target_agent) }
  let(:context) { {} }

  describe "#initialize" do
    it "creates handoff tool with target agent" do
      expect(handoff_tool.target_agent).to eq(target_agent)
    end

    it "sets tool name based on target agent" do
      expect(handoff_tool.name).to eq("handoff_to_support_agent")
    end

    context "with special characters in agent name" do
      it "strips special characters from tool name" do
        agent = instance_double(Agents::Agent, name: "Billing-Agent!")
        tool = described_class.new(agent)

        expect(tool.name).to eq("handoff_to_billingagent")
      end
    end

    it "sets description for handoff" do
      expected_description = "Transfer conversation to Support Agent"
      expect(handoff_tool.description).to eq(expected_description)
    end
  end

  describe "#perform" do
    it "returns halt with transfer message" do
      tool_context = instance_double(Agents::ToolContext)
      run_context = instance_double(Agents::RunContext)
      context_hash = {}

      allow(tool_context).to receive(:run_context).and_return(run_context)
      allow(run_context).to receive(:context).and_return(context_hash)

      result = handoff_tool.perform(tool_context)

      expect(result).to be_a(RubyLLM::Tool::Halt)
      expect(result.content).to eq("I'll transfer you to Support Agent who can better assist you with this.")
      expect(context_hash[:pending_handoff]).to include(target_agent: target_agent)
    end
  end

  describe "#target_agent" do
    it "returns the target agent" do
      expect(handoff_tool.target_agent).to be(target_agent)
    end
  end

  describe "custom overrides" do
    let(:tool_context) { instance_double(Agents::ToolContext) }
    let(:run_context) { instance_double(Agents::RunContext) }
    let(:context_hash) { {} }

    before do
      allow(tool_context).to receive(:run_context).and_return(run_context)
      allow(run_context).to receive(:context).and_return(context_hash)
    end

    it "uses custom string message in Halt content" do
      tool = described_class.new(target_agent, message: "Connecting you with support.")

      result = tool.perform(tool_context)

      expect(result.content).to eq("Connecting you with support.")
    end

    it "still records pending_handoff when a custom message is set" do
      tool = described_class.new(target_agent, message: "Connecting you with support.")

      tool.perform(tool_context)

      expect(context_hash[:pending_handoff]).to include(target_agent: target_agent)
    end

    it "evaluates Proc messages with the tool_context at perform time" do
      tool = described_class.new(
        target_agent,
        message: ->(ctx) { "ctx=#{ctx.equal?(tool_context)}" }
      )

      result = tool.perform(tool_context)

      expect(result.content).to eq("ctx=true")
    end

    it "overrides the tool description" do
      tool = described_class.new(target_agent, description: "Send billing questions here")

      expect(tool.description).to eq("Send billing questions here")
    end

    it "overrides the tool name" do
      tool = described_class.new(target_agent, name: "escalate_to_support")

      expect(tool.name).to eq("escalate_to_support")
    end

    it "preserves the default message when none is provided" do
      tool = described_class.new(target_agent)

      result = tool.perform(tool_context)

      expect(result.content).to eq("I'll transfer you to Support Agent who can better assist you with this.")
    end
  end
end

RSpec.describe Agents::Handoff do
  let(:target_agent) { instance_double(Agents::Agent, name: "Support") }

  describe ".to" do
    it "wraps an agent in a Handoff::Target with the given message" do
      target = described_class.to(target_agent, message: "Hi from override")

      expect(target).to be_a(Agents::Handoff::Target)
      expect(target.agent).to be(target_agent)
      expect(target.message).to eq("Hi from override")
    end

    it "carries description and name overrides" do
      target = described_class.to(target_agent, description: "desc", name: "custom_name")

      expect(target.description).to eq("desc")
      expect(target.name).to eq("custom_name")
    end

    it "freezes the returned target" do
      target = described_class.to(target_agent, message: "x")

      expect(target).to be_frozen
    end
  end

  describe "Target.from" do
    it "passes Target through unchanged" do
      target = described_class.to(target_agent, message: "x")

      expect(described_class::Target.from(target)).to be(target)
    end

    it "wraps a bare Agent into a default Target" do
      result = described_class::Target.from(target_agent)

      expect(result).to be_a(Agents::Handoff::Target)
      expect(result.agent).to be(target_agent)
      expect(result.message).to be_nil
    end
  end
end

# TODO: HandoffResult and AgentResponse classes need to be implemented
# These were referenced in the original design but aren't part of current implementation
