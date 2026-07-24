// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import FoundationModels
import Testing

@testable import ClaudeForFoundationModels

@Generable
private struct OrderedPayload {
  var answer: String
  var commentary: String
}

@Suite struct PromptedOutputTests {
  @Test func `prompted schema preserves declaration order`() throws {
    let text = PromptedSchema.text(from: OrderedPayload.generationSchema)
    let answer = try #require(text.range(of: "\"answer\""))
    let commentary = try #require(text.range(of: "\"commentary\""))
    #expect(answer.lowerBound < commentary.lowerBound)
  }

  @Test func `extractor passes plain JSON through`() {
    #expect(extract(["{\"a\":1}"]) == "{\"a\":1}")
  }

  @Test func `extractor strips markdown fences`() {
    #expect(extract(["```json\n{\"a\":1}\n```"]) == "{\"a\":1}")
  }

  @Test func `extractor strips surrounding prose`() {
    #expect(extract(["Here: {\"a\":1} done."]) == "{\"a\":1}")
  }

  @Test func `extractor survives delta boundaries`() {
    #expect(extract(["```js", "on\n{\"a\":", "[1,2]}", "\n``", "`"]) == "{\"a\":[1,2]}")
  }

  @Test func `extractor ignores braces and escaped quotes inside strings`() {
    let json = "{\"text\":\"say \\\"}\\\" beside {\",\"n\":{\"x\":1}}"
    #expect(extract([json, "junk"]) == json)
  }

  private func extract(_ deltas: [String]) -> String {
    var extractor = JsonStreamExtractor()
    return deltas.map { extractor.filter($0) }.joined()
  }
}
