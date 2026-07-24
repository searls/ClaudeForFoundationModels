// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import FoundationModels

/// Serializes a `GenerationSchema` as prompt text with object properties in
/// DECLARATION order (the framework's `x-order` annotation) instead of the
/// wire schema's alphabetical order. Prompted models emit properties in the
/// order the schema lists them, and streaming UX depends on the payload's
/// main content generating before its trailing commentary fields.
///
enum PromptedSchema {
  static func text(from schema: GenerationSchema) -> String {
    guard let raw = JSONValue.encoded(schema) else { return "{\"type\": \"object\"}" }
    return render(raw, propertyOrder: nil)
  }

  /// Keys worth showing the model, rendered in a stable, readable order.
  private static let keyOrder = [
    "type", "description", "required", "properties", "items", "enum", "const",
    "anyOf", "allOf", "oneOf", "$ref", "format", "additionalProperties",
    "$defs", "definitions",
  ]
  private static let mapValuedKeys: Set<String> = ["properties", "$defs", "definitions"]

  private static func render(_ value: JSONValue, propertyOrder: [String]?) -> String {
    switch value {
    case .object(let dict):
      let declared = stringArray(dict["x-order"])
      var parts: [String] = []
      for key in keyOrder {
        guard let child = dict[key] else { continue }
        if mapValuedKeys.contains(key), case .object(let nested) = child {
          let names = ordered(Array(nested.keys), by: key == "properties" ? declared : nil)
          let body = names.compactMap { name in
            nested[name].map { "\(escaped(name)): \(render($0, propertyOrder: nil))" }
          }
          parts.append("\(escaped(key)): {\(body.joined(separator: ", "))}")
        } else if key == "required" {
          // Mirror the property order so "first listed" is unambiguous.
          let names = ordered(stringArray(child), by: declared)
          parts.append("\(escaped(key)): [\(names.map(escaped).joined(separator: ", "))]")
        } else {
          parts.append("\(escaped(key)): \(render(child, propertyOrder: nil))")
        }
      }
      return "{\(parts.joined(separator: ", "))}"
    case .array(let items):
      return "[\(items.map { render($0, propertyOrder: nil) }.joined(separator: ", "))]"
    case .string(let string):
      return escaped(string)
    case .number(let number):
      return number == number.rounded() && number.magnitude < 1e15
        ? String(Int(number)) : String(number)
    case .bool(let bool):
      return bool ? "true" : "false"
    case .null:
      return "null"
    }
  }

  private static func ordered(_ names: [String], by declared: [String]?) -> [String] {
    guard let declared, !declared.isEmpty else { return names.sorted() }
    let rank = Dictionary(uniqueKeysWithValues: declared.enumerated().map { ($1, $0) })
    return names.sorted {
      (rank[$0] ?? Int.max, $0) < (rank[$1] ?? Int.max, $1)
    }
  }

  private static func stringArray(_ value: JSONValue?) -> [String] {
    guard case .array(let items) = value else { return [] }
    return items.compactMap {
      if case .string(let s) = $0 { return s }
      return nil
    }
  }

  private static func escaped(_ string: String) -> String {
    var out = "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\t": out += "\\t"
      case "\r": out += "\\r"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }
}
