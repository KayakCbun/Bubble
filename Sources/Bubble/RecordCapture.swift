import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

protocol RecordCaptureDelegate: AnyObject {
    func recordCaptureDidOutput(_ buffer: AVAudioPCMBuffer)
    func recordCaptureDidFail(_ error: Error)
}

enum RecordCaptureError: Error, LocalizedError {
    case converter
    case tapFailed(OSStatus)
    case audioPermission

    var errorDescription: String? {
        switch self {
        case .converter:
            return "Bubble could not convert captured audio for transcription."
        case .tapFailed(let status):
            return "系统音频采集失败（\(status)）。请在「系统设置 → 隐私与安全性 → 录屏与系统录音」下方的「仅系统录音」里打开 Bubble，然后完全退出再打开。"
        case .audioPermission:
            return "请在「系统设置 → 隐私与安全性 → 录屏与系统录音」下方的「仅系统录音」里打开 Bubble，关掉开关再打开一次，然后完全退出 Bubble 再试。"
        }
    }
}

final class RecordCapture: NSObject {
    weak var delegate: RecordCaptureDelegate?
    var outputFormat: AVAudioFormat?

    private let queue = DispatchQueue(label: "local.bubble.record-capture", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var systemConverter: AVAudioConverter?
    private var systemConverterInputFormat: AVAudioFormat?
    private var micConverter: AVAudioConverter?
    private var micConverterInputFormat: AVAudioFormat?
    private var engine: AVAudioEngine?
    private var loggedFirstSystemBuffer = false
    private var loggedFirstMicBuffer = false
    private var loggedNonZeroSystem = false

    func start() async throws {
        do {
            try await authorizeSystemAudio()
            try startSystemTap()
            try startMicrophone()
            OverlayLog.write("record capture started (system tap + microphone)")
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        stopMicrophone()
        stopSystemTap()
    }

    private func authorizeSystemAudio() async throws {
        let status = await RecordAudioCaptureAuthorization.ensure()
        OverlayLog.write("record system-audio TCC \(status)")
        switch status {
        case .authorized, .unavailable:
            return
        case .denied, .undetermined:
            Self.openAudioPrivacySettings()
            throw RecordCaptureError.audioPermission
        }
    }

    private func startSystemTap() throws {
        // stereoGlobalTapButExcludeProcesses sets exclusive=true (tap everything
        // except the listed process objects). Do not assign isExclusive afterwards.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.name = "Bubble Record"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        let tapUID = tapDescription.uuid.uuidString

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            OverlayLog.write("record tap create failed: \(tapStatus)")
            RecordAudioCaptureAuthorization.forgetAuthorized()
            Self.openAudioPrivacySettings()
            throw RecordCaptureError.audioPermission
        }
        RecordAudioCaptureAuthorization.rememberAuthorized()
        self.tapID = tapID

        // Tap-only private aggregate. Including the default output as a
        // sub-device makes the IO proc read that device's empty input and
        // look like a working tap that is all zeros.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Bubble Record Aggregate",
            kAudioAggregateDeviceUIDKey: "local.bubble.record.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard aggStatus == noErr, aggregateID != kAudioObjectUnknown else {
            OverlayLog.write("record aggregate failed: \(aggStatus)")
            stopSystemTap()
            throw RecordCaptureError.tapFailed(aggStatus)
        }
        self.aggregateID = aggregateID
        tapFormat = try Self.inputStreamFormat(aggregateID) ?? Self.tapStreamFormat(tapID)
        OverlayLog.write(
            "record tap ready format=\(tapFormat?.sampleRate ?? 0)Hz ch=\(tapFormat?.channelCount ?? 0) interleaved=\(tapFormat?.isInterleaved ?? false)"
        )

        let queue = queue
        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self]
            _, inInputData, _, _, _ in
            self?.handleSystemAudio(inInputData)
        }
        guard ioStatus == noErr, let ioProcID else {
            OverlayLog.write("record io proc failed: \(ioStatus)")
            stopSystemTap()
            throw RecordCaptureError.tapFailed(ioStatus)
        }
        self.ioProcID = ioProcID
        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            OverlayLog.write("record device start failed: \(startStatus)")
            stopSystemTap()
            throw RecordCaptureError.tapFailed(startStatus)
        }
    }

    private func stopSystemTap() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
        ioProcID = nil
        tapFormat = nil
        systemConverter = nil
        systemConverterInputFormat = nil
        loggedFirstSystemBuffer = false
        loggedNonZeroSystem = false
    }

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        OverlayLog.write(
            "record mic format=\(format.sampleRate)Hz ch=\(format.channelCount)"
        )
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let copy = Self.copy(buffer) else { return }
            self?.queue.async {
                self?.emitMicrophone(copy)
            }
        }
        try engine.start()
        self.engine = engine
    }

    private func stopMicrophone() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        micConverter = nil
        micConverterInputFormat = nil
        loggedFirstMicBuffer = false
    }

    private func handleSystemAudio(_ bufferList: UnsafePointer<AudioBufferList>) {
        let rawPeak = Self.ablPeak(bufferList)
        if !loggedFirstSystemBuffer {
            loggedFirstSystemBuffer = true
            OverlayLog.write("record system buffer peak=\(rawPeak)")
        } else if !loggedNonZeroSystem, rawPeak > 0.001 {
            loggedNonZeroSystem = true
            OverlayLog.write("record system audio is live peak=\(rawPeak)")
        }
        guard let tapFormat else { return }
        let source = pcmBuffer(from: bufferList, format: tapFormat)
        guard let source else { return }
        emitConverted(source, converter: &systemConverter, inputFormat: &systemConverterInputFormat)
    }

    private func emitMicrophone(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(
            buffer,
            converter: &micConverter,
            inputFormat: &micConverterInputFormat
        ) else { return }
        guard converted.frameLength > 0, Self.hasFiniteSamples(converted) else { return }
        let peak = RecordAudioConvert.peak(converted)
        if !loggedFirstMicBuffer {
            loggedFirstMicBuffer = true
            OverlayLog.write("record mic buffer peak=\(peak)")
        }
        guard RecordPolicy.shouldSendMicrophone(peak: peak) else { return }
        delegate?.recordCaptureDidOutput(converted)
    }

    private func emitConverted(
        _ buffer: AVAudioPCMBuffer,
        converter: inout AVAudioConverter?,
        inputFormat: inout AVAudioFormat?
    ) {
        guard let converted = convert(buffer, converter: &converter, inputFormat: &inputFormat) else { return }
        guard converted.frameLength > 0, Self.hasFiniteSamples(converted) else { return }
        delegate?.recordCaptureDidOutput(converted)
    }

    private func convert(
        _ input: AVAudioPCMBuffer,
        converter: inout AVAudioConverter?,
        inputFormat: inout AVAudioFormat?
    ) -> AVAudioPCMBuffer? {
        guard let outputFormat else { return input }
        if RecordAudioConvert.formatsMatch(input.format, outputFormat) {
            return input
        }
        if converter == nil || inputFormat != input.format || converter?.outputFormat != outputFormat {
            converter = RecordAudioConvert.converter(from: input.format, to: outputFormat)
            inputFormat = input.format
        }
        guard let converter else { return nil }
        return RecordAudioConvert.convertPacket(input, to: outputFormat, converter: converter)
    }

    private func pcmBuffer(
        from bufferList: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if let wrapped = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil),
           let copy = Self.copy(wrapped) {
            return copy
        }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = abl.first, first.mDataByteSize > 0 else { return nil }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        copy.frameLength = frames
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard abl.count == dst.count else { return nil }
        for index in 0..<abl.count {
            let bytes = Int(min(abl[index].mDataByteSize, dst[index].mDataByteSize))
            guard bytes > 0, let from = abl[index].mData, let to = dst[index].mData else { continue }
            memcpy(to, from, bytes)
        }
        return copy
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard src.count == dst.count else { return nil }
        for index in 0..<src.count {
            let bytes = Int(min(src[index].mDataByteSize, dst[index].mDataByteSize))
            guard bytes > 0, let from = src[index].mData, let to = dst[index].mData else { continue }
            memcpy(to, from, bytes)
        }
        return copy
    }

    private static func hasFiniteSamples(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else { return true }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        for channel in 0..<count {
            for frame in 0..<frames {
                if !channels[channel][frame].isFinite { return false }
            }
        }
        return true
    }

    private static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else {
            return ablPeak(buffer.audioBufferList)
        }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        var peak: Float = 0
        for channel in 0..<count {
            for frame in 0..<frames {
                peak = max(peak, abs(channels[channel][frame]))
            }
        }
        return peak
    }

    private static func ablPeak(_ bufferList: UnsafePointer<AudioBufferList>) -> Float {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var peak: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<count {
                let sample = samples[index]
                if sample.isFinite {
                    peak = max(peak, abs(sample))
                }
            }
        }
        return peak
    }

    private static func tapStreamFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecordCaptureError.tapFailed(err)
        }
        return format
    }

    private static func inputStreamFormat(_ deviceID: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: 0
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        guard err == noErr, asbd.mSampleRate > 0 else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    private static func openAudioPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
