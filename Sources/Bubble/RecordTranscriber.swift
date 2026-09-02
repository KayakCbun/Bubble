import AVFoundation
import Foundation
import Speech

protocol RecordTranscriber: AnyObject {
    var inputFormat: AVAudioFormat? { get }
    func start(locale: Locale) async throws
    func send(_ buffer: AVAudioPCMBuffer)
    func finalize() async -> String
}

final class SpeechAnalyzerTranscriber: RecordTranscriber {
    private(set) var inputFormat: AVAudioFormat?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var volatileNotes = ""
    private var finalizedNotes = ""
    private var onCaptions: ((String) -> Void)?
    private var ready = false
    private var sentBuffers = 0
    private var resultCount = 0
    private var droppedFormat = 0

    init(onCaptions: ((String) -> Void)? = nil) {
        self.onCaptions = onCaptions
    }

    func start(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(
            locale: try await Self.resolvedLocale(locale),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            OverlayLog.write("record downloading speech assets")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw RecordCaptureError.converter
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputSequence)
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.inputBuilder = inputBuilder
        self.inputFormat = format
        volatileNotes = ""
        finalizedNotes = ""
        ready = true
        OverlayLog.write(
            "record transcriber ready format=\(format.sampleRate)Hz ch=\(format.channelCount) interleaved=\(format.isInterleaved)"
        )
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    self.resultCount += 1
                    await MainActor.run {
                        if result.isFinal {
                            self.appendFinal(text)
                        } else {
                            self.volatileNotes = Self.merge(final: self.finalizedNotes, volatile: text)
                            self.onCaptions?(self.volatileNotes)
                        }
                    }
                }
            } catch {
                OverlayLog.write("record transcriber failed: \(error.localizedDescription)")
            }
        }
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        guard ready, buffer.frameLength > 0 else { return }
        guard let inputFormat,
              buffer.format.sampleRate == inputFormat.sampleRate,
              buffer.format.channelCount == inputFormat.channelCount else {
            droppedFormat += 1
            return
        }
        sentBuffers += 1
        inputBuilder?.yield(AnalyzerInput(buffer: buffer))
    }

    func finalize() async -> String {
        ready = false
        inputBuilder?.finish()
        inputBuilder = nil
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                OverlayLog.write("record transcriber finalize failed: \(error.localizedDescription)")
            }
        }
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        inputFormat = nil
        let notes = volatileNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let finished = notes.isEmpty ? finalizedNotes : notes
        OverlayLog.write(
            "record transcriber finished notes=\(finished.count) sent=\(sentBuffers) results=\(resultCount) dropped=\(droppedFormat)"
        )
        return finished
    }

    private func appendFinal(_ text: String) {
        if finalizedNotes.isEmpty {
            finalizedNotes = text
        } else if !finalizedNotes.hasSuffix(text) {
            finalizedNotes += finalizedNotes.hasSuffix(" ") || text.hasPrefix(" ") ? text : " " + text
        }
        volatileNotes = finalizedNotes
        onCaptions?(volatileNotes)
    }

    private static func merge(final: String, volatile: String) -> String {
        if final.isEmpty { return volatile }
        if volatile.isEmpty { return final }
        if volatile.hasPrefix(final) { return volatile }
        return final + (final.hasSuffix(" ") || volatile.hasPrefix(" ") ? "" : " ") + volatile
    }

    private static func resolvedLocale(_ preferred: Locale) async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        if supported.contains(where: { $0.identifier == preferred.identifier }) {
            return preferred
        }
        let language = preferred.language.languageCode?.identifier
        if let language,
           let match = supported.first(where: { $0.identifier.hasPrefix(language) }) {
            return match
        }
        if let english = supported.first(where: { $0.identifier.hasPrefix("en") }) {
            OverlayLog.write("record falling back to locale \(english.identifier)")
            return english
        }
        return preferred
    }
}
