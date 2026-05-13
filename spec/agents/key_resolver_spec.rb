# frozen_string_literal: true

require_relative "../../lib/agents"

RSpec.describe Agents::KeyResolver do
  let(:agent) { instance_double(Agents::Agent, name: "Triage", model: "gpt-4o") }

  before do
    # Reset Agents.configuration between tests so a Proc set in one test
    # does not leak into the next.
    Agents.instance_variable_set(:@configuration, Agents::Configuration.new)
  end

  describe ".resolve_one" do
    it "returns nil for nil" do
      expect(described_class.resolve_one(nil, {})).to be_nil
    end

    it "returns the string for a String spec" do
      expect(described_class.resolve_one("sk-static", {})).to eq("sk-static")
    end

    it "calls a Proc with the info Hash and returns its result" do
      probe = ->(info) { "key-for-#{info[:tenant]}" }
      expect(described_class.resolve_one(probe, { tenant: "acme" })).to eq("key-for-acme")
    end

    it "raises ArgumentError for unsupported spec types" do
      expect { described_class.resolve_one(42, {}) }.to raise_error(ArgumentError, /String, Proc, or nil/)
    end
  end

  describe ".resolve_for" do
    context "with no per-call keys and no Procs in global config" do
      it "returns an empty hash so callers know to skip the override" do
        result = described_class.resolve_for(per_call_keys: nil, agent: agent, model: "gpt-4o", context: {})
        expect(result).to eq({})
      end
    end

    context "with per-call String keys" do
      it "resolves them under the *_api_key suffix" do
        result = described_class.resolve_for(
          per_call_keys: { openai: "sk-call", anthropic: "sk-ant-call" },
          agent: agent,
          model: "gpt-4o",
          context: {}
        )
        expect(result).to eq(openai_api_key: "sk-call", anthropic_api_key: "sk-ant-call")
      end
    end

    context "with a per-call Proc" do
      it "passes provider, agent, model, and context to the Proc" do
        captured = nil
        probe = lambda do |info|
          captured = info
          "sk-proc"
        end

        described_class.resolve_for(
          per_call_keys: { openai: probe },
          agent: agent,
          model: "gpt-4o-mini",
          context: { tenant_id: 7 }
        )

        expect(captured).to eq(provider: :openai, agent: agent, model: "gpt-4o-mini", context: { tenant_id: 7 })
      end

      it "is called once per resolve_for invocation, supporting pool rotation" do
        pool = %w[k1 k2 k3]
        cursor = 0
        rotator = lambda do |_info|
          val = pool[cursor % pool.size]
          cursor += 1
          val
        end

        keys = 3.times.map do
          described_class.resolve_for(
            per_call_keys: { openai: rotator },
            agent: agent,
            model: "gpt-4o",
            context: {}
          )[:openai_api_key]
        end

        expect(keys).to eq(%w[k1 k2 k3])
      end
    end

    context "when a Proc returns nil or empty string" do
      it "drops the provider rather than overriding global config with a blank value" do
        result = described_class.resolve_for(
          per_call_keys: { openai: ->(_info) { nil }, anthropic: ->(_info) { "" } },
          agent: agent,
          model: "gpt-4o",
          context: {}
        )
        expect(result).to eq({})
      end
    end

    context "when a Proc lives in Agents.configuration (per-tenant default)" do
      it "is invoked when no per-call override is given" do
        Agents.configuration.openai_api_key = ->(info) { "global-#{info[:agent].name}" }

        result = described_class.resolve_for(
          per_call_keys: nil, agent: agent, model: "gpt-4o", context: {}
        )

        expect(result).to eq(openai_api_key: "global-Triage")
      end

      it "is overridden by a per-call key" do
        Agents.configuration.openai_api_key = ->(_info) { "global-key" }

        result = described_class.resolve_for(
          per_call_keys: { openai: "per-call-key" },
          agent: agent, model: "gpt-4o", context: {}
        )

        expect(result).to eq(openai_api_key: "per-call-key")
      end
    end

    context "with an unknown provider" do
      it "is silently ignored — only documented providers are resolved" do
        result = described_class.resolve_for(
          per_call_keys: { unknown_provider: "sk-bogus", openai: "sk-real" },
          agent: agent, model: "gpt-4o", context: {}
        )
        expect(result).to eq(openai_api_key: "sk-real")
      end
    end
  end
end
