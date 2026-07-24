// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// Thin HTTP client for `POST /v1/messages`.
package struct ClaudeClient: Sendable {
  /// Wire-level timing, so a slow lookup on a detached device is diagnosable
  /// from Console: was it the API sitting silent before the first byte
  /// (schema grammar compilation, congestion) or slow generation?
  private static let logger = Logger(subsystem: "co.searls.LipGloss", category: "claude-api")

  package let configuration: Configuration
  private let transport: any HTTPTransport

  /// Production initializer — talks to the API over `URLSession`.
  package init(configuration: Configuration, session: URLSession = .shared) {
    self.init(configuration: configuration, transport: URLSessionTransport(session: session))
  }

  /// Inject a transport. Production passes ``URLSessionTransport``; tests pass
  /// a fake so the client can be exercised without a network.
  package init(configuration: Configuration, transport: any HTTPTransport) {
    self.configuration = configuration
    self.transport = transport
  }

  // MARK: - Non-streaming

  /// - Parameter headers: Additional headers for this request, merged over
  ///   the configuration's defaults. Use for rotating credentials
  ///   (`Authorization`), beta opt-ins (`anthropic-beta`), or telemetry.
  package func send(
    _ request: MessagesRequest,
    headers: [String: String] = [:]
  ) async throws -> MessagesResponse {
    var req = request
    req.stream = false
    let started = Date.now
    let (data, response) = try await transport.data(for: urlRequest(for: req, headers: headers))
    let total = Date.now.timeIntervalSince(started)
    Self.logger.info(
      "send \(req.model, privacy: .public) total=\(total, format: .fixed(precision: 2))s"
    )
    #if DEBUG
    print("[claude-api] send \(req.model) total=\(String(format: "%.2f", total))s")
    #endif
    try Self.check(response, body: data)
    return try JSONDecoder().decode(MessagesResponse.self, from: data)
  }

  // MARK: - Streaming

  /// Streams the response as it generates. HTTP error statuses and SSE
  /// `error` events both surface by throwing ``APIError`` from the stream.
  /// `headers` behaves as in ``send(_:headers:)``.
  package func stream(
    _ request: MessagesRequest,
    headers: [String: String] = [:]
  ) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var req = request
          req.stream = true
          let started = Date.now
          let (bytes, response) = try await transport.bytes(
            for: urlRequest(for: req, headers: headers)
          )
          if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            // Error responses arrive as a JSON body, not SSE.
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            try Self.check(response, body: body)
          }
          // The request-id ties a slow request to Anthropic's server-side
          // trace — the one fact that makes a latency report actionable.
          let requestID =
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "request-id") ?? "-"
          var awaitingFirstEvent = true
          for try await event in SSEParser.events(from: bytes) {
            ClaudeRequestMetrics.shared.record(event)
            if awaitingFirstEvent {
              awaitingFirstEvent = false
              let ttfb = Date.now.timeIntervalSince(started)
              Self.logger.info(
                "stream \(req.model, privacy: .public) ttfb=\(ttfb, format: .fixed(precision: 2))s request-id=\(requestID, privacy: .public)"
              )
              #if DEBUG
              print(
                "[claude-api] stream \(req.model) ttfb=\(String(format: "%.2f", ttfb))s request-id=\(requestID)"
              )
              #endif
            }
            continuation.yield(event)
          }
          let total = Date.now.timeIntervalSince(started)
          Self.logger.info(
            "stream \(req.model, privacy: .public) total=\(total, format: .fixed(precision: 2))s"
          )
          #if DEBUG
          print("[claude-api] stream \(req.model) total=\(String(format: "%.2f", total))s")
          #endif
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Convenience over ``stream(_:headers:)``: yields the accumulated text
  /// after each delta — snapshots of the full text so far, not increments.
  package func streamText(
    _ request: MessagesRequest,
    headers: [String: String] = [:]
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var acc = ""
          for try await event in stream(request, headers: headers) {
            if case .contentBlockDelta(_, .text(let t)) = event {
              acc += t
              continuation.yield(acc)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Request building

  private func urlRequest(
    for body: MessagesRequest,
    headers: [String: String]
  ) throws -> URLRequest {
    var req = URLRequest(url: configuration.baseURL.appending(path: "v1/messages"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.setValue(configuration.version, forHTTPHeaderField: "anthropic-version")
    req.setValue(Telemetry.userAgent, forHTTPHeaderField: "User-Agent")
    switch configuration.auth {
    case .apiKey(let key):
      req.setValue(key, forHTTPHeaderField: "x-api-key")
    case .none:
      break
    }
    for (key, value) in headers {
      req.setValue(value, forHTTPHeaderField: key)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    req.httpBody = try encoder.encode(body)
    return req
  }

  private static func check(_ response: URLResponse, body: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard http.statusCode >= 400 else { return }
    if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: body) {
      var err = envelope.error
      err.requestID =
        envelope.requestID
        ?? http.value(forHTTPHeaderField: "request-id")
      throw err
    }
    // Cap the body excerpt so unexpected error pages can't flood logs via errorDescription.
    let maxBodyExcerpt = 512
    var excerpt = String(decoding: body.prefix(maxBodyExcerpt), as: UTF8.self)
    if body.count > maxBodyExcerpt {
      excerpt += "… [truncated, \(body.count) bytes total]"
    }
    // Without an envelope the status is the only classification signal.
    // Intermediaries (proxies, CDNs) answer auth and rate-limit failures
    // with non-JSON bodies.
    let kind: APIError.Kind =
      switch http.statusCode {
      case 401: .authentication
      case 403: .permission
      case 404: .notFound
      case 413: .requestTooLarge
      case 429: .rateLimit
      case 529: .overloaded
      default: .api
      }
    throw APIError(
      kind: kind,
      message: "HTTP \(http.statusCode): \(excerpt)",
      requestID: http.value(forHTTPHeaderField: "request-id")
    )
  }
}
