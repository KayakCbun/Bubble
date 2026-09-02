import AVFoundation
import Foundation

enum RecordAudioConvert {
    static func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    static func seedAsrInputFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    static func pcmInt16LE(_ buffer: AVAudioPCMBuffer) -> Data? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return Data() }
        var samples = [Int16](repeating: 0, count: frames)
        if buffer.format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData {
            for frame in 0..<frames {
                let clipped = max(-1, min(1, channels[0][frame]))
                samples[frame] = Int16((clipped * 32767).rounded())
            }
        } else {
            let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let data = abl.first?.mData else { return nil }
            if buffer.format.commonFormat == .pcmFormatInt16 {
                memcpy(&samples, data, frames * MemoryLayout<Int16>.size)
            } else {
                let floats = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    let clipped = max(-1, min(1, floats[frame]))
                    samples[frame] = Int16((clipped * 32767).rounded())
                }
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    static func converter(from input: AVAudioFormat, to output: AVAudioFormat) -> AVAudioConverter? {
        AVAudioConverter(from: input, to: output)
    }

    /// Convert one capture packet with a long-lived converter.
    /// Do not send `endOfStream` here: that finishes the converter and every
    /// later packet comes out empty, so Record notes stay blank after stop.
    static func convertPacket(
        _ input: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        if formatsMatch(input.format, outputFormat) { return input }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var gotInput = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if gotInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            gotInput = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        if buffer.format.commonFormat == .pcmFormatFloat32,
           let channels = buffer.floatChannelData {
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
        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var peak: Float = 0
        for item in abl {
            guard let data = item.mData, item.mDataByteSize > 0 else { continue }
            let count = Int(item.mDataByteSize) / MemoryLayout<Float>.size
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
}
