import Foundation

/// A parsed VRM Animation (`.vrma`) file.
///
/// `.vrma` is a glTF / GLB container carrying the `VRMC_vrm_animation` extension.
/// This type exposes the underlying glTF data, the humanoid-bone → node mapping
/// and a ready-to-use sampler over the glTF animation clips so a renderer can
/// retarget the motion onto a VRM avatar.
public struct VRMAnimation {
    /// The underlying binary glTF container.
    public let gltf: BinaryGLTF
    /// `specVersion` declared by the `VRMC_vrm_animation` extension (e.g. `"1.0"`).
    public let specVersion: String
    /// The decoded `VRMC_vrm_animation` extension.
    public let vrmAnimation: VRMCVRMAnimation

    /// Maps a VRM humanoid bone name (e.g. `"hips"`, `"leftUpperArm"`) to the glTF
    /// node index that the animation clips drive.
    public let humanoidBoneNodeMap: [String: Int]

    /// Loads a `.vrma` bundled by `name` (with or without the `.vrma` extension).
    public init(named name: String, in bundle: Bundle = .main) throws {
        let url = bundle.url(forResource: name, withExtension: nil)
            ?? bundle.url(forResource: name, withExtension: "vrma")
        guard let url else { throw URLError(.fileDoesNotExist) }
        try self.init(withURL: url)
    }

    /// Loads a `.vrma` from a file URL.
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
        self.specVersion = vrmAnimation.specVersion

        self.humanoidBoneNodeMap = vrmAnimation.humanoid?.humanBones
            .reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value.node
            } ?? [:]
    }

    /// The glTF animation clips contained in the file (usually a single clip).
    public var clips: [GLTF.Animation] {
        gltf.jsonData.animations ?? []
    }
}
