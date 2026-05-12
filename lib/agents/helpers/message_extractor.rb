# frozen_string_literal: true

require "set"

# Service object responsible for extracting and formatting conversation messages
# from RubyLLM chat objects into a format suitable for persistence and context restoration.
#
# Handles different message types:
# - User messages: Basic content preservation
# - Assistant messages: Includes agent attribution and tool calls
# - Tool result messages: Links back to original tool calls
#
# Handoff bookkeeping (assistant messages whose only tool call is a `handoff_to_*`
# tool, plus the matching tool-result envelope) is filtered out: the routing
# decision is captured by the agent_name attribution on subsequent messages, and
# preserving the handoff tool_call in persisted history would later be replayed
# against an agent that no longer exposes that tool.
#
# @example Extract messages from a chat
#   messages = Agents::Helpers::MessageExtractor.extract_messages(chat, current_agent)
#   #=> [
#     { role: :user, content: "Hello" },
#     { role: :assistant, content: "Hi!", agent_name: "Support", tool_calls: [...] },
#     { role: :tool, content: "Result", tool_call_id: "call_123" }
#   ]
module Agents
  module Helpers
    module MessageExtractor
      HANDOFF_TOOL_PREFIX = "handoff_to_"

      module_function

      # Check if content is considered empty (handles both String and Hash content)
      #
      # @param content [String, Hash, nil] The content to check
      # @return [Boolean] true if content is empty, false otherwise
      def content_empty?(content)
        case content
        when String
          content.strip.empty?
        when Hash
          content.empty?
        else
          content.nil?
        end
      end

      # Extract messages from a chat object for conversation history persistence
      #
      # @param chat [Object] Chat object that responds to :messages
      # @param current_agent [Agent] The agent currently handling the conversation
      # @return [Array<Hash>] Array of message hashes suitable for persistence
      def extract_messages(chat, current_agent)
        return [] unless chat.respond_to?(:messages)

        handoff_call_ids = collect_handoff_call_ids(chat.messages)

        chat.messages.filter_map do |msg|
          case msg.role
          when :user, :assistant
            extract_user_or_assistant_message(msg, current_agent, handoff_call_ids)
          when :tool
            next if msg.respond_to?(:tool_call_id) && handoff_call_ids.include?(msg.tool_call_id)

            extract_tool_message(msg)
          end
        end
      end

      def collect_handoff_call_ids(messages)
        ids = Set.new
        messages.each do |msg|
          next unless assistant_tool_calls?(msg)

          msg.tool_calls.each do |id, tc|
            ids << id if tc.name.to_s.start_with?(HANDOFF_TOOL_PREFIX)
          end
        end
        ids
      end

      def filter_handoff_tool_calls(msg, handoff_call_ids)
        return [] unless assistant_tool_calls?(msg)

        msg.tool_calls.values.reject { |tc| handoff_call_ids.include?(tc.id) }
      end

      def extract_user_or_assistant_message(msg, current_agent, handoff_call_ids = nil)
        handoff_call_ids ||= Set.new
        content_present = message_content?(msg)
        remaining_tool_calls = filter_handoff_tool_calls(msg, handoff_call_ids)
        tool_calls_present = remaining_tool_calls.any?
        return nil unless content_present || tool_calls_present

        message = {
          role: msg.role,
          content: content_present ? msg.content : ""
        }

        return message unless msg.role == :assistant

        message[:agent_name] = current_agent.name if current_agent
        # RubyLLM stores tool_calls as Hash with call_id => ToolCall object
        # Reference: RubyLLM::StreamAccumulator#tool_calls_from_stream
        message[:tool_calls] = remaining_tool_calls.map(&:to_h) if tool_calls_present
        message
      end

      def message_content?(msg)
        msg.content && !content_empty?(msg.content)
      end

      def assistant_tool_calls?(msg)
        msg.role == :assistant && msg.tool_call? && msg.tool_calls && !msg.tool_calls.empty?
      end

      def extract_tool_message(msg)
        return nil unless msg.tool_result?

        {
          role: msg.role,
          content: msg.content,
          tool_call_id: msg.tool_call_id
        }
      end

      private_class_method :collect_handoff_call_ids, :filter_handoff_tool_calls,
                           :extract_user_or_assistant_message, :message_content?,
                           :assistant_tool_calls?, :extract_tool_message
    end
  end
end
