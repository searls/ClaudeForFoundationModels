// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

/// Salvages the JSON object from a prompted structured-output text stream.
///
/// Without constrained decoding the model occasionally wraps its JSON in
/// markdown fences or a line of preamble; the framework parses cumulative
/// partial JSON, so a single leading backtick poisons every snapshot and the
/// response silently decodes to nothing. This filter passes through exactly
/// one balanced top-level JSON object: everything before its opening `{` and
/// after its closing `}` is dropped. String literals and escapes are tracked
/// so braces inside values don't fool the depth count.
///
struct JsonStreamExtractor {
  private enum State {
    case seeking
    case streaming
    case done
  }

  private enum Container {
    case object(expectingKey: Bool)
    case array
  }

  private enum StringRole {
    case objectKey
    case value
  }

  private struct StringState {
    let role: StringRole
    var escaped = false
  }

  private struct PendingQuote {
    let role: StringRole
    var whitespace: [Unicode.Scalar] = []
  }

  private var state: State = .seeking
  private var containers: [Container] = []
  private var stringState: StringState?
  private var pendingQuote: PendingQuote?

  init() {}

  /// Feed one text delta; returns the substring that should pass through.
  mutating func filter(_ text: String) -> String {
    var output = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      switch state {
      case .seeking:
        if scalar == "{" {
          state = .streaming
          containers = [.object(expectingKey: true)]
          output.append(scalar)
        }
      case .streaming:
        if var pendingQuote {
          if Self.isJsonWhitespace(scalar) {
            pendingQuote.whitespace.append(scalar)
            self.pendingQuote = pendingQuote
          } else {
            resolve(pendingQuote, followedBy: scalar, into: &output)
          }
        } else if stringState != nil {
          consumeStringScalar(scalar, into: &output)
        } else {
          consumeStructuralScalar(scalar, into: &output)
          if case .done = state {
            return String(String.UnicodeScalarView(output))
          }
        }
      case .done:
        return String(String.UnicodeScalarView(output))
      }
    }
    return String(String.UnicodeScalarView(output))
  }

  private mutating func consumeStringScalar(
    _ scalar: Unicode.Scalar,
    into output: inout String.UnicodeScalarView
  ) {
    guard var stringState else { return }
    if stringState.escaped {
      output.append(scalar)
      stringState.escaped = false
      self.stringState = stringState
    } else {
      switch scalar {
      case "\\":
        output.append(scalar)
        stringState.escaped = true
        self.stringState = stringState
      case "\"":
        pendingQuote = PendingQuote(role: stringState.role)
      default:
        output.append(scalar)
      }
    }
  }

  private mutating func resolve(
    _ quote: PendingQuote,
    followedBy scalar: Unicode.Scalar,
    into output: inout String.UnicodeScalarView
  ) {
    pendingQuote = nil
    if canCloseString(role: quote.role, followedBy: scalar) {
      output.append("\"")
      output.append(contentsOf: quote.whitespace)
      stringState = nil
      markStringClosed(quote.role)
      consumeStructuralScalar(scalar, into: &output)
    } else {
      output.append("\\")
      output.append("\"")
      output.append(contentsOf: quote.whitespace)
      stringState = StringState(role: quote.role)
      consumeStringScalar(scalar, into: &output)
    }
  }

  private func canCloseString(
    role: StringRole,
    followedBy scalar: Unicode.Scalar
  ) -> Bool {
    switch role {
    case .objectKey:
      scalar == ":"
    case .value:
      scalar == "," || scalar == "}" || scalar == "]"
    }
  }

  private mutating func consumeStructuralScalar(
    _ scalar: Unicode.Scalar,
    into output: inout String.UnicodeScalarView
  ) {
    output.append(scalar)
    switch scalar {
    case "\"":
      stringState = StringState(role: nextStringRole())
    case "{":
      containers.append(.object(expectingKey: true))
    case "[":
      containers.append(.array)
    case ",":
      guard let container = containers.last else { return }
      switch container {
      case .object:
        containers[containers.count - 1] = .object(expectingKey: true)
      case .array:
        break
      }
    case "}":
      closeContainer()
    case "]":
      closeContainer()
    default:
      break
    }
  }

  private func nextStringRole() -> StringRole {
    guard case .object(expectingKey: true) = containers.last else { return .value }
    return .objectKey
  }

  private mutating func markStringClosed(_ role: StringRole) {
    guard !containers.isEmpty, case .object = containers.last else { return }
    switch role {
    case .objectKey, .value:
      containers[containers.count - 1] = .object(expectingKey: false)
    }
  }

  private mutating func closeContainer() {
    guard !containers.isEmpty else { return }
    containers.removeLast()
    if containers.isEmpty {
      state = .done
    } else if case .object = containers.last {
      containers[containers.count - 1] = .object(expectingKey: false)
    }
  }

  private static func isJsonWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
  }
}
