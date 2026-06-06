import Foundation
import simd

/// Samples a single glTF animation clip into per-node local transforms.
///
/// This is engine-agnostic: it decodes the keyframe accessors of a
/// ``GLTF/Animation`` once and then evaluates translation / rotation / scale for
/// every animated node at an arbitrary time. Renderers map the returned node
/// indices onto their own scene graph (for `.vrma`, via
/// ``VRMAnimation/humanoidBoneNodeMap``).
public struct VRMAnimationSampler {
    /// A node's animated local transform at a given time. Each component is `nil`
    /// when the clip does not animate it.
    public struct NodeTransform {
        public var translation: SIMD3<Float>?
        public var rotation: simd_quatf?
        public var scale: SIMD3<Float>?
    }

    /// Total length of the clip in seconds (the largest keyframe time).
    public let duration: TimeInterval

    private struct Track {
        enum Path {
            case translation
            case rotation
            case scale
        }

        let node: Int
        let path: Path
        let interpolation: GLTF.Animation.Sampler.Interpolation
        let input: [Float]      // keyframe times (ascending)
        let output: [SIMD4<Float>] // packed values; xyz used for VEC3, xyzw for VEC4
        let componentCount: Int // 3 for translation/scale, 4 for rotation
    }

    private let tracks: [Track]

    public init(animation: GLTF.Animation, gltf: BinaryGLTF, rootDirectory: URL? = nil) throws {
        var tracks: [Track] = []
        var maxTime: Float = 0

        for channel in animation.channels {
            guard let node = channel.target.node else { continue }
            let path: Track.Path
            switch channel.target.path {
            case "translation": path = .translation
            case "rotation": path = .rotation
            case "scale": path = .scale
            default: continue // weights handled separately (expressions)
            }

            guard animation.samplers.indices.contains(channel.sampler) else { continue }
            let sampler = animation.samplers[channel.sampler]

            let input = try Self.readScalars(accessorIndex: sampler.input, gltf: gltf, rootDirectory: rootDirectory)
            guard !input.isEmpty else { continue }
            let componentCount = (path == .rotation) ? 4 : 3
            let output = try Self.readVectors(accessorIndex: sampler.output,
                                              componentCount: componentCount,
                                              gltf: gltf,
                                              rootDirectory: rootDirectory)

            maxTime = max(maxTime, input.last ?? 0)
            tracks.append(Track(node: node,
                                path: path,
                                interpolation: sampler.interpolation,
                                input: input,
                                output: output,
                                componentCount: componentCount))
        }

        self.tracks = tracks
        self.duration = TimeInterval(maxTime)
    }

    /// Evaluates every animated node's local transform at `time` (seconds).
    public func sample(at time: TimeInterval) -> [Int: NodeTransform] {
        let t = Float(time)
        var result: [Int: NodeTransform] = [:]

        for track in tracks {
            let value = evaluate(track: track, time: t)
            var transform = result[track.node] ?? NodeTransform()
            switch track.path {
            case .translation:
                transform.translation = SIMD3<Float>(value.x, value.y, value.z)
            case .scale:
                transform.scale = SIMD3<Float>(value.x, value.y, value.z)
            case .rotation:
                transform.rotation = Self.normalizedQuat(value)
            }
            result[track.node] = transform
        }
        return result
    }

    // MARK: - Evaluation

    private func evaluate(track: Track, time: Float) -> SIMD4<Float> {
        let input = track.input
        let isCubic = track.interpolation == .CUBICSPLINE

        // Clamp outside the keyframe range.
        if time <= input.first! {
            return isCubic ? cubicValue(track: track, keyframe: 0) : track.output[0]
        }
        if time >= input.last! {
            let last = input.count - 1
            return isCubic ? cubicValue(track: track, keyframe: last) : track.output[last]
        }

        // Binary search for the segment [i, i+1] containing `time`.
        var lo = 0
        var hi = input.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if input[mid] <= time { lo = mid } else { hi = mid }
        }

        let t0 = input[lo]
        let t1 = input[hi]
        let dt = t1 - t0
        let f = dt > 0 ? (time - t0) / dt : 0

