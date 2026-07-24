// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI

/// Rebuilds a streamed assistant turn so `pause_turn` can replay it verbatim.
struct TurnAccumulator {
  private(set) var stopReason: StopReason?
  private var open: [Int: OpenBlock] = [:]
  private var finished: [(Int, ContentBlock)] = []

  private enum OpenBlock {
    case text(String)
    case thinking(String, String?)
    case toolUse(String, String, JSONValue, String)
    case serverToolUse(String, String, JSONValue, String)
    case whole(ContentBlock)
    case dropped
  }

  mutating func consume(_ event: StreamEvent) {
    switch event {
    case .contentBlockStart(let index, let block):
      open[index] = Self.seed(block)
    case .contentBlockDelta(let index, let delta):
      guard let block = open[index] else { return }
      open[index] = Self.applying(delta, to: block)
    case .contentBlockStop(let index):
      guard let block = open.removeValue(forKey: index),
        let finalized = Self.finalize(block)
      else { return }
      finished.append((index, finalized))
    case .messageDelta(let reason, _):
      if let reason { stopReason = reason }
    case .messageStart, .messageStop, .ping, .error, .unknown:
      break
    }
  }

  mutating func assistantBlocks() -> [ContentBlock] {
    for (index, block) in open {
      if let finalized = Self.finalize(block) {
        finished.append((index, finalized))
      }
    }
    open.removeAll()
    return finished.sorted { $0.0 < $1.0 }.map(\.1)
  }

  private static func seed(_ block: ContentBlock) -> OpenBlock {
    switch block {
    case .text(let text): .text(text)
    case .thinking(let text, let signature): .thinking(text, signature)
    case .toolUse(let id, let name, let input): .toolUse(id, name, input, "")
    case .serverToolUse(let id, let name, let input): .serverToolUse(id, name, input, "")
    case .redactedThinking, .serverToolResult, .image, .toolResult: .whole(block)
    case .unknown: .dropped
    }
  }

  private static func applying(_ delta: StreamEvent.Delta, to block: OpenBlock) -> OpenBlock {
    switch (delta, block) {
    case (.text(let chunk), .text(let text)):
      .text(text + chunk)
    case (.thinking(let chunk), .thinking(let text, let signature)):
      .thinking(text + chunk, signature)
    case (.signature(let chunk), .thinking(let text, let signature)):
      .thinking(text, (signature ?? "") + chunk)
    case (.inputJSON(let chunk), .toolUse(let id, let name, let initial, let input)):
      .toolUse(id, name, initial, input + chunk)
    case (.inputJSON(let chunk), .serverToolUse(let id, let name, let initial, let input)):
      .serverToolUse(id, name, initial, input + chunk)
    default:
      block
    }
  }

  private static func finalize(_ block: OpenBlock) -> ContentBlock? {
    switch block {
    case .text(let text): text.isEmpty ? nil : .text(text)
    case .thinking(let text, let signature):
      text.isEmpty ? nil : .thinking(text, signature: signature)
    case .toolUse(let id, let name, let initial, let input):
      .toolUse(id: id, name: name, input: decoded(input, fallback: initial))
    case .serverToolUse(let id, let name, let initial, let input):
      .serverToolUse(id: id, name: name, input: decoded(input, fallback: initial))
    case .whole(let block): block
    case .dropped: nil
    }
  }

  private static func decoded(_ input: String, fallback: JSONValue) -> JSONValue {
    input.isEmpty ? fallback : JSONValue.parsed(input) ?? fallback
  }
}
