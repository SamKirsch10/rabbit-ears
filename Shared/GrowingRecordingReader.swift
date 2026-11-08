// Shared/GrowingRecordingReader.swift
//
// A tvheadend recording that is still being written, as one forward-only byte stream for a live
// AetherEngine session: the file from its first byte, following it as it grows, then the channel's
// live stream once the recording stops. The engine spools everything it reads into its DVR ring, so
// the whole recording is the live session's rewind buffer and the edge keeps moving without a reload.
//
// /dvrfile answers a range inside the file with 206 and one past its end with a 200 text/html error
// (measured on the test server, 2026-11-08), so anything but a 206 means "nothing new yet".
import AetherEngine
import Foundation

nonisolated final class GrowingRecordingReader: NSObject, IOReader, URLSessionDataDelegate, @unchecked Sendable {
    /// Asked when the file has stopped growing for a moment: true while the recording is still
    /// running, false once it has stopped, nil if the server could not say.
    typealias StillRecording = @Sendable (@escaping @Sendable (Bool?) -> Void) -> Void

    private let fileURL: URL
    private let liveURL: URL
    private let headers: [String: String]
    private let stillRecording: StillRecording
    /// Runs once, on the main queue, the first time the reader reaches the end of what is recorded.
    private let onCaughtUp: @Sendable () -> Void

    // Everything below is guarded by `condition`.
    private let condition = NSCondition()
    /// Received and not yet read: `pending[readIndex...]`.
    private var pending = Data()
    private var readIndex = 0
    private var fileOffset: Int64 = 0
    private var task: URLSessionDataTask?
    private var acceptingResponse = false
    private var receivedThisRequest = 0
    private var suspended = false
    /// The server says the recording has stopped: one more pass drains the file's tail, then live.
    private var fileComplete = false
    private var onLive = false
    /// No more bytes will ever come.
    private var finished = false
    private var closed = false
    /// Bumped by `cancel()`: a read blocked across it returns an error, later reads work again.
    private var interrupts = 0
    private var caughtUp = false
    private var lastStatusCheck = Date.distantPast

    private var session: URLSession!

    /// Received bytes held in memory before the request is suspended. The engine drains the reader
    /// into its disk ring as fast as it can, so this only fills if the ring stalls.
    private static let maxPendingBytes = 8 << 20
    /// How often to look for new bytes once the file's end is reached. The recording grows
    /// continuously, so a short wait keeps the live edge close.
    private static let pollInterval: TimeInterval = 1
    /// How often to ask the server whether the recording is still running, while the file isn't growing.
    private static let statusInterval: TimeInterval = 5

    init(fileURL: URL, liveURL: URL, headers: [String: String],
         stillRecording: @escaping StillRecording, onCaughtUp: @escaping @Sendable () -> Void) {
        self.fileURL = fileURL
        self.liveURL = liveURL
        self.headers = headers
        self.stillRecording = stillRecording
        self.onCaughtUp = onCaughtUp
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        condition.lock()
        startRequestLocked()
        condition.unlock()
    }

    // MARK: IOReader

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        condition.lock()
        defer { condition.unlock() }
        let entryInterrupts = interrupts
        while pending.count == readIndex, !finished, !closed, interrupts == entryInterrupts {
            condition.wait()
        }
        let available = pending.count - readIndex
        guard available > 0 else { return finished ? 0 : -5 }  // AVERROR(EIO): closed or interrupted
        let count = min(Int(size), available)
        pending.withUnsafeBytes { raw in
            buffer.update(from: raw.baseAddress!.advanced(by: readIndex).assumingMemoryBound(to: UInt8.self),
                          count: count)
        }
        readIndex += count
        // Compact once the consumed prefix dominates, so removal stays amortised.
        if readIndex >= 1 << 20, readIndex * 2 >= pending.count {
            pending.removeSubrange(0..<readIndex)
            readIndex = 0
        }
        if suspended, pending.count - readIndex < Self.maxPendingBytes / 2 {
            suspended = false
            task?.resume()
        }
        return Int32(count)
    }

    /// Forward-only: the engine's DVR ring is what makes the stream seekable.
    func seek(offset: Int64, whence: Int32) -> Int64 { -1 }

    func close() {
        condition.lock()
        closed = true
        task?.cancel()
        task = nil
        condition.broadcast()
        condition.unlock()
        session.invalidateAndCancel()
    }

    func cancel() {
        condition.lock()
        interrupts += 1
        condition.broadcast()
        condition.unlock()
    }

    var discImageProbeEnabled: Bool { false }

    // MARK: requests

    private func startRequestLocked() {
        guard !closed else { return }
        var request = URLRequest(url: onLive ? liveURL : fileURL)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if !onLive { request.setValue("bytes=\(fileOffset)-", forHTTPHeaderField: "Range") }
        receivedThisRequest = 0
        acceptingResponse = false
        suspended = false
        let next = session.dataTask(with: request)
        task = next
        next.resume()
    }

    /// The file ended for now. Wait for it to grow, check now and then whether the recording is
    /// still running, and move on to the live stream once it has stopped.
    private func reachedFileEndLocked() {
        if !caughtUp {
            caughtUp = true
            let notify = onCaughtUp
            DispatchQueue.main.async { notify() }
        }
        if fileComplete {
            EngineLog.emit("[GrowingRecording] recording finished at \(fileOffset) bytes; continuing live")
            onLive = true
            startRequestLocked()
            return
        }
        guard Date().timeIntervalSince(lastStatusCheck) >= Self.statusInterval else {
            pollLocked()
            return
        }
        lastStatusCheck = Date()
        stillRecording { [weak self] running in
            guard let self else { return }
            self.condition.lock()
            defer { self.condition.unlock() }
            guard !self.closed else { return }
            if running == false {
                // Drain whatever was written between the last pass and the stop, then go live.
                self.fileComplete = true
                self.startRequestLocked()
            } else {
                self.pollLocked()
            }
        }
    }

    private func pollLocked() {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
            guard let self else { return }
            self.condition.lock()
            if !self.closed, self.task == nil { self.startRequestLocked() }
            self.condition.unlock()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        condition.lock()
        let current = dataTask === task
        let accept = current && (onLive ? (200..<300).contains(status) : status == 206)
        if current { acceptingResponse = accept }
        condition.unlock()
        completionHandler(accept ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard dataTask === task, acceptingResponse, !closed else { return }
        pending.append(data)
        receivedThisRequest += data.count
        if !onLive { fileOffset += Int64(data.count) }
        if !suspended, pending.count - readIndex > Self.maxPendingBytes {
            suspended = true
            dataTask.suspend()
        }
        condition.broadcast()
    }

    func urlSession(_ session: URLSession, task finishedTask: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        defer { condition.unlock() }
        guard finishedTask === task, !closed else { return }
        task = nil
        if onLive {
            // The live stream dropped. The engine reads this as a source reset and retunes.
            EngineLog.emit("[GrowingRecording] live stream ended (\(error.map { "\($0)" } ?? "closed"))")
            finished = true
            condition.broadcast()
            return
        }
        if receivedThisRequest > 0 {
            // More may have been written while this pass downloaded: go straight back for it.
            startRequestLocked()
        } else {
            reachedFileEndLocked()
        }
    }
}
