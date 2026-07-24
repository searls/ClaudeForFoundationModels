// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import os

/// Process-wide wire-level counters for benchmarking and diagnostics: every
/// streamed request reports its token usage and tool activity here. Callers
/// (the bench harness) reset before a scenario and snapshot after. Counting
/// assumes serial scenarios; concurrent requests still total correctly but
/// can't be attributed per-scenario.
public final class ClaudeRequestMetrics: Sendable {
  public struct Snapshot: Sendable, Equatable {
    public var requests = 0
    /// Client-side tool invocations (dictionary searches).
    public var toolCalls = 0
    /// Server-side tool invocations (web search).
    public var serverToolCalls = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadInputTokens = 0

    public init() {}
  }

  public static let shared = ClaudeRequestMetrics()

  private let state = OSAllocatedUnfairLock(initialState: Snapshot())

  public func reset() {
    state.withLock { $0 = Snapshot() }
  }

  public func snapshot() -> Snapshot {
    state.withLock { $0 }
  }

  package func record(_ event: StreamEvent) {
    state.withLock { snapshot in
      switch event {
      case .messageStart(let message):
        snapshot.requests += 1
        snapshot.inputTokens += message.usage.inputTokens ?? 0
        snapshot.cacheReadInputTokens += message.usage.cacheReadInputTokens ?? 0
      case .messageDelta(_, let usage):
        snapshot.outputTokens += usage.outputTokens
      case .contentBlockStart(_, .toolUse):
        snapshot.toolCalls += 1
      case .contentBlockStart(_, .serverToolUse):
        snapshot.serverToolCalls += 1
      default:
        break
      }
    }
  }
}
