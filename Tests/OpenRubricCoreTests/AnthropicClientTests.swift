import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenRubricCore

/// Records the last request so tests can assert on the wire format.
final class AnthropicStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    static var lastRequest: URLRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _last }
        set { lock.lock(); defer { lock.unlock() }; _last = newValue }
    }
    private nonisolated(unsafe) static var _last: URLRequest?

    /// ?stubStatus=NNN  -> respond with that status
    /// ?stubRawBody=... -> respond with that body
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        AnthropicStubProtocol.lastRequest = request
        var query: [String: String] = [:]
        if let url = request.url,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] { query[item.name] = item.value }
        }
        let status = (query["stubStatus"]).flatMap(Int.init) ?? 200
        let body: String
        if let raw = query["stubRawBody"] {
            body = raw
        } else if (200..<300).contains(status) {
            body = #"{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"ANSWER: B\nCONFIDENCE: high"}],"stop_reason":"end_turn"}"#
        } else {
            body = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        }
        let data = body.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("AnthropicClient")
struct AnthropicClientTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicStubProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(
        baseURL: String = "https://api.anthropic.com",
        model: String = "claude-haiku-5-5",
        status: Int? = nil,
        rawBody: String? = nil
    ) throws -> AnthropicClient {
        var components = URLComponents(string: baseURL)!
        var items: [URLQueryItem] = []
        if let status { items.append(URLQueryItem(name: "stubStatus", value: String(status))) }
        if let rawBody { items.append(URLQueryItem(name: "stubRawBody", value: rawBody)) }
        if !items.isEmpty { components.queryItems = items }
        return try AnthropicClient(
            configuration: .init(
                baseURL: components.url!.absoluteString,
                apiKey: "sk-ant-test",
                model: model
            ),
            session: makeSession()
        )
    }

    @Test("success: sends x-api-key + anthropic-version and parses content blocks")
    func success() async throws {
        let client = try makeClient()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let raw = try await client.completion(systemPrompt: "sys", userPrompt: "user", imagePNG: png)
        #expect(raw.contains("ANSWER: B"))

        let request = AnthropicStubProtocol.lastRequest
        #expect(request?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request?.url?.absoluteString.contains("/v1/messages") == true)

        // The image must be a base64 content block, system a top-level field.
        let data = request?.httpBody!
        let body = (try? JSONSerialization.jsonObject(with: data!)) as? [String: Any]
        #expect(body?["system"] as? String == "sys")
        #expect(body?["max_tokens"] as? Int == 300)
        let messages = body?["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        let content = messages?.first?["content"] as? [[String: Any]]
        let imagePart = content?.first { ($0["type"] as? String) == "image" }
        let source = imagePart?["source"] as? [String: Any]
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/png")
        #expect((source?["data"] as? String)?.count == png.base64EncodedString().count)
        let textPart = content?.first { ($0["type"] as? String) == "text" }
        #expect(textPart?["text"] as? String == "user")
    }

    @Test("proxy base URL already ending in /v1 does not double the path")
    func proxyURL() throws {
        let client = try makeClient(baseURL: "https://api.minimax.io/anthropic/v1")
        #expect(client.url.absoluteString == "https://api.minimax.io/anthropic/v1/messages")
    }

    @Test("official base URL resolves to /v1/messages")
    func officialURL() throws {
        let client = try makeClient()
        #expect(client.url.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test("invalid base URLs are rejected instead of crashing")
    func invalidBaseURLs() {
        for raw in ["", "   ", "not a url"] {
            let client = try? AnthropicClient(
                configuration: .init(baseURL: raw, apiKey: "sk-ant-test", model: "m"),
                session: makeSession()
            )
            #expect(client == nil)
        }
    }

    @Test("non-2xx raises Error.http with the Anthropic error message")
    func httpError() async {
        let client = try! makeClient(status: 529)
        do {
            _ = try await client.completion(systemPrompt: "s", userPrompt: "u", imagePNG: Data([0x89]))
            Issue.record("expected http error, got success")
        } catch let error as AnthropicClient.Error {
            if case .http(let status, let body) = error {
                #expect(status == 529)
                #expect(body.contains("Overloaded"))
            } else {
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("wrong shape raises Error.decoding, missing text raises Error.emptyContent")
    func decodingAndEmpty() async {
        let client = try! makeClient(rawBody: #"{"unexpected":true}"#)
        do {
            _ = try await client.completion(systemPrompt: "s", userPrompt: "u", imagePNG: Data([0x89]))
            Issue.record("expected decoding error, got success")
        } catch let error as AnthropicClient.Error {
            if case .decoding = error {} else {
                Issue.record("expected .decoding, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        let client2 = try! makeClient(rawBody: #"{"content":[{"type":"image","data":"x"}]}"#)
        do {
            _ = try await client2.completion(systemPrompt: "s", userPrompt: "u", imagePNG: Data([0x89]))
            Issue.record("expected emptyContent error, got success")
        } catch let error as AnthropicClient.Error {
            if case .emptyContent = error {} else {
                Issue.record("expected .emptyContent, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}