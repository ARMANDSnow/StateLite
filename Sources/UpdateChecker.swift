import Foundation

struct ReleaseVersion: Comparable {
    let parts: [Int]
    init?(_ value: String) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let fields = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && ($0 == "0" || !$0.hasPrefix("0"))
        }) else { return nil }
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        parts = numbers
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

enum UpdateResult: Equatable {
    case current, available(String, URL), noRelease, failure(String)
    var message: String {
        switch self {
        case .current: return "当前版本已是最新正式版。"
        case .available(let version, _): return "发现 \(version)，请查看发布说明后下载更新。"
        case .noRelease: return "暂无正式发布版本，请稍后再试。"
        case .failure(let message): return message
        }
    }
}

enum UpdateChecker {
    static let releasesURL = URL(string: "https://github.com/ARMANDSnow/StateLite/releases")!
    static let endpoint = URL(string: "https://api.github.com/repos/ARMANDSnow/StateLite/releases/latest")!
    static let limit = 256 * 1024

    static func evaluate(status: Int, data: Data, current: String) -> UpdateResult {
        if status == 404 { return .noRelease }
        if status == 403 || status == 429 { return .failure("GitHub 暂时限制请求，请稍后重试。") }
        guard status == 200 else { return .failure("检查失败（HTTP \(status)），请稍后重试。") }
        guard data.count <= limit, let local = ReleaseVersion(current),
              let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease,
              let remote = ReleaseVersion(release.tag_name),
              release.tag_name == "v" + remote.parts.map(String.init).joined(separator: ".") else {
            return .failure("发布信息格式不正确，未推荐更新。")
        }
        let tag = release.tag_name
        let expectedPage = releasesURL.absoluteString + "/tag/" + tag
        let prefix = releasesURL.absoluteString + "/download/" + tag + "/"
        let zip = "StateLite-\(tag)-macos-arm64.zip"
        guard release.html_url == expectedPage,
              [zip, "SHA256SUMS"].allSatisfy({ name in
                  release.assets.contains { $0.name == name && $0.state == "uploaded" && $0.browser_download_url == prefix + name }
              }), let url = URL(string: expectedPage) else {
            return .failure("发布页或安装包不完整，请到发布页核实。")
        }
        return remote > local ? .available(tag, url) : .current
    }

    static func check(current: String, completion: @escaping (UpdateResult) -> Void) {
        Request(current: current, completion: completion).start()
    }
    private struct Release: Decodable {
        let tag_name: String, html_url: String
        let draft: Bool, prerelease: Bool
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String, state: String, browser_download_url: String
    }

    // One serial delegate per explicit click; no cookies, credentials, disk cache or background polling.
    private final class Request: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let current: String
        var completion: ((UpdateResult) -> Void)?
        var session: URLSession?
        var data = Data()
        var status = 0
        init(current: String, completion: @escaping (UpdateResult) -> Void) {
            self.current = current; self.completion = completion
        }
        func start() {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            self.session = session
            var request = URLRequest(url: UpdateChecker.endpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("StateLite-UpdateCheck", forHTTPHeaderField: "User-Agent")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            session.dataTask(with: request).resume()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil) // Repository moves require a reviewed app update.
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if response.expectedContentLength > UpdateChecker.limit {
                completionHandler(.cancel); finish(.failure("发布信息过大，检查已停止。"))
            } else { completionHandler(.allow) }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            guard data.count + chunk.count <= UpdateChecker.limit else {
                dataTask.cancel(); finish(.failure("发布信息过大，检查已停止。")); return
            }
            data.append(chunk)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish(error == nil ? UpdateChecker.evaluate(status: status, data: data, current: current) :
                .failure("无法连接 GitHub，请检查网络后重试。"))
        }
        private func finish(_ result: UpdateResult) {
            guard let callback = completion else { return }
            completion = nil; session?.invalidateAndCancel(); session = nil
            DispatchQueue.main.async { callback(result) }
        }
    }
}
