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
    case streaming(depth: Int, inString: Bool, escaped: Bool)
    case done
  }

  private var state: State = .seeking

  init() {}

  /// Feed one text delta; returns the substring that should pass through.
  mutating func filter(_ text: String) -> String {
    var output = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      switch state {
      case .seeking:
        if scalar == "{" {
          state = .streaming(depth: 1, inString: false, escaped: false)
          output.append(scalar)
        }
      case .streaming(var depth, var inString, var escaped):
        output.append(scalar)
        if escaped {
          escaped = false
        } else if inString {
          switch scalar {
          case "\\": escaped = true
          case "\"": inString = false
          default: break
          }
        } else {
          switch scalar {
          case "\"": inString = true
          case "{": depth += 1
          case "}":
            depth -= 1
            if depth == 0 {
              state = .done
              return String(String.UnicodeScalarView(output))
            }
          default: break
          }
        }
        state = .streaming(depth: depth, inString: inString, escaped: escaped)
      case .done:
        return String(String.UnicodeScalarView(output))
      }
    }
    return String(String.UnicodeScalarView(output))
  }
}
