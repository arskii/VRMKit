import Foundation

/// A parsed VRM Animation (`.vrma`) file: a glTF / GLB container carrying the
/// `VRMC_vrm_animation` extension.
public struct VRMAnimation {
    public let gltf: BinaryGLTF
    public let specVersion: String
    public let vrmAnimation: VRMCVRMAnimation

    /// VRM humanoid bone name (e.g. `"hips"`) → glTF node index driven by the clips.
    public let humanoidBoneNodeMap: [String: Int]

    /// Loads a `.vrma` bundled by `name` (with or without the `.vrma` extension).
    public init(named name: String, in bundle: Bundle = .main) throws {
        let url = bundle.url(forResource: name, withExtension: nil)
            ?? bundle.url(forResource: name, withExtension: "vrma")
        guard let url else { throw URLError(.fileDoesNotExist) }
        try self.init(withURL: url)
    }

    public init(withURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    public init(data: Data) throws {
        let gltf = try BinaryGLTF(data: data)
        self.gltf = gltf

        let rawExtensions = try gltf.jsonData.extensions ??? .keyNotFound("extensions")
        let extensions = try rawExtensions.value as? [String: [String: Any]] ??? .dataInconsistent("extension type mismatch")
        let raw = try extensions["VRMC_vrm_animation"] ??? .keyNotFound("VRMC_vrm_animation")

        let decoder = DictionaryDecoder()
        let vrmAnimation = try decoder.decode(VRMCVRMAnimation.self, from: raw)
        self.vrmAnimation = vrmAnimation
        self.specVersion = vrmAnimation.specVersion ?? "1.0"

        self.humanoidBoneNodeMap = vrmAnimation.humanoid?.humanBones
            .reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value.node
            } ?? [:]
    }

    public var clips: [GLTF.Animation] {
        gltf.jsonData.animations ?? []
    }
}
