import Foundation

// VRM Animation (`.vrma`) extension: maps the file's glTF nodes to humanoid bones,
// expressions and look-at, so the glTF animations can be retargeted onto an avatar.
// https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm_animation-1.0/README.md

public struct VRMCVRMAnimation: Codable {
    public let specVersion: String? // some exporters omit it
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
