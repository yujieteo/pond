import Foundation

/// media-plan.md in the site repo, the master copy of the plan (R8), through the GitHub contents API.
public enum PlanRepo {
    public static let repo = "yujieteo/site"
    public static let path = "media-plan.md"
    public static let branch = "main"

    /// The text of the file and its Git blob SHA.
    public struct File: Equatable, Sendable {
        public var text: String
        public var sha: String

        public init(text: String, sha: String) {
            self.text = text
            self.sha = sha
        }
    }

    /// What the reply to a commit means to the phone.
    public enum Saved: Equatable, Sendable {
        /// The site repo has the text, with this new SHA.
        case saved(sha: String)
        /// 409: the file in the site repo is not the one that the phone changed.
        case conflict
        /// 401, 403, 404 or 422: the token cannot commit. A new token or a new change sends again.
        case refused(status: Int)
        /// No reply, or a reply that can change later: send again later.
        case later
    }

    public static func url(api: URL) -> URL {
        api.appending(path: "repos/\(repo)/contents/\(path)")
    }

    /// The site repo is public, so the read needs no token.
    public static func load(api: URL, token: String?, transport: Outbox.Transport) async throws -> File {
        var request = URLRequest(url: url(api: api).appending(queryItems: [URLQueryItem(name: "ref", value: branch)]))
        headers(&request, token: token)
        let (status, body) = try await transport(request)
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try file(body)
    }

    public static func commit(_ text: String, sha: String, api: URL, token: String, transport: Outbox.Transport) async -> Saved {
        var request = URLRequest(url: url(api: api))
        request.httpMethod = "PUT"
        headers(&request, token: token)
        request.httpBody = try? JSONEncoder().encode([
            "message": "plan: edit media-plan.md in Pond", "content": Data(text.utf8).base64EncodedString(),
            "sha": sha, "branch": branch,
        ])
        guard let (status, body) = try? await transport(request) else { return .later }
        return saved(status: status, body: body)
    }

    static func saved(status: Int, body: Data) -> Saved {
        struct Reply: Decodable { struct Content: Decodable { var sha: String }; var content: Content }
        switch status {
        case 200, 201:
            guard let sha = try? JSONDecoder().decode(Reply.self, from: body).content.sha else { return .later }
            return .saved(sha: sha)
        case 409: return .conflict
        case 401, 403, 404, 422: return .refused(status: status)
        default: return .later
        }
    }

    static func file(_ body: Data) throws -> File {
        struct Reply: Decodable { var content: String; var sha: String }
        let reply = try JSONDecoder().decode(Reply.self, from: body)
        guard let data = Data(base64Encoded: reply.content, options: .ignoreUnknownCharacters) else {
            throw URLError(.cannotDecodeContentData)
        }
        return File(text: String(decoding: data, as: UTF8.self), sha: reply.sha)
    }

    private static func headers(_ request: inout URLRequest, token: String?) {
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }
}
