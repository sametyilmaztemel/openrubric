import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenRubricCore
/// Behavior is driven by request headers so each test stays independent:
///   X-Stub-Status: 500  -> respond with that status code
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()

    static var lastRequest: URLRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _lastRequest }
        set { lock.lock(); defer { lock.unlock() }; _lastRequest = newValue }
    }
    static var lastBody: [String: Any]? {
        get { lock.lock(); defer { lock.unlock() }; return _lastBody }
        set { lock.lock(); defer { lock.unlock() }; _lastBody = newValue }
    }
    private nonisolated(unsafe) static var _lastRequest: URLRequest?
    private nonisolated(unsafe) static var _lastBody: [String: Any]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.lastRequest = request
        if let data = request.httpBody {
            StubURLProtocol.lastBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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

    /// Stub behavior is driven by URL query items (portable: `httpAdditionalHeaders`
    /// is not propagated to requests by swift-corelibs-foundation on Linux).
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

/// Client wrapper that lets tests tag outgoing requests.
private final class TaggingClient: ChatCompletionsClient, @unchecked Sendable {
    let inner: OpenAICompatibleClient
    let tag: String?
    init(inner: OpenAICompatibleClient, tag: String?) {
        self.inner = inner
        self.tag = tag
    }
    func completion(systemPrompt: String, userPrompt: String, imagePNG: Data) async throws -> String {
        // Tag goes through a custom header by rebuilding the request path;
        // simplest: call inner and inspect lastRequest afterwards. For the
        // error test we need the header BEFORE the call, so we use a
        // session-level default instead (see makeSession).
        return try await inner.completion(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imagePNG: imagePNG
        )
    }
}

@Suite("OpenAICompatibleClient")
struct ClientTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(status: Int? = nil, rawBody: String? = nil) -> OpenAICompatibleClient {
        var components = URLComponents(string: "https://api.example.test/v1")!
        var items: [URLQueryItem] = []
        if let status { items.append(URLQueryItem(name: "stubStatus", value: String(status))) }
        if let rawBody { items.append(URLQueryItem(name: "stubRawBody", value: rawBody)) }
        if !items.isEmpty { components.queryItems = items }
        let baseURL = components.url!.absoluteString
        return OpenAICompatibleClient(
            configuration: .init(
                baseURL: baseURL,
                apiKey: "sk-test",
                model: "gpt-4o-mini"
            ),
            session: makeSession()
        )
    }

    @Test("success: parses content out of the chat-completions envelope")
    func success() async throws {
        let client = makeClient()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let raw = try await client.completion(
            systemPrompt: "sys",
            userPrompt: "user",
            imagePNG: png
        )
        #expect(raw.contains("ANSWER: B"))
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = StubURLProtocol.lastBody
        #expect(body?["model"] as? String == "gpt-4o-mini")
        let messages = body?["messages"] as? [[String: Any]]
        #expect(messages?.count == 2)
        // The image must be inline as a base64 data URI.
        let userMsg = messages?[1]
        let userContent = userMsg?["content"] as? [[String: Any]]
        let imagePart = userContent?.first { ($0["type"] as? String) == "image_url" }
        let urlDict = imagePart?["image_url"] as? [String: Any]
        let imageURL = urlDict?["url"] as? String ?? ""
        #expect(imageURL.hasPrefix("data:image/png;base64,"))
    }

    @Test("non-2xx raises Error.http with the status code")
    func httpError() async {
        let client = makeClient(status: 429)
        do {
            _ = try await client.completion(systemPrompt: "s", userPrompt: "u", imagePNG: Data([0x89]))
            Issue.record("expected http error, got success")
        } catch let error as OpenAICompatibleClient.Error {
            if case .http(let status, _) = error {
                #expect(status == 429)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("valid JSON but wrong shape raises Error.decoding")
    func malformed() async {
        let client = makeClient(rawBody: #"{"unexpected":true}"#)
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
}
