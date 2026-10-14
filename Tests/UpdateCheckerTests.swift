import Foundation

@main struct UpdateCheckerTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); count += 1
        }
        func fixture(tag: String = "v0.6.0", page: String? = nil, draft: Bool = false,
                     prerelease: Bool = false, assetPrefix: String? = nil, missing: Bool = false) throws -> Data {
            let root = UpdateChecker.releasesURL.absoluteString
            return try JSONSerialization.data(withJSONObject: [
                "tag_name": tag, "html_url": page ?? root + "/tag/" + tag,
                "draft": draft, "prerelease": prerelease,
                "assets": missing ? [] : ["StateLite-\(tag)-macos-arm64.zip", "SHA256SUMS"].map { name in
                    ["name": name, "state": "uploaded", "browser_download_url": (assetPrefix ?? root + "/download/" + tag + "/") + name]
                }
            ])
        }
        func evaluate(_ data: Data, status: Int = 200, current: String = "0.5.0") -> UpdateResult {
            UpdateChecker.evaluate(status: status, data: data, current: current)
        }
        func failed(_ result: UpdateResult) -> Bool { if case .failure = result { return true }; return false }
        check(ReleaseVersion("1.10.0")! > ReleaseVersion("1.9.99")!, "numeric ordering")
        for tag in ["1.2", "1.2.3.4", "01.2.3", "1.2.3-beta", "1.2.-1", "１.2.3", "999999999999999999999999.2.3"] {
            check(ReleaseVersion(tag) == nil, "invalid version \(tag)")
        }
        check(evaluate(try fixture()) == .available("v0.6.0", URL(string: "https://github.com/ARMANDSnow/StateLite/releases/tag/v0.6.0")!), "upgrade")
        check(evaluate(try fixture(tag: "v0.5.0")) == .current, "same version")
        check(evaluate(try fixture(tag: "v0.4.3")) == .current, "no downgrade")
        check(evaluate(Data(), status: 404) == .noRelease, "no stable release")
        for status in [403, 429, 500, 301] { check(failed(evaluate(Data(), status: status)), "HTTP \(status)") }
        for data in [try fixture(draft: true), try fixture(prerelease: true), try fixture(missing: true),
                     try fixture(page: "https://example.com"), try fixture(assetPrefix: "https://example.com/"),
                     try fixture(tag: "0.6.0"), Data("not-json".utf8), Data(repeating: 32, count: UpdateChecker.limit + 1)] {
            check(failed(evaluate(data)), "reject untrusted or incomplete release")
        }
        check(failed(evaluate(try fixture(), current: "invalid")), "invalid installed version")
        print("Update checker: \(count) tests passed (offline fixtures).")
    }
}
