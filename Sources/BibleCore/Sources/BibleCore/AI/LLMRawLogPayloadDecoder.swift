// LLMRawLogPayloadDecoder.swift -- bounded Android raw-log decoding

import Foundation

/** Stable failures raised while opening an Android-compatible persisted raw LLM log. */
public enum LLMRawLogPayloadDecoderError: Error, Equatable, Sendable {
    /// The payload is neither valid bounded gzip nor supported legacy plain text.
    case invalidPayload
    /// Decompressed bytes are not UTF-8 text.
    case invalidText
}

/** Decodes persisted Android gzip log payloads without exposing the archive implementation. */
public enum LLMRawLogPayloadDecoder {
    /**
     Returns an Android-compatible gzip attachment for one persisted raw log.

     Current records already contain gzip and are validated before reuse. Legacy iOS plain-text
     records are encoded through the same bounded gzip codec used by telemetry persistence.

     - Parameter data: Persisted compressed or legacy plain log bytes.
     - Returns: One validated gzip member suitable for Android-compatible bug reports.
     - Side effects: Gzip validation may use a uniquely named temporary directory that is removed
       before returning.
     - Throws: `LLMRawLogPayloadDecoderError` when the payload is malformed, non-UTF-8, oversized,
       or cannot be compressed within the telemetry limits.
     */
    public static func gzipAttachmentData(_ data: Data) throws -> Data {
        if data.starts(with: [0x1f, 0x8b]) {
            _ = try decode(data)
            return data
        }

        guard data.count <= LLMRunTelemetryService.maximumTranscriptByteCount,
              String(data: data, encoding: .utf8) != nil else {
            throw LLMRawLogPayloadDecoderError.invalidText
        }
        do {
            let compressed = try RemoteSyncArchiveStagingService.gzip(data)
            guard compressed.count <= LLMRunTelemetryService.maximumCompressedLogByteCount else {
                throw LLMRawLogPayloadDecoderError.invalidPayload
            }
            return compressed
        } catch let error as LLMRawLogPayloadDecoderError {
            throw error
        } catch {
            throw LLMRawLogPayloadDecoderError.invalidPayload
        }
    }

    /**
     Decodes one local raw-log payload.

     Android stores every current raw log as gzip. Plain UTF-8 remains accepted for early iOS
     records created before telemetry adopted Android's compressed format.

     - Parameter data: Persisted compressed or legacy plain log bytes.
     - Returns: The complete UTF-8 conversation log.
     - Side effects: Uses a uniquely named temporary directory and removes it before returning.
     - Throws: LLMRawLogPayloadDecoderError for oversized, malformed, or non-UTF-8 content.
     */
    public static func decode(_ data: Data) throws -> String {
        guard data.count <= LLMRunTelemetryService.maximumCompressedLogByteCount else {
            throw LLMRawLogPayloadDecoderError.invalidPayload
        }

        guard data.starts(with: [0x1f, 0x8b]) else {
            guard let text = String(data: data, encoding: .utf8) else {
                throw LLMRawLogPayloadDecoderError.invalidText
            }
            return text
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("andbible-raw-log-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = directory.appendingPathComponent("log.gz")
        let outputURL = directory.appendingPathComponent("log.txt")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: directory) }
            try data.write(to: archiveURL, options: .withoutOverwriting)
            try RemoteSyncBoundedFileIO.inflateGzip(
                at: archiveURL,
                to: outputURL,
                maximumCompressedByteCount: LLMRunTelemetryService.maximumCompressedLogByteCount,
                maximumExpandedByteCount: LLMRunTelemetryService.maximumTranscriptByteCount
            )
            let expanded = try Data(
                contentsOf: outputURL,
                options: [.mappedIfSafe, .uncached]
            )
            guard let text = String(data: expanded, encoding: .utf8) else {
                throw LLMRawLogPayloadDecoderError.invalidText
            }
            return text
        } catch let error as LLMRawLogPayloadDecoderError {
            throw error
        } catch {
            try? fileManager.removeItem(at: directory)
            throw LLMRawLogPayloadDecoderError.invalidPayload
        }
    }
}
