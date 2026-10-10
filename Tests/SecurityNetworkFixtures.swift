import Foundation

// Injected into URLSession only in the test script's temporary source copy.
// No request can reach a real network endpoint.
final class SecurityNetworkFixture: @unchecked Sendable {
    static let shared = SecurityNetworkFixture()
    private let lock = NSLock()
    private var paths: [String] = []
    private var iconData = Data()
    func reset(icon: Data) { lock.lock(); defer { lock.unlock() }; paths = []; iconData = icon }
    func record(_ path: String) { lock.lock(); defer { lock.unlock() }; paths.append(path) }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    var icon: Data { lock.lock(); defer { lock.unlock() }; return iconData }
}

final class SecurityURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "security-fixture.test" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let fixture = SecurityNetworkFixture.shared
        fixture.record(url.path)
        var headers = ["Content-Type": "text/html"]
        let data: Data
        switch url.path {
        case "/page": data = Data("<link rel='icon' href='/valid.png'>".utf8)
        case "/large-html":
            headers["Content-Length"] = "3000000"
            data = Data("x".utf8)
        case "/lying-html": data = Data(repeating: 32, count: 2 * 1024 * 1024 + 1)
        case "/large-icon-page": data = Data("<link rel='icon' href='/large-icon.png'>".utf8)
        case "/large-icon.png":
            headers = ["Content-Type": "image/png", "Content-Length": "9000000"]
            data = Data("x".utf8)
        case "/bad-icons": data = Data((0..<50).map { "<link rel='icon' href='/bad\($0).png'>" }.joined().utf8)
        case "/valid.png", "/favicon.ico":
            headers = ["Content-Type": "image/png"]
            data = fixture.requests.first == "/bad-icons" ? Data("invalid".utf8) : fixture.icon
        default: headers = ["Content-Type": "image/png"]; data = Data("invalid".utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
