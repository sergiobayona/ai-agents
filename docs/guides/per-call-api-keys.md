---
layout: default
title: Per-Call API Keys & Multi-Tenant Pools
parent: Guides
nav_order: 8
---

# Per-Call API Keys & Multi-Tenant Pools

Pass provider API keys per call instead of (or in addition to) the global
`Agents.configure` block. This lets you:

- Use a **different key per tenant** — for billing, cost tracking, quota
  isolation.
- Rotate through a **rate-limit-aware key pool** — the resolver fires once
  per chat construction (initial run + each handoff), giving a key pool the
  natural seam to check out a fresh key.
- **Look up keys at runtime** from a vault, encrypted DB column, or
  per-tenant config — without putting them in process-global state.

The classic global config pattern still works exactly as before. This guide
covers what to do *in addition* to that when one global key isn't enough.

## When to reach for this

| Scenario | Recommended approach |
|---|---|
| Single-tenant app, one key per provider | Stick with `Agents.configure` — nothing here applies |
| Multi-tenant SaaS, distinct key per organization | Per-call `api_keys:` String values |
| Hitting per-key rate limits, want to spread load across N keys | Per-call `api_keys:` with a Proc that does pool checkout |
| Per-tenant default + occasional overrides | Proc in `Agents.configure` (per-tenant default) + per-call `api_keys:` (override) |

## The two new mechanisms

### 1. `api_keys:` kwarg on `runner.run`

Pass a Hash of provider symbols (without the `_api_key` suffix) → key spec:

```ruby
result = runner.run(
  "I have a billing question",
  context: ctx,
  api_keys: { openai: tenant.openai_api_key }
)
```

A spec can be:

- a **String** — used as-is for that provider on this call
- a **Proc** — called with `{provider:, agent:, model:, context:}`, must
  return a String (or nil to skip)
- omitted / `nil` — falls through to the global `Agents.configure` value

Recognized provider keys: `:openai`, `:anthropic`, `:gemini`, `:deepseek`,
`:openrouter`. Unknown providers in the Hash are silently ignored.

### 2. Procs in `Agents.configure`

You can assign a Proc to any `*_api_key` field in the global config:

```ruby
Agents.configure do |config|
  config.openai_api_key = ->(info) { TenantKeyVault.fetch(:openai, info[:context][:tenant_id]) }
end
```

A Proc here is **not** pushed into RubyLLM's global config — it's resolved
at runtime per chat. String values continue to work as before and *are*
pushed to RubyLLM globally.

## Resolution order

For each provider, the resolver checks (highest to lowest precedence):

1. `api_keys[<provider>]` from the per-call kwarg
2. `Agents.configuration.<provider>_api_key` — only if it's a Proc
3. The global RubyLLM config (set from a String in `Agents.configure`, or
   directly via `RubyLLM.configure`)

If steps 1 and 2 both miss, no per-call override is built and `RubyLLM::Chat`
uses the global config — the pre-existing back-compat path.

## Recipe: per-tenant keys (static lookup)

The simplest case. Pass the tenant's key string per request:

```ruby
class ChatController < ApplicationController
  def create
    runner = AgentBuilder.runner_for(current_organization)
    ctx = session[:agent_context] || {}

    result = runner.run(
      params[:message],
      context: ctx,
      api_keys: {
        openai: current_organization.openai_api_key,
        anthropic: current_organization.anthropic_api_key
      }.compact
    )

    session[:agent_context] = result.context
    render json: { reply: result.output }
  end
end
```

`.compact` is important — if a tenant only has an OpenAI key, omit the
Anthropic entry rather than pass `nil`, so the resolver falls through to
your global default for that provider (or no override at all).

## Recipe: rate-limit-aware key pool

The pool problem: one key for OpenAI hits 429s under load. You have N keys
and want to spread requests across them.

```ruby
class OpenAIKeyPool
  def initialize(keys)
    @keys = keys
    @cursor = 0
    @mutex = Mutex.new
  end

  # Round-robin checkout. Real implementations may track per-key usage,
  # last 429 timestamp, etc.
  def checkout
    @mutex.synchronize do
      key = @keys[@cursor % @keys.size]
      @cursor += 1
      key
    end
  end
end

POOL = OpenAIKeyPool.new(ENV.fetch("OPENAI_KEY_POOL").split(","))

result = runner.run(
  user_input,
  api_keys: { openai: ->(_info) { POOL.checkout } }
)
```

The Proc fires once when the chat is created and once **at each handoff**.
That's typically the right granularity for spreading load: a multi-turn
conversation where the LLM calls the model many times within the same
agent reuses the same key (so the conversation stays coherent on one
client connection), and each handoff to a new agent gets a fresh checkout.

If you need **finer-grained rotation** (e.g. per LLM call), see *Caveats*
below.

## Recipe: tenant-aware default with per-call override

