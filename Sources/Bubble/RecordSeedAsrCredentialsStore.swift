import Foundation

enum RecordSeedAsrCredentialsStore {
    private struct FilePayload: Codable {
        var engine: String?
        var apiKey: String?
        var appId: String?
        var accessToken: String?
        var resourceId: String?
        var endpoint: String?
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        file: URL
    ) -> (engine: RecordEngine, credentials: RecordSeedAsrCredentials) {
        let payload = readFile(file)
        var credentials = RecordSeedAsrCredentials()
        credentials.apiKey = firstNonEmpty([
            environment["VOLC_ASR_API_KEY"],
            environment["ARK_API_KEY"],
            environment["DOUBAO_ASR_API_KEY"],
            payload?.apiKey,
        ])
        credentials.appId = firstNonEmpty([
            environment["VOLC_ASR_APP_ID"],
            environment["DOUBAO_ASR_APP_ID"],
            payload?.appId,
        ])
        credentials.accessToken = firstNonEmpty([
            environment["VOLC_ASR_ACCESS_TOKEN"],
            environment["DOUBAO_ASR_ACCESS_TOKEN"],
            payload?.accessToken,
        ])
        let resourceId = firstNonEmpty([
            environment["VOLC_ASR_RESOURCE_ID"],
            payload?.resourceId,
        ])
        if !resourceId.isEmpty {
            credentials.resourceId = resourceId
        }
        let endpoint = firstNonEmpty([
            environment["VOLC_ASR_ENDPOINT"],
            payload?.endpoint,
        ])
        if !endpoint.isEmpty {
            credentials.endpoint = endpoint
        }
        let engine = RecordEngine.parse(firstNonEmpty([
            environment["BUBBLE_RECORD_ENGINE"],
            payload?.engine,
        ]))
        return (engine, credentials)
    }

    private static func readFile(_ file: URL) -> FilePayload? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(FilePayload.self, from: data)
    }

    private static func firstNonEmpty(_ values: [String?]) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
