import Foundation
import Testing
@testable import ShepherdRemote

/// The directory's answers as Browse reads them: search, the ranked lists (`/api/v1`), and a
/// skill's files; and install counts as the directory writes them.
@Suite("Skills directory")
struct SkillsDirectoryTests {
    @Test func searchResultsNameTheirRepositoryMostInstalledFirst() throws {
        let json = #"""
        {"skills":[
          {"id":"pg-query-tuning","name":"pg-query-tuning","source":"dbkit/skills","installs":24000},
          {"id":"supabase-postgres-best-practices","name":"supabase-postgres-best-practices","source":"supabase/agent-skills","installs":71000},
          {"id":"orphan","name":"orphan","installs":5}
        ]}
        """#
        let skills = try SkillsDirectory.decodeSearch(Data(json.utf8))
        #expect(skills.map(\.slug) == ["supabase-postgres-best-practices", "pg-query-tuning"])
        #expect(skills.first?.id == "supabase/agent-skills/supabase-postgres-best-practices")
        #expect(skills.first?.official == false)
    }

    @Test func rankedListsReadSlugOrId() throws {
        let json = #"""
        {"data":[
          {"id":"a1","slug":"find-skills","name":"find-skills","source":"vercel-labs/skills","installs":3600000,"sourceType":"github"},
          {"id":"skill-creator","source":"anthropics/skills","installs":131000}
        ],"pagination":{"page":1,"perPage":50,"total":2,"hasMore":false}}
        """#
        let skills = try SkillsDirectory.decodeRanked(Data(json.utf8))
        #expect(skills.map(\.slug) == ["find-skills", "skill-creator"])
        #expect(skills.map(\.name) == ["find-skills", "skill-creator"])
    }

    @Test func aSkillsFilesKeepTheirPathsInItsFolder() throws {
        let json = #"{"files":[{"path":"SKILL.md","contents":"---\nname: pdf\n---\n"},{"path":"scripts/fill.py"}],"hash":"abc"}"#
        let files = try SkillsDirectory.decodeFiles(Data(json.utf8))
        #expect(files == [DirectoryFile(path: "SKILL.md", contents: "---\nname: pdf\n---\n"), DirectoryFile(path: "scripts/fill.py", contents: "")])
    }

    @Test func directoryRequestsUseShepherdWithoutCredentials() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectoryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let directory = SkillsDirectory(session: session)
        #expect(directory.base.absoluteString == "https://api.useshepherd.app")
        #expect(try await directory.search("react & ui", limit: 7).isEmpty)
        for ranking in DirectoryRanking.allCases {
            let skills = try await directory.ranked(ranking, page: 2, perPage: 7)
            #expect(skills.count == 1)
            #expect(skills.first?.official == (ranking == .official))
        }
        let skill = DirectorySkill(slug: "pdf", name: "pdf", source: "anthropics/skills", installs: 1)
        #expect(try await directory.files(of: skill).isEmpty)
    }

    @Test(arguments: [401, 403, 429, 500])
    func serviceErrorsDoNotAskForUserCredentials(status: Int) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectoryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let directory = SkillsDirectory(base: URL(string: "https://status-\(status).test")!, session: session)
        await #expect(throws: SkillsDirectoryError.unavailable("Shepherd's skills directory answered \(status).")) {
            try await directory.ranked(.trending, page: 2, perPage: 7)
        }
    }

    @Test(arguments: [(980, "980"), (1_000, "1K"), (1_200, "1.2K"), (8_400, "8.4K"), (71_000, "71K"), (312_000, "312K"),
                      (3_600_000, "3.6M")])
    func installsReadAsTheDirectoryWritesThem(count: Int, text: String) {
        #expect(DirectoryPresentation.installs(count) == text)
    }

    @Test func aSearchLightsEveryMatchInAName() {
        let name = "postgres-rls-postgres"
        let ranges = DirectoryPresentation.matches(of: "Postgres", in: name)
        #expect(ranges.map { String(name[$0]) } == ["postgres", "postgres"])
        #expect(DirectoryPresentation.matches(of: " ", in: name).isEmpty)
    }

    /// A preview reads the SKILL.md wherever skills.sh puts it, and lists the skill's files.
    @Test func aPreviewReadsTheSkillsDescriptionAndFiles() {
        let skill = DirectorySkill(slug: "pdf", name: "pdf", source: "anthropics/skills", installs: 71_000)
        let text = "---\nname: pdf\ndescription: Read, fill, merge and split PDFs.\n---\n\n# PDF\n"
        let preview = DirectoryPreview(skill: skill, files: [DirectoryFile(path: "skills/pdf/SKILL.md", contents: text),
                                                             DirectoryFile(path: "scripts/fill.py", contents: "")])
        #expect(preview.summary == "Read, fill, merge and split PDFs.")
        #expect(preview.instructions == text)
        #expect(preview.tokens == SkillsText.tokens(text))
        #expect(preview.entries.map(\.name) == ["scripts", "skills"])
        let empty = DirectoryPreview(skill: skill, files: [])
        #expect(empty.summary == nil && empty.tokens == 0 && empty.entries.isEmpty)
    }

    /// A result rides a route to its preview, so it survives encoding.
    @Test func aDirectorySkillSurvivesEncoding() throws {
        let skill = DirectorySkill(slug: "find-skills", name: "find-skills", source: "vercel-labs/skills", installs: 3_600_000,
                                   official: true)
        #expect(try JSONDecoder().decode(DirectorySkill.self, from: JSONEncoder().encode(skill)) == skill)
    }

    @Test func aSkillsPageIsItsRepositoryAndName() {
        let skill = DirectorySkill(slug: "pdf", name: "pdf", source: "anthropics/skills", installs: 1)
        #expect(SkillsDirectory.page(of: skill).absoluteString == "https://skills.sh/anthropics/skills/pdf")
    }
}

private final class DirectoryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        var body = #"{"files":[]}"#
        switch url.path {
        case "/api/search":
            #expect(query == [URLQueryItem(name: "q", value: "react & ui"), URLQueryItem(name: "limit", value: "7")])
            body = #"{"skills":[]}"#
        case "/api/v1/skills", "/api/v1/skills/curated":
            #expect(query.first == URLQueryItem(name: "per_page", value: "7"))
            #expect(query.dropFirst().first == URLQueryItem(name: "page", value: "2"))
            if url.path.hasSuffix("curated") {
                #expect(query.count == 2)
            } else {
                #expect(query.count == 3)
                #expect(query.last?.name == "view")
                #expect(["trending", "all-time", "hot"].contains(query.last?.value ?? ""))
            }
            body = #"{"data":[{"slug":"pdf","source":"anthropics/skills"}]}"#
        default:
            #expect(url.path == "/api/download/anthropics/skills/pdf")
            #expect(query.isEmpty)
        }
        let status = url.host.flatMap { Int($0.replacingOccurrences(of: "status-", with: "").replacingOccurrences(of: ".test", with: "")) } ?? 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
