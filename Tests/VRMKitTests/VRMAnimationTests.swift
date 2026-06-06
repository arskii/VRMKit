import XCTest
import simd
@testable import VRMKit

final class VRMAnimationTests: XCTestCase {

    /// Builds a minimal in-memory `.vrma` (GLB) with a single rotation track on
    /// node 0 (the `hips` bone): identity at t=0, 90° about Y at t=1, LINEAR.
    private func makeVRMA() -> Data {
        // BIN chunk: input [0, 1] then output quaternions [identity, 90°-Y].
        let s = Float(sin(Double.pi / 4)) // sin 45°
        let c = Float(cos(Double.pi / 4))
        let floats: [Float] = [
            0.0, 1.0,           // input (SCALAR x2)
            0, 0, 0, 1,         // output q0 = identity
            0, s, 0, c,         // output q1 = 90° about Y
        ]
        var bin = Data()
        for f in floats { withUnsafeBytes(of: f.bitPattern.littleEndian) { bin.append(contentsOf: $0) } }

        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "extensionsUsed": ["VRMC_vrm_animation"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["name": "hips"]],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 8],
                ["buffer": 0, "byteOffset": 8, "byteLength": 32],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR"],
                ["bufferView": 1, "componentType": 5126, "count": 2, "type": "VEC4"],
            ],
            "animations": [[
                "channels": [["sampler": 0, "target": ["node": 0, "path": "rotation"]]],
                "samplers": [["input": 0, "output": 1, "interpolation": "LINEAR"]],
            ]],
            "extensions": [
                "VRMC_vrm_animation": [
                    "specVersion": "1.0",
                    "humanoid": ["humanBones": ["hips": ["node": 0]]],
                ],
            ],
        ]
        return Self.makeGLB(json: json, bin: bin)
    }

    private static func makeGLB(json: [String: Any], bin: Data) -> Data {
        var jsonData = try! JSONSerialization.data(withJSONObject: json)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) } // pad with spaces
        var binData = bin
        while binData.count % 4 != 0 { binData.append(0x00) }

        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        let totalLength = UInt32(12 + 8 + jsonData.count + 8 + binData.count)
        var glb = Data()
        glb.append(u32(0x46546C67)) // magic "glTF"
        glb.append(u32(2))          // version
        glb.append(u32(totalLength))
        glb.append(u32(UInt32(jsonData.count)))
        glb.append(u32(0x4E4F534A)) // "JSON"
        glb.append(jsonData)
        glb.append(u32(UInt32(binData.count)))
        glb.append(u32(0x004E4942)) // "BIN\0"
        glb.append(binData)
        return glb
    }

    func testParseVRMAExtension() throws {
        let animation = try VRMAnimation(data: makeVRMA())
        XCTAssertEqual(animation.specVersion, "1.0")
        XCTAssertEqual(animation.humanoidBoneNodeMap["hips"], 0)
        XCTAssertEqual(animation.clips.count, 1)
    }

    func testSamplerDurationAndInterpolation() throws {
        let animation = try VRMAnimation(data: makeVRMA())
        let sampler = try VRMAnimationSampler(animation: animation.clips[0], gltf: animation.gltf)
        XCTAssertEqual(sampler.duration, 1.0, accuracy: 1e-5)

        // At t=0: identity.
        let start = sampler.sample(at: 0)[0]?.rotation
        XCTAssertNotNil(start)
        XCTAssertEqual(start!.angle, 0, accuracy: 1e-4)

        // At t=1: 90° about Y.
        let end = sampler.sample(at: 1)[0]?.rotation
        XCTAssertEqual(end!.angle, Float.pi / 2, accuracy: 1e-3)
        XCTAssertEqual(abs(end!.axis.y), 1, accuracy: 1e-3)

        // At t=0.5: slerp → 45° about Y.
        let mid = sampler.sample(at: 0.5)[0]?.rotation
        XCTAssertEqual(mid!.angle, Float.pi / 4, accuracy: 1e-3)
        XCTAssertEqual(abs(mid!.axis.y), 1, accuracy: 1e-3)
    }

    func testParsesWhenSpecVersionMissing() throws {
        // Some exporters omit specVersion; parsing must still succeed.
        var glb = makeVRMA()
        // Rebuild without specVersion in the extension.
        let s = Float(sin(Double.pi / 4)); let c = Float(cos(Double.pi / 4))
        let floats: [Float] = [0, 1, 0, 0, 0, 1, 0, s, 0, c]
        var bin = Data()
        for f in floats { withUnsafeBytes(of: f.bitPattern.littleEndian) { bin.append(contentsOf: $0) } }
        let json: [String: Any] = [
            "asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": [0]]],
            "nodes": [["name": "hips"]], "buffers": [["byteLength": bin.count]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": 8],
                            ["buffer": 0, "byteOffset": 8, "byteLength": 32]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR"],
                          ["bufferView": 1, "componentType": 5126, "count": 2, "type": "VEC4"]],
            "animations": [["channels": [["sampler": 0, "target": ["node": 0, "path": "rotation"]]],
                           "samplers": [["input": 0, "output": 1, "interpolation": "LINEAR"]]]],
            "extensions": ["VRMC_vrm_animation": ["humanoid": ["humanBones": ["hips": ["node": 0]]]]],
        ]
        glb = Self.makeGLB(json: json, bin: bin)
        let animation = try VRMAnimation(data: glb)
        XCTAssertEqual(animation.specVersion, "1.0") // default
        XCTAssertEqual(animation.humanoidBoneNodeMap["hips"], 0)
    }

    func testSampleClampsOutsideRange() throws {
        let animation = try VRMAnimation(data: makeVRMA())
        let sampler = try VRMAnimationSampler(animation: animation.clips[0], gltf: animation.gltf)
        // Before start clamps to first keyframe, after end clamps to last.
        XCTAssertEqual(sampler.sample(at: -1)[0]?.rotation?.angle ?? -1, 0, accuracy: 1e-4)
        XCTAssertEqual(sampler.sample(at: 5)[0]?.rotation?.angle ?? -1, Float.pi / 2, accuracy: 1e-3)
    }
}
