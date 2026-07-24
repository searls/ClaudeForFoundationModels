// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import Foundation
import Testing

@testable import ClaudeForFoundationModels

@Suite struct TurnAccumulatorTests {
  @Test func `records pause turn and rebuilds streamed text`() throws {
    var accumulator = try accumulated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"message_delta","delta":{"stop_reason":"pause_turn"},"usage":{"output_tokens":2}}"#,
    ])
    #expect(accumulator.stopReason == .pauseTurn)
    #expect(accumulator.assistantBlocks() == [.text("Hello, world")])
  }

  @Test func `rebuilds thinking with its signature`() throws {
    var accumulator = try accumulated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"AAEC"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
    ])
    #expect(accumulator.assistantBlocks() == [.thinking("hmm", signature: "AAEC")])
  }

  @Test func `rebuilds server tool calls and results`() throws {
    var accumulator = try accumulated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{}}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"weather\"}"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srv_1","content":[]}}"#,
      #"{"type":"content_block_stop","index":1}"#,
    ])
    #expect(
      accumulator.assistantBlocks() == [
        .serverToolUse(
          id: "srv_1",
          name: "web_search",
          input: .object(["query": .string("weather")])
        ),
        .serverToolResult(toolUseID: "srv_1", type: "web_search_tool_result", content: .array([])),
      ]
    )
  }

  @Test func `finalizes open blocks and drops empty ones`() throws {
    var accumulator = try accumulated([
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"unfinished"}}"#,
    ])
    #expect(accumulator.assistantBlocks() == [.text("unfinished")])
  }

  private func accumulated(_ lines: [String]) throws -> TurnAccumulator {
    var accumulator = TurnAccumulator()
    for line in lines {
      accumulator.consume(try JSONDecoder().decode(StreamEvent.self, from: Data(line.utf8)))
    }
    return accumulator
  }
}
