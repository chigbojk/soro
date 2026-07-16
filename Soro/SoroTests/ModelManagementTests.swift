import XCTest
@testable import Soro

/// Covers the curated model catalogues, install-state detection, selected-model
/// resolution, and OllamaClient's pure tag/pull parsing (task: model-management).
final class ModelManagementTests: XCTestCase {

    // MARK: - Whisper curated catalogue

    func testWhisperCuratedListNonEmptyAndUnique() {
        let ids = ModelManager.curatedModels.map(\.id)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(Set(ids).count, ids.count, "curated whisper ids must be unique")
    }

    func testWhisperCuratedIncludesDefaultAndHasHints() {
        XCTAssertTrue(ModelManager.curatedModels.contains { $0.id == ModelManager.defaultModel })
        for m in ModelManager.curatedModels {
            XCTAssertFalse(m.name.isEmpty)
            XCTAssertFalse(m.sizeHint.isEmpty)
            XCTAssertFalse(m.qualityHint.isEmpty)
        }
    }

    func testAvailableModelsMirrorsCuratedIDs() {
        XCTAssertEqual(ModelManager.availableModels, ModelManager.curatedModels.map(\.id))
    }

    func testCuratedModelLookup() {
        XCTAssertEqual(ModelManager.curatedModel(id: ModelManager.defaultModel)?.id,
                       ModelManager.defaultModel)
        XCTAssertNil(ModelManager.curatedModel(id: "does-not-exist"))
    }

    // MARK: - selectedModel resolution

    func testSelectedModelReadsPref() {
        var prefs = Preferences.default
        prefs.whisperModel = "openai_whisper-medium.en"
        XCTAssertEqual(ModelManager.selectedModel(from: prefs), "openai_whisper-medium.en")
    }

    func testSelectedModelFallsBackWhenEmpty() {
        var prefs = Preferences.default
        prefs.whisperModel = ""
        XCTAssertEqual(ModelManager.selectedModel(from: prefs), ModelManager.defaultModel)
    }

    func testSelectedModelDefaultPrefIsDefaultModel() {
        XCTAssertEqual(ModelManager.selectedModel(from: .default), ModelManager.defaultModel)
    }

    // MARK: - Whisper install-state detection (on disk)

    func testWhisperInstallDetectionRoundTrip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soro-modeltest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let paths = AppPaths(root: tmp)
        let mgr = ModelManager(paths: paths)
        let name = "openai_whisper-base.en"

        XCTAssertFalse(mgr.isModelInstalled(name), "absent before creating folder")

        let folder = mgr.modelFolder(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Empty folder must not count as installed.
        XCTAssertFalse(mgr.isModelInstalled(name), "empty folder is not installed")

        try Data("x".utf8).write(to: folder.appendingPathComponent("model.mlmodelc"))
        XCTAssertTrue(mgr.isModelInstalled(name), "non-empty folder is installed")
    }

    // MARK: - Ollama curated catalogue

    func testOllamaCuratedListNonEmptyAndUnique() {
        let ids = OllamaClient.curatedModels.map(\.id)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains("llama3.2:3b"))
        for m in OllamaClient.curatedModels {
            XCTAssertFalse(m.label.isEmpty)
            XCTAssertFalse(m.hint.isEmpty)
        }
    }

    func testOllamaCuratedLookup() {
        XCTAssertEqual(OllamaClient.curatedModel(id: "llama3.2:3b")?.id, "llama3.2:3b")
        XCTAssertNil(OllamaClient.curatedModel(id: "nope"))
    }

    // MARK: - Ollama tag normalization + install detection (pure)

    func testNormalizeTagAddsLatest() {
        XCTAssertEqual(OllamaClient.normalizeTag("llama3.2"), "llama3.2:latest")
        XCTAssertEqual(OllamaClient.normalizeTag("llama3.2:3b"), "llama3.2:3b")
    }

    func testIsInstalledMatchesExactAndLatest() {
        let installed = ["llama3.2:3b", "qwen2.5:latest"]
        XCTAssertTrue(OllamaClient.isInstalled("llama3.2:3b", in: installed))
        // Bare name matches the :latest entry.
        XCTAssertTrue(OllamaClient.isInstalled("qwen2.5", in: installed))
        XCTAssertTrue(OllamaClient.isInstalled("qwen2.5:latest", in: installed))
        XCTAssertFalse(OllamaClient.isInstalled("llama3.1:8b", in: installed))
    }

    // MARK: - /api/tags parsing (pure)

    func testParseTagNames() throws {
        let json = """
        {"models":[{"name":"llama3.2:3b"},{"name":"qwen2.5:7b"}]}
        """
        let names = OllamaClient.parseTagNames(from: Data(json.utf8))
        XCTAssertEqual(names, ["llama3.2:3b", "qwen2.5:7b"])
    }

    func testParseTagNamesMalformedReturnsEmpty() {
        XCTAssertEqual(OllamaClient.parseTagNames(from: Data("not json".utf8)), [])
        XCTAssertEqual(OllamaClient.parseTagNames(from: Data("{}".utf8)), [])
    }

    // MARK: - /api/pull progress parsing (pure)

    func testParsePullProgressWithTotals() throws {
        let line = #"{"status":"downloading","total":1000,"completed":250}"#
        let parsed = try XCTUnwrap(OllamaClient.parsePullProgress(from: Data(line.utf8)))
        XCTAssertEqual(parsed.fraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(parsed.status, "downloading")
    }

    func testParsePullProgressStatusOnly() throws {
        let line = #"{"status":"success"}"#
        let parsed = try XCTUnwrap(OllamaClient.parsePullProgress(from: Data(line.utf8)))
        XCTAssertNil(parsed.fraction)
        XCTAssertEqual(parsed.status, "success")
    }

    func testParsePullProgressClampsAndGuardsZeroTotal() throws {
        // total 0 must not divide-by-zero → nil fraction.
        let zero = #"{"status":"x","total":0,"completed":5}"#
        XCTAssertNil(try XCTUnwrap(OllamaClient.parsePullProgress(from: Data(zero.utf8))).fraction)
        // completed > total clamps to 1.0.
        let over = #"{"status":"x","total":10,"completed":50}"#
        XCTAssertEqual(try XCTUnwrap(OllamaClient.parsePullProgress(from: Data(over.utf8))).fraction, 1.0)
    }

    func testParsePullProgressMalformedReturnsNil() {
        XCTAssertNil(OllamaClient.parsePullProgress(from: Data("garbage".utf8)))
    }

    // MARK: - Pref persistence round trip (selected models)

    func testSelectedModelsPersistThroughCodable() throws {
        var prefs = Preferences.default
        prefs.whisperModel = "openai_whisper-medium.en"
        prefs.ollamaModel = "qwen2.5:7b"
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(decoded.whisperModel, "openai_whisper-medium.en")
        XCTAssertEqual(decoded.ollamaModel, "qwen2.5:7b")
    }
}
