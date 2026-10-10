// A short GPU benchmark in real units: how many floating-point operations
// per second the shader cores sustain, and how fast the GPU moves memory.
//
// The kernels are compiled from source at run time, so the app ships no
// Metal library. Each measurement is one command buffer of about 40 ms timed
// by the GPU's own clock, so the screen keeps drawing between them.

import Foundation
import Metal
import Synchronization

/// One of the measurements a quick run makes.
enum BenchmarkTest: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case fp32, fp16, bandwidth

    var label: String {
        switch self {
        case .fp32: "32-bit compute"
        case .fp16: "16-bit compute"
        case .bandwidth: "Memory speed"
        }
    }

    var unit: String {
        self == .bandwidth ? "GB/s" : "TFLOPS"
    }

    /// What the number means, in a sentence.
    var explanation: String {
        switch self {
        case .fp32: "Trillions of 32-bit float operations per second, as games and most apps use."
        case .fp16: "The same with 16-bit floats, common in image processing and machine learning."
        case .bandwidth: "Gigabytes per second the GPU can read and write in memory."
        }
    }
}

/// Results of one quick run.
struct BenchmarkResult: Codable, Sendable, Equatable, Identifiable {
    let date: Date
    let gpu: String
    let values: [BenchmarkTest: Double]

    var id: Date { date }

    func value(_ test: BenchmarkTest) -> Double? { values[test] }
}

enum BenchmarkError: Error, Equatable, CustomStringConvertible {
    case noGPU
    case setup(String)
    case gpu(String)
    case cancelled

    var description: String {
        switch self {
        case .noGPU: "This Mac has no GPU that Metal can use."
        case .setup(let detail): "The benchmark couldn't start: \(detail)"
        case .gpu(let detail): "The GPU reported an error: \(detail)"
        case .cancelled: "The benchmark was stopped."
        }
    }
}

/// Lets the main thread stop a run between two command buffers.
final class Cancellation: Sendable {
    private let flag = Atomic<Bool>(false)

    var isCancelled: Bool { flag.load(ordering: .relaxed) }

    func cancel() { flag.store(true, ordering: .relaxed) }
}

/// Owns the Metal objects. Used by one thread at a time.
final class GPUBenchmark: @unchecked Sendable {
    /// Each timed command buffer aims for this long on the GPU.
    static let targetSeconds = 0.04
    /// Threads per compute dispatch; a multiple of every threadgroup size used.
    static let threads = 1 << 20
    /// Fused multiply-adds per loop iteration and thread: 16 calls on 4 lanes.
    static let fmasPerIteration = 64.0

    let name: String
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [String: MTLComputePipelineState]

