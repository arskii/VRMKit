import Foundation

// VRM Animation (`.vrma`) extension.
// https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm_animation-1.0/README.md
//
// A `.vrma` file is a regular glTF / GLB whose root `extensions` object contains
// `VRMC_vrm_animation`. The extension maps the file's glTF nodes to humanoid
// bones, expressions and look-at, so the glTF `animations` (which target those
// nodes) can be retargeted onto an arbitrary VRM avatar.

public struct VRMCVRMAnimation: Codable {
    public let specVersion: String
    public let humanoid: Humanoid?
    public let expressions: Expressions?
    public let lookAt: LookAt?

    public struct Humanoid: Codable {
        public let humanBones: [String: HumanBone]

        public struct HumanBone: Codable {
            public let node: Int
        }
    }

    public struct Expressions: Codable {
        public let preset: [String: Expression]?
        public let custom: [String: Expression]?

        public struct Expression: Codable {
            public let node: Int
        }
    }

    public struct LookAt: Codable {
        public let node: Int?
        public let offsetFromHeadBone: [Float]?
    }
}
