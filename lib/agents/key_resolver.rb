# frozen_string_literal: true

module Agents
  # Resolves API key specs into plain string values at chat-creation time.
  #
  # A key spec may be:
  #   - String: returned as-is
  #   - Proc:   called with an info Hash, expected to return a String (or nil)
  #   - nil:    falls through to the global RubyLLM config
  #
  # The Proc form is what enables runtime patterns like rotating through a
  # rate-limit-bucketed key pool, tenant-aware lookup, or per-agent checkout —
  # without binding specific keys to specific agents in the SDK itself.
  module KeyResolver
    PROVIDER_KEYS = %i[
      openai_api_key
      anthropic_api_key
      gemini_api_key
      deepseek_api_key
      openrouter_api_key
    ].freeze

    module_function

    # Resolve a single spec to a String (or nil if not configured).
    def resolve_one(spec, info)
      case spec
      when nil    then nil
      when String then spec
      when Proc   then spec.call(info)
      else
        raise ArgumentError, "API key spec must be a String, Proc, or nil; got #{spec.class}"
      end
    end

    # Build a Hash of resolved keys to apply on a per-call RubyLLM config.
    #
    # Resolution order per provider (highest precedence first):
    #   1. per_call_keys[<provider>] — e.g. { openai: "sk-..." }
    #   2. Agents.configuration.<provider>_api_key, when it's a Proc
    #      (Strings live in the global RubyLLM config already; nothing to override.)
    #
    # @param per_call_keys [Hash, nil] Keys keyed by provider symbol (without _api_key suffix)
    # @param agent [Agents::Agent] The agent the chat is being constructed for
    # @param model [String] The model id the chat is being constructed with
    # @param context [Hash] The current run context (passed to Procs for tenant lookup)
    # @return [Hash] Keys like { openai_api_key: "sk-..." } for resolved providers only
    def resolve_for(per_call_keys:, agent:, model:, context:)
      info_base = { agent: agent, model: model, context: context }
      resolved = {}

      PROVIDER_KEYS.each do |key|
        provider = key.to_s.sub(/_api_key$/, "").to_sym
        spec = (per_call_keys && per_call_keys[provider]) || proc_from_global(key)
        next unless spec

        value = resolve_one(spec, info_base.merge(provider: provider))
        resolved[key] = value if value.is_a?(String) && !value.empty?
      end

      resolved
    end

    def proc_from_global(key)
      value = Agents.configuration.send(key)
      value if value.is_a?(Proc)
    end
  end
end
