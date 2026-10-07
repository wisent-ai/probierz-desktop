import Foundation
import SwiftUI

/// One suite the product's manifest declares, as `probierz benchmark suites`
/// judges it: its version, hash and case count, or the refusal that keeps it
/// from running.
struct BenchmarkSuite: Identifiable, Decodable, Sendable {
    let id: String
    let file: String
    let version: String?
    let hash: String?
    let cases: Int?
    let refused: String?
}

/// One contender the manifest declares: ours or a rival's driver.
struct BenchmarkContender: Identifiable, Decodable, Sendable {
    let id: String
    let ours: Bool
    let program: String
}

/// One contender's measured result in a run summary.
struct BenchmarkMeasure: Decodable, Sendable {
    let attempts: Int
    let passed: Int
    let passRate: Double
    let broken: Int
    let p50Ms: Double?
}

/// One recorded run as `probierz benchmark list` answers it.
struct BenchmarkRun: Identifiable, Decodable, Sendable {
    struct Suite: Decodable, Sendable {
        let id: String
        let version: String
    }

    let runId: String
    let suite: Suite
    let startedAt: String
    let ours: String
    let summary: [String: BenchmarkMeasure]
    var id: String { runId }
    var oursPassRate: Double? { summary[ours]?.passRate }
    var bestRival: (id: String, passRate: Double)? {
        summary.filter { $0.key != ours }
            .max { $0.value.passRate < $1.value.passRate }
            .map { ($0.key, $0.value.passRate) }
    }
}

/// `probierz benchmark` owns the manifest, the suites, the run store and the
/// catalog writes. Desktop reads and acts only through that command: every
/// operation is one finite CLI call, and what it shows is that command's JSON
/// answer or the sentence of its `probierz-failure` line.
@MainActor
final class BenchmarkStore: ObservableObject {
    @Published private(set) var suites: [BenchmarkSuite] = []
    @Published private(set) var contenders: [BenchmarkContender] = []
    @Published private(set) var runs: [BenchmarkRun] = []
    @Published private(set) var loadedAt: Date?
    @Published private(set) var problem: String?
    @Published private(set) var isWorking = false
    /// The title and pretty-printed answer of the last read or action.
    @Published private(set) var answerTitle: String?
    @Published private(set) var answer: String?
    @Published var selectedRunID: String?
    private var generation = 0

    var freshnessLabel: String? {
        loadedAt.map { "Read \($0.formatted(date: .omitted, time: .standard))" }
    }

    func clear() {
        generation += 1
        suites = []
        contenders = []
        runs = []
        selectedRunID = nil
        answerTitle = nil
        answer = nil
        problem = nil
        loadedAt = nil
    }

    /// The manifest's suites and contenders, then its recorded runs.
    func load(root: URL, app: String) async {
        generation += 1
        let requested = generation
        do {
            struct Declared: Decodable {
                let suites: [BenchmarkSuite]
                let contenders: [BenchmarkContender]
            }
            struct Listed: Decodable { let runs: [BenchmarkRun] }
            let declared = try JSONDecoder().decode(
                Declared.self, from: try await answerOf(root, ["suites", app]))
            let listed = try JSONDecoder().decode(
                Listed.self, from: try await answerOf(root, ["list", app]))
            guard requested == generation else { return }
            suites = declared.suites
            contenders = declared.contenders
            runs = listed.runs
            problem = nil
            loadedAt = Date()
        } catch {
            guard requested == generation else { return }
            suites = []
            contenders = []
            runs = []
            problem = error.localizedDescription
        }
    }

    /// A read whose answer is shown as it is: `show`, `standing`, `compare`.
    func read(root: URL, title: String, _ arguments: [String]) async {
        await perform(root: root, title: title, arguments, reload: nil)
    }

    /// An action that changes recorded state — `run`, `roadmap`, `author`,
    /// `author-suite` — then reloads the manifest and the runs.
    func act(root: URL, app: String, title: String, _ arguments: [String]) async {
        await perform(root: root, title: title, arguments, reload: app)
    }

    /// `rivals` prints its whole answer, gaps included, and exits non-zero
    /// while any gap remains: the answer is shown together with the refusal.
    func rivals(root: URL, app: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await ProbierzCLI.run(
                repositoryRoot: root, arguments: ["benchmark", "rivals", app])
            answerTitle = "Rivals of \(app)"
            answer = pretty(outcome.stdout)
            problem = outcome.status == 0 ? nil : ProbierzCLI.refusal(outcome).localizedDescription
        } catch {
            problem = error.localizedDescription
        }
    }

    private func perform(root: URL, title: String, _ arguments: [String], reload app: String?) async
    {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await answerOf(root, arguments)
            answerTitle = title
            answer = pretty(data)
            problem = nil
            if let app { await load(root: root, app: app) }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func answerOf(_ root: URL, _ arguments: [String]) async throws -> Data {
        try await ProbierzCLI.answer(repositoryRoot: root, arguments: ["benchmark"] + arguments)
    }

    private func pretty(_ data: Data) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: data),
            let formatted = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: formatted, as: UTF8.self)
    }
}
