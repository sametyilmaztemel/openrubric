import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenRubricCore

/// Stub behavior is driven by URL query items on the final request URL
/// (portable: `httpAdditionalHeaders` on `URLSessionConfiguration` is not
/// propagated to individual requests by swift-corelibs-foundation on Linux):
///   ?stubStatus=500   -> respond with that status code
///   ?stubRawBody=...  -> respond with that raw body
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()

    static var requests: [URLRequest] {
        get { lock.lock(); defer { lock.unlock() }; return _requests }
        set { lock.lock(); defer { lock.unlock() }; _requests = newValue }
    }
    static var bodies: [[String: Any]] {
        get { lock.lock(); defer { lock.unlock() }; return _bodies }
        set { lock.lock(); defer { lock.unlock() }; _bodies = newValue }
    }
    private nonisolated(unsafe) static var _requests: [URLRequest] = []
    private nonisolated(unsafe) static var _bodies: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.requests = StubURLProtocol.requests + [request]
        if let data = request.httpBody {
            StubURLProtocol.bodies = StubURLProtocol.bodies + [(try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]]
        }
        let query = stubQuery(from: request.url)
        let status = (query["stubStatus"]).flatMap(Int.init) ?? 200
        let body: String
        if let raw = query["stubRawBody"] {
            body = raw
        } else if (200..<300).contains(status) {
            body = #"{"choices":[{"message":{"role":"assistant","content":"ANSWER: B\nCONFIDENCE: high"}}]}"#
        } else {
            body = #"{"error":{"message":"boom"}}"#
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

    private func stubQuery(from url: URL?) -> [String: String] {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value
        }
        return result
    }
}

@Suite("OpenAICompatibleClient")
struct ClientTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(
        baseURL: String = "https://api.example.test/v1",
        status: Int? = nil,
        rawBody: String? = nil
    ) throws -> OpenAICompatibleClient {
        var components = URLComponents(string: baseURL)!
        var items: [URLQueryItem] = []
        if let status { items.append(URLQueryItem(name: "stubStatus", value: String(status))) }
        if let rawBody { items.append(URLQueryItem(name: "stubRawBody", value: rawBody)) }
        if !items.isEmpty { components.queryItems = items }
        return try OpenAICompatibleClient(
            configuration: .init(
                baseURL: components.url!.absoluteString,
                apiKey: "sk-test",
                model: "gpt-4o-mini"
            ),
            session: makeSession()
        )
    }

    @Test("success: parses content out of the chat-completions envelope")
    func success() async throws {
        let client = try makeClient()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let raw = try await client.completion(
            systemPrompt: "sys",
            userPrompt: "user",
            imagePNG: png
        )
        #expect(raw.contains("ANSWER: B"))
        let idx = StubURLProtocol.requests
            .firstIndex { $0.url?.absoluteString == client.url.absoluteString }
        let request = idx.map { StubURLProtocol.requests[$0] }
        let body = idx.map { StubURLProtocol.bodies[$0] }
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(body?["model"] as? String == "gpt-4o-mini")
        let messages = body?["messages"] as? [[String: Any]]
        #expect(messages?.count == 2)
        // The image must be inline as a base64 data URI.
        let userContent = (messages?[1]["content"] as? [[String: Any]]) ?? []
        let imagePart = userContent.first { ($0["type"] as? String) == "image_url" }
        let urlDict = imagePart?["image_url"] as? [String: Any]
        let imageURL = (urlDict?["url"] as? String) ?? ""
        #expect(imageURL.hasPrefix("data:image/png;base64,"))
    }

    @Test("non-2xx raises Error.http with status and error body")
    func httpError() async {
        let client = try! makeClient(status: 429)
        do {
            _ = try await client.completion(systemPrompt: "s", userPrompt: "u", imagePNG: Data([0x89]))
            Issue.record("expected http error, got success")
        } catch let error as OpenAICompatibleClient.Error {
            if case .http(let status, let body) = error {
                #expect(status == 429)
                #expect(body.contains("boom"))
            } else {
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("valid JSON but wrong shape raises Error.decoding")
    func malformed() async {
        let client = try! makeClient(rawBody: #"{"unexpected":true}"#)
        do {
            _ = try await client.completion(systemPrompt: "s", userPrompt: "u", imagePNG: Data([0x89]))
            Issue.record("expected decoding error, got success")
        } catch let error as OpenAICompatibleClient.Error {
            if case .decoding = error {} else {
                Issue.record("expected .decoding, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("empty model content raises Error.emptyContent")
    func emptyContent() async {
        let client = try! makeClient(rawBody: #"{"choices":[{"message":{"role":"assistant","content":""}}]}"#)
        do {
            _ = try await client.completion(systemPrompt: "s", userPrompt: "u", imagePNG: Data([0x89]))
            Issue.record("expected emptyContent error, got success")
        } catch let error as OpenAICompatibleClient.Error {
            if case .emptyContent = error {} else {
                Issue.record("expected .emptyContent, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("invalid base URLs are rejected instead of crashing")
    func invalidBaseURLs() {
        for raw in ["", "   ", "not a url", "example.com"] {
            let client = try? OpenAICompatibleClient(
                configuration: .init(baseURL: raw, apiKey: "***", model: "m"),
                session: makeSession()
            )
            #expect(client == nil)
        }
    }

    @Test("trailing slash and whitespace are normalized before the path append")
    func urlConstruction() throws {
        let plain = try makeClient()
        #expect(plain.url.absoluteString == "https://api.example.test/v1/chat/completions")
        let padded = try OpenAICompatibleClient(
            configuration: .init(baseURL: "  https://api.example.test/v1/  ", apiKey: "***", model: "m"),
            session: makeSession()
        )
        #expect(padded.url.absoluteString == "https://api.example.test/v1/chat/completions")
    }
}
