import Foundation
import Network
import ScudoKit
import ScudoShared
import WebKit

/// Loads a test page in a WKWebView with the four compiled rule lists and
/// checks what Safari would do: network blocking, element hiding, custom
/// rules and the allowlist.
///
/// Images are served by a tiny HTTP server bound to 127.0.0.1 that records
/// every request, so a blocked image is one that never reached the server.
/// The page itself is injected with `loadHTMLString(_:baseURL:)`, which lets
/// it pretend to live on any domain without touching the network.
struct EndToEndTest {
    let store: ScudoStore
    let directory: URL

    static let customRule = "/scudo-custom-block/"
    static let allowedDomain = "scudo-consentito.example"

    @MainActor
    func run() async throws -> Bool {
        guard BlockerKind.allCases.allSatisfy(store.hasRules(for:)) else {
            print("Run `rulecheck update` first.")
            return false
        }

        // Add a custom rule and an allowlisted domain, rebuild (no download).
        let original = store.loadSettings()
        var settings = original
        settings.customRules = Self.customRule
        settings.allowlist = [Self.allowedDomain]
        try store.save(settings)
        defer { try? store.save(original) }

        let webKit = try WebKitRules(directory: directory.appending(path: "WebKit-e2e"))
        let engine = ProtectionEngine(store: store, reloader: { kind in
            let json = try String(contentsOf: store.rulesURL(for: kind), encoding: .utf8)
            try await webKit.compile(kind, json: json)
            return .reloaded
        })
        _ = await engine.update(skipDownload: true)
        // Rules that did not change were not reloaded above: compile them too.
        for kind in BlockerKind.allCases where webKit.compiled[kind] == nil {
            try await webKit.compile(kind, json: String(contentsOf: store.rulesURL(for: kind), encoding: .utf8))
        }

        let server = try TinyHTTPServer()
        try await server.start()
        let base = "http://127.0.0.1:\(server.port)"
        print("Test server on \(base)")

        let page = """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
        <div class="banner-advert" id="cosmetic-generic">annuncio (regola generica AdGuard Base)</div>
        <div id="adk_article-top">annuncio (lista italiana)</div>
        <div class="contenuto" id="control">articolo</div>
        <img id="img-ad" src="\(base)/static/ad-provider.gif">
        <img id="img-custom" src="\(base)/scudo-custom-block/pixel.gif">
        <img id="img-ok" src="\(base)/static/logo.gif">
        </body></html>
        """

        var passed = true
        func check(_ name: String, _ condition: Bool) {
            print("  \(condition ? "✔" : "✘") \(name)")
            passed = passed && condition
        }

        let browser = TestBrowser(ruleLists: Array(webKit.compiled.values))

        print("\nPage on a normal site (blocking expected):")
        var result = try await browser.load(page, as: "https://www.notizie-di-prova.example/articolo")
        check("ad image from a generic list rule is blocked", result.imageWidth["img-ad"] == 0 && !server.wasRequested("ad-provider"))
        check("image matching the custom rule is blocked", result.imageWidth["img-custom"] == 0 && !server.wasRequested("scudo-custom-block"))
        check("normal image loads", result.imageWidth["img-ok"] == 1)
        check("generic ad element is hidden", result.display["cosmetic-generic"] == "none")
        check("element from the Italian list is hidden", result.display["adk_article-top"] == "none")
        check("normal content stays visible", result.display["control"] == "block")

        server.reset()
        print("\nPage on an allowlisted site (nothing blocked):")
        result = try await browser.load(page, as: "https://www.\(Self.allowedDomain)/articolo")
        check("ad image loads", result.imageWidth["img-ad"] == 1 && server.wasRequested("ad-provider"))
        check("custom-rule image loads", result.imageWidth["img-custom"] == 1)
        check("ad element stays visible", result.display["cosmetic-generic"] == "block")

        print(passed ? "\n✔ End-to-end test passed" : "\n✘ End-to-end test FAILED")
        return passed
    }
}

/// A WKWebView with the content rule lists attached.
@MainActor
final class TestBrowser: NSObject, WKNavigationDelegate {
    struct Result {
        var display: [String: String] = [:]
        var imageWidth: [String: Int] = [:]
    }

    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, any Error>?

    init(ruleLists: [WKContentRuleList]) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        for list in ruleLists {
            configuration.userContentController.add(list)
        }
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ html: String, as url: String) async throws -> Result {
        webView.loadHTMLString(html, baseURL: URL(string: url)!)
        try await withCheckedThrowingContinuation { continuation = $0 }
        // Give images and style recalculation a moment.
        try await Task.sleep(for: .milliseconds(1500))

        let json = try await evaluate("""
        JSON.stringify({
          display: Object.fromEntries(['cosmetic-generic','adk_article-top','control'].map(id => [id, getComputedStyle(document.getElementById(id)).display])),
          imageWidth: Object.fromEntries(['img-ad','img-custom','img-ok'].map(id => [id, document.getElementById(id).naturalWidth]))
        })
        """)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]] ?? [:]
        var result = Result()
        result.display = (object["display"] as? [String: String]) ?? [:]
        result.imageWidth = (object["imageWidth"] as? [String: Int]) ?? [:]
        print("    page \(url): \(json)")
        return result
    }

    private func evaluate(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value as? String ?? "")
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Minimal HTTP server on 127.0.0.1 answering every request with a 1×1 GIF.
final class TinyHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rulecheck.http")
    private let lock = NSLock()
    private var requestedPaths: [String] = []
    private static let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func start() async throws {
        let started = OSAllocatedUnfairLockFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if started.setOnce() { continuation.resume() }
                case .failed(let error):
                    if started.setOnce() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func wasRequested(_ fragment: String) -> Bool {
        lock.withLock { requestedPaths.contains { $0.contains(fragment) } }
    }

    func reset() {
        lock.withLock { requestedPaths.removeAll() }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            self?.lock.withLock { self?.requestedPaths.append(path) }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\nContent-Length: \(Self.gif.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + Self.gif, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

/// Thread-safe "do once" flag.
final class OSAllocatedUnfairLockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func setOnce() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
