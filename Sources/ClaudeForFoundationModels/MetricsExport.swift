// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI

/// Public facade over the wire-level request metrics, for benchmarking
/// harnesses that depend on the umbrella module.
public enum ClaudeWireMetrics {
  public struct Snapshot: Sendable, Equatable {
    public let requests: Int
    public let toolCalls: Int
    public let serverToolCalls: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadInputTokens: Int
  }

  public static func reset() {
    ClaudeRequestMetrics.shared.reset()
  }

  public static func snapshot() -> Snapshot {
    let raw = ClaudeRequestMetrics.shared.snapshot()
    return Snapshot(
      requests: raw.requests,
      toolCalls: raw.toolCalls,
      serverToolCalls: raw.serverToolCalls,
      inputTokens: raw.inputTokens,
      outputTokens: raw.outputTokens,
      cacheReadInputTokens: raw.cacheReadInputTokens
    )
  }
}