    private static let source = """
        #include <metal_stdlib>
        using namespace metal;

        // Eight independent chains hide the latency of each fused multiply-add.
        #define FMA_BODY(T) \\
            T a0 = T(float(id & 1023) * 1e-4f), a1 = a0 + T(0.1f), a2 = a0 + T(0.2f), a3 = a0 + T(0.3f); \\
            T a4 = a0 + T(0.4f), a5 = a0 + T(0.5f), a6 = a0 + T(0.6f), a7 = a0 + T(0.7f); \\
            const T m = T(0.999f), k = T(0.0001f); \\
            for (uint i = 0; i < n; i++) { \\
                a0 = fma(a0, m, k); a1 = fma(a1, m, k); a2 = fma(a2, m, k); a3 = fma(a3, m, k); \\
                a4 = fma(a4, m, k); a5 = fma(a5, m, k); a6 = fma(a6, m, k); a7 = fma(a7, m, k); \\
                a0 = fma(a0, m, k); a1 = fma(a1, m, k); a2 = fma(a2, m, k); a3 = fma(a3, m, k); \\
                a4 = fma(a4, m, k); a5 = fma(a5, m, k); a6 = fma(a6, m, k); a7 = fma(a7, m, k); \\
            } \\
            out[id] = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;

        kernel void fp32(device float4 *out [[buffer(0)]], constant uint &n [[buffer(1)]], uint id [[thread_position_in_grid]]) {
            FMA_BODY(float4)
        }

        kernel void fp16(device half4 *out [[buffer(0)]], constant uint &n [[buffer(1)]], uint id [[thread_position_in_grid]]) {
            FMA_BODY(half4)
        }

        kernel void bandwidth(device const float4 *source [[buffer(0)]], device float4 *destination [[buffer(1)]],
                              uint id [[thread_position_in_grid]]) {
            destination[id] = source[id];
        }
        """

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw BenchmarkError.noGPU }
        guard let queue = device.makeCommandQueue() else { throw BenchmarkError.setup("no command queue") }
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            var pipelines: [String: MTLComputePipelineState] = [:]
            for test in BenchmarkTest.allCases {
                guard let function = library.makeFunction(name: test.rawValue) else {
                    throw BenchmarkError.setup("missing kernel \(test.rawValue)")
                }
                pipelines[test.rawValue] = try device.makeComputePipelineState(function: function)
            }
            self.pipelines = pipelines
        } catch let error as BenchmarkError {
            throw error
        } catch {
            throw BenchmarkError.setup(error.localizedDescription)
        }
        self.device = device
        self.queue = queue
        name = device.name
    }

    /// Calibrates the work per command buffer, then keeps the best of `runs`.
    func measure(_ test: BenchmarkTest, runs: Int = 5, cancellation: Cancellation) throws -> Double {
        switch test {
        case .fp32, .fp16:
            let output = try outputBuffer(test)
            let iterations = try calibrate(test, output: output, cancellation: cancellation)
            var best = 0.0
            for _ in 0..<runs {
                best = max(best, try compute(test, iterations: iterations, output: output, cancellation: cancellation).rate)
            }
            return best
        case .bandwidth:
            let buffers = try copyBuffers()
            var best = 0.0
            for _ in 0..<runs {
                best = max(best, try copy(buffers, cancellation: cancellation))
            }
            return best
        }
    }

    /// Runs 32-bit compute back to back for `duration`, reporting TFLOPS
    /// about once a second. A Mac that gets hot slows down as it goes.
    func sustain(for duration: Duration, cancellation: Cancellation, report: (Double) -> Void) throws {
        let output = try outputBuffer(.fp32)
        let iterations = try calibrate(.fp32, output: output, cancellation: cancellation)
        let clock = ContinuousClock()
        let start = clock.now
        var windowStart = start
        var operations = 0.0
        var seconds = 0.0
        while clock.now - start < duration {
            let run = try compute(.fp32, iterations: iterations, output: output, cancellation: cancellation)
            operations += run.operations
            seconds += run.seconds
            if clock.now - windowStart >= .seconds(1), seconds > 0 {
                report(operations / seconds / 1e12)
                windowStart = clock.now
                operations = 0
                seconds = 0
            }
        }
    }

    // MARK: Compute

    private func outputBuffer(_ test: BenchmarkTest) throws -> MTLBuffer {
        let laneBytes = test == .fp16 ? 8 : 16
        guard let output = device.makeBuffer(length: Self.threads * laneBytes, options: .storageModePrivate) else {
            throw BenchmarkError.setup("out of GPU memory")
        }
        return output
    }

    /// Loop count that makes one dispatch take about ``targetSeconds``.
    private func calibrate(_ test: BenchmarkTest, output: MTLBuffer, cancellation: Cancellation) throws -> UInt32 {
        var iterations: UInt32 = 64
        // The first dispatch also warms the GPU up from idle clocks.
        while true {
            let seconds = try compute(test, iterations: iterations, output: output, cancellation: cancellation).seconds
            let scaled = Double(iterations) * Self.targetSeconds / max(seconds, 1e-6)
            if seconds >= Self.targetSeconds / 4 || iterations >= 1 << 16 {
                return UInt32(min(max(scaled, 16), Double(1 << 18)))
            }
            iterations = UInt32(min(Double(1 << 16), max(Double(iterations) * 4, scaled / 2)))
        }
    }

    private func compute(_ test: BenchmarkTest, iterations: UInt32, output: MTLBuffer, cancellation: Cancellation)
        throws -> (operations: Double, seconds: Double, rate: Double)
    {
        guard !cancellation.isCancelled else { throw BenchmarkError.cancelled }
        guard let pipeline = pipelines[test.rawValue] else { throw BenchmarkError.setup("missing kernel \(test.rawValue)") }
        var count = iterations
        let seconds = try run { encoder in
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(output, offset: 0, index: 0)
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
            dispatch(encoder, pipeline: pipeline, threads: Self.threads)
        }
        let operations = Double(Self.threads) * Double(iterations) * Self.fmasPerIteration * 2
        return (operations, seconds, operations / seconds / 1e12)
    }

    // MARK: Memory

    private struct CopyBuffers {
        let source: MTLBuffer
        let destination: MTLBuffer
        let elements: Int
    }

    private func copyBuffers() throws -> CopyBuffers {
        // Large enough to defeat every cache, small enough for an 8 GB Mac.
        let budget = Int(min(UInt64(256 << 20), max(UInt64(16 << 20), device.recommendedMaxWorkingSetSize / 16)))
        let bytes = budget / 4096 * 4096
        guard let source = device.makeBuffer(length: bytes, options: .storageModePrivate),
              let destination = device.makeBuffer(length: bytes, options: .storageModePrivate)
        else { throw BenchmarkError.setup("out of GPU memory") }
        return CopyBuffers(source: source, destination: destination, elements: bytes / 16)
    }

    /// GB/s read plus written by four back-to-back copies.
    private func copy(_ buffers: CopyBuffers, cancellation: Cancellation) throws -> Double {
        guard !cancellation.isCancelled else { throw BenchmarkError.cancelled }
        guard let pipeline = pipelines[BenchmarkTest.bandwidth.rawValue] else { throw BenchmarkError.setup("missing kernel") }
        let passes = 4
        let seconds = try run { encoder in
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffers.source, offset: 0, index: 0)
            encoder.setBuffer(buffers.destination, offset: 0, index: 1)
            for _ in 0..<passes {
                dispatch(encoder, pipeline: pipeline, threads: buffers.elements)
            }
        }
        return Double(buffers.elements * 16 * 2 * passes) / seconds / 1e9
    }

    // MARK: Plumbing

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, threads: Int) {
        let width = min(256, pipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreadgroups(
            MTLSize(width: (threads + width - 1) / width, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
    }

    /// Encodes, runs and waits for one command buffer; returns its GPU time.
    private func run(_ encode: (MTLComputeCommandEncoder) -> Void) throws -> Double {
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else {
            throw BenchmarkError.setup("no command buffer")
        }
        encode(encoder)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error {
            throw BenchmarkError.gpu(error.localizedDescription)
        }
        let seconds = buffer.gpuEndTime - buffer.gpuStartTime
        guard seconds > 0 else { throw BenchmarkError.gpu("the GPU reported no time") }
        return seconds
    }
}