        switch track.interpolation {
        case .STEP:
            return track.output[lo]
        case .LINEAR:
            if track.path == .rotation {
                let q0 = Self.normalizedQuat(track.output[lo])
                let q1 = Self.normalizedQuat(track.output[hi])
                let q = simd_slerp(q0, q1, f)
                return SIMD4<Float>(q.imag.x, q.imag.y, q.imag.z, q.real)
            } else {
                return mix(track.output[lo], track.output[hi], t: f)
            }
        case .CUBICSPLINE:
            // output layout per keyframe: [inTangent, value, outTangent]
            let v0 = cubicValue(track: track, keyframe: lo)
            let v1 = cubicValue(track: track, keyframe: hi)
            let b0 = track.output[lo * 3 + 2] // outTangent of keyframe lo
            let a1 = track.output[hi * 3 + 0] // inTangent of keyframe hi
            let m0 = b0 * dt
            let m1 = a1 * dt
            let f2 = f * f
            let f3 = f2 * f
            let h00 = 2 * f3 - 3 * f2 + 1
            let h10 = f3 - 2 * f2 + f
            let h01 = -2 * f3 + 3 * f2
            let h11 = f3 - f2
            let value = h00 * v0 + h10 * m0 + h01 * v1 + h11 * m1
            return value
        }
    }

    private func cubicValue(track: Track, keyframe: Int) -> SIMD4<Float> {
        // The value sits between the in/out tangents for each keyframe.
        track.output[keyframe * 3 + 1]
    }

    private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, t: Float) -> SIMD4<Float> {
        a + (b - a) * t
    }

    private static func normalizedQuat(_ v: SIMD4<Float>) -> simd_quatf {
        if v.x == 0 && v.y == 0 && v.z == 0 && v.w == 0 {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }
        return simd_normalize(simd_quatf(ix: v.x, iy: v.y, iz: v.z, r: v.w))
    }

    // MARK: - Accessor reading

    private static func readScalars(accessorIndex: Int, gltf: BinaryGLTF, rootDirectory: URL?) throws -> [Float] {
        let vectors = try readVectors(accessorIndex: accessorIndex, componentCount: 1, gltf: gltf, rootDirectory: rootDirectory)
        return vectors.map { $0.x }
    }

    /// Reads `componentCount` floats per element from an accessor into packed SIMD4 values.
    private static func readVectors(accessorIndex: Int,
                                    componentCount: Int,
                                    gltf: BinaryGLTF,
                                    rootDirectory: URL?) throws -> [SIMD4<Float>] {
        let accessor = try gltf.jsonData.load(\.accessors)[accessorIndex]
        let bytesPerComponent = Self.bytes(of: accessor.componentType)
        let componentsPerVector = Self.numberOfComponents(of: accessor.type)
        let vectorSize = bytesPerComponent * componentsPerVector

        let data: Data
        if let bufferViewIndex = accessor.bufferView {
            let view = try gltf.bufferViewData(at: bufferViewIndex, relativeTo: rootDirectory)
            let stride = view.stride ?? vectorSize
            data = view.data.subdata(offset: accessor.byteOffset, size: vectorSize, stride: stride, count: accessor.count)
        } else {
            data = Data(count: vectorSize * accessor.count)
        }

        var result: [SIMD4<Float>] = []
        result.reserveCapacity(accessor.count)
        let normalized = accessor.normalized
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<accessor.count {
                let elementOffset = i * vectorSize
                var values = SIMD4<Float>(0, 0, 0, 0)
                for c in 0..<min(componentsPerVector, 4) {
                    let offset = elementOffset + c * bytesPerComponent
                    values[c] = Self.readComponent(base: base,
                                                   offset: offset,
                                                   componentType: accessor.componentType,
                                                   normalized: normalized)
                }
                result.append(values)
            }
        }
        return result
    }

    private static func readComponent(base: UnsafeRawPointer,
                                      offset: Int,
                                      componentType: GLTF.Accessor.ComponentType,
                                      normalized: Bool) -> Float {
        switch componentType {
        case .float:
            return base.loadUnaligned(fromByteOffset: offset, as: Float.self)
        case .byte:
            let v = Float(base.loadUnaligned(fromByteOffset: offset, as: Int8.self))
            return normalized ? max(v / 127.0, -1.0) : v
        case .unsignedByte:
            let v = Float(base.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
            return normalized ? v / 255.0 : v
        case .short:
            let v = Float(base.loadUnaligned(fromByteOffset: offset, as: Int16.self))
            return normalized ? max(v / 32767.0, -1.0) : v
        case .unsignedShort:
            let v = Float(base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            return normalized ? v / 65535.0 : v
        case .unsignedInt:
            return Float(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func bytes(of type: GLTF.Accessor.ComponentType) -> Int {
        switch type {
        case .byte, .unsignedByte: return 1
        case .short, .unsignedShort: return 2
        case .unsignedInt, .float: return 4
        }
    }

    private static func numberOfComponents(of type: GLTF.Accessor.`Type`) -> Int {
        switch type {
        case .SCALAR: return 1
        case .VEC2: return 2
        case .VEC3: return 3
        case .VEC4: return 4
        case .MAT2: return 4
        case .MAT3: return 9
        case .MAT4: return 16
        }
    }
}
