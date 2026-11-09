import Foundation

/// Downloads filter lists using conditional requests, so that unchanged
/// lists cost a single `304 Not Modified` round trip.
struct FilterDownloader: Sendable {
    enum Outcome: Sendable {
        case notModified
        case downloaded(Data, etag: String?, lastModified: String?)
    }

    let session: URLSession

    func fetch(_ list: FilterList, etag: String?, lastModified: String?) async throws -> Outcome {
        var request = URLRequest(url: list.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ScudoError.invalidResponse
        }
        switch http.statusCode {
        case 304:
            return .notModified
        case 200..<300:
            guard RuleText.looksLikeFilterList(data) else { throw ScudoError.notAFilterList }
            return .downloaded(
                data,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified")
            )
        default:
            throw ScudoError.httpStatus(http.statusCode)
        }
    }
}