You can have a sensible default Proc in the global config and still pass
per-call overrides for special cases (admin tools, internal jobs):

```ruby
Agents.configure do |config|
  config.openai_api_key = lambda do |info|
    tenant_id = info[:context][:tenant_id]
    Rails.cache.fetch("openai_key:#{tenant_id}") { Tenant.find(tenant_id).openai_api_key }
  end
end

# Tenant flow — Proc in global config resolves the key.
runner.run(input, context: { tenant_id: 42 })

# Internal flow — explicit override wins.
runner.run(input, context: { tenant_id: 42 }, api_keys: { openai: ENV["INTERNAL_OPENAI_KEY"] })
```

## What the Proc receives

The Proc is called with one positional argument — a Hash:

```ruby
{
  provider: :openai,             # provider symbol the resolver is asking about
  agent:    <Agents::Agent>,     # the agent whose chat is being constructed
  model:    "gpt-4o",            # the model id about to be used
  context:  { tenant_id: 42 }    # the run context (your :tenant_id, etc. live here)
}
```

The Proc must return a String, an empty String, or nil. Empty strings and
nil are treated as "no override" so they don't accidentally clobber a valid
global key.

## Per-call vs. per-agent

This API deliberately does **not** put `api_key:` on the `Agent` class.
Reasons:

- **Cost tracking** is naturally per-tenant, not per-agent. Tying a key to
  an agent makes per-tenant billing awkward.
- **Rate-limit pools** want to rotate across agents, not be partitioned by
  agent.
- The Proc form lets you implement either pattern without the SDK
  taking a position. If you want per-agent keys, your Proc can dispatch on
  `info[:agent].name`.

```ruby
PER_AGENT_KEYS = {
  "Triage"  => ENV["TRIAGE_OPENAI_KEY"],
  "Billing" => ENV["BILLING_OPENAI_KEY"],
  "Support" => ENV["SUPPORT_OPENAI_KEY"]
}

runner.run(input, api_keys: { openai: ->(info) { PER_AGENT_KEYS[info[:agent].name] } })
```

## When the Proc fires

| Event | Proc called? |
|---|---|
| `runner.run(...)` — initial chat created | Yes |
| Handoff to another agent | Yes (re-resolved against the new agent) |
| Continuing a tool-call loop (no handoff) | No (same chat instance) |
| Multi-turn conversation across HTTP requests | Yes, once per request |

In other words: **once per chat construction**. If the same chat keeps
running multiple LLM calls in the agent loop (because the agent calls
tools, gets tool results, asks again), they share the resolved key.

## Persistence: keys are not stored in context

The resolved key value lives only on the in-memory `RubyLLM::Context` of
that chat. It is **not** written into the `result.context` you persist —
which is what you want, since you don't want raw API keys ending up in
session cookies or a database column. Pass `api_keys:` again on the next
turn.

## Caveats and limits

### Mid-conversation 429s

A single agent loop reuses the key the Proc returned at chat construction.
If you're rate-limited mid-conversation (e.g. you're streaming many tool
results back), the loop won't rotate keys.

If this matters, the next granularity is via `on_chat_created` and RubyLLM's
`on_end_message` hook — you can detect rate-limit responses and reconstruct
the chat with a fresh key. That's not built in here.

### Provider scope

Currently scoped to `*_api_key` providers: `openai`, `anthropic`, `gemini`,
`deepseek`, `openrouter`. AWS Bedrock auth (multi-field: api key + secret +
region + session token) isn't covered — use `Agents.configure` for those.

### Synchronous resolution

The Proc is called synchronously during chat construction. If you call out
to a network service or vault inside the Proc, that latency is on every
request. Cache aggressively (`Rails.cache.fetch`, in-process LRU) — Procs
are designed to make caching easy.

### Empty-string trap

If your vault returns `""` for an unset key, the resolver intentionally
treats that as "no override" and falls through to global config. This is a
safety net so a misconfigured vault doesn't silently authenticate every
call as the empty key. If you want empty to mean "fail loudly," check
explicitly inside your Proc and raise.

## Reference: shape

```ruby
runner.run(
  input,
  context:   {},     # your usual conversation context
  api_keys:  {      # NEW — optional Hash of provider => spec
    openai:     "sk-...",                  # String spec
    anthropic:  ->(info) { "sk-ant-..." }, # Proc spec
    gemini:     nil                        # nil = no override (fall through)
  }
)
```

```ruby
Agents.configure do |config|
  config.openai_api_key = "sk-..."                       # String — pushed to RubyLLM globally
  config.anthropic_api_key = ->(info) { vault_lookup(info) } # Proc — resolved per call
end
```

## See also

- [Custom Request Headers](request-headers.html) — for non-auth headers
- [State Persistence](state-persistence.html) — for serializing context
  across requests (and why keys aren't part of it)
- [Provider-Specific Params](provider-params.html) — for `service_tier`
  and similar
