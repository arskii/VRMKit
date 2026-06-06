#if canImport(RealityKit)
import Foundation
import RealityKit
import simd
import VRMKit
import VRMKitRuntime

/// Plays a VRM Animation (`.vrma`) clip on a loaded ``VRMEntity`` by retargeting
/// the clip's humanoid bones onto the avatar's humanoid skeleton.
///
/// Usage:
/// ```swift
/// let vrm = try VRMLoader().load(named: "avatar.vrm")
/// let entity = try VRMEntityLoader(vrm: vrm).loadEntity()
///
/// let animation = try VRMAnimation(data: vrmaData)
/// let player = try VRMAnimationPlayer(animation: animation, target: entity)
/// player.play()
///
/// // From your render loop (e.g. RealityView's SceneEvents.Update):
/// player.update(deltaTime: event.deltaTime)
/// ```
///
/// ## Retargeting model
/// The clip stores, per humanoid bone, a *local* rotation track. Since VRM
/// humanoid bones share a canonical orientation, the motion is applied as the
/// delta from the source rest pose onto the target rest pose:
///
///     target.localRotation = targetRestLocal * (sourceRestLocal⁻¹ * sampledLocal)
///
/// The hips translation is normalized by the ratio of the avatar's hips height
/// to the clip's hips height so motion scales across differently-sized models.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public final class VRMAnimationPlayer {
    public let animation: VRMAnimation
    private weak var target: VRMEntity?
    private let sampler: VRMAnimationSampler

    /// Whether playback loops back to the start when reaching the end.
    public var isLooping: Bool = true
    /// Playback speed multiplier (1.0 = real time).
    public var speed: Double = 1.0
    /// Whether the clip is currently advancing.
    public private(set) var isPlaying: Bool = false
    /// Current playback head in seconds.
    public private(set) var time: TimeInterval = 0
    /// Clip length in seconds.
    public var duration: TimeInterval { sampler.duration }

    private struct BoneBinding {
        let sourceNode: Int
        let targetEntity: Entity
        let targetRestLocalRotation: simd_quatf
        let sourceRestLocalRotationInverse: simd_quatf
    }

    private var boneBindings: [BoneBinding] = []

    private var hipsEntity: Entity?
    private var hipsSourceNode: Int?
    private var hipsTargetRestTranslation: SIMD3<Float> = .zero
    private var hipsSourceRestTranslation: SIMD3<Float> = .zero
    private var hipsHeightScale: Float = 1

    public init(animation: VRMAnimation, target: VRMEntity) throws {
        self.animation = animation
        self.target = target

        let clip = try animation.clips.first ??? VRMError._dataInconsistent("vrma contains no animation clip")
        self.sampler = try VRMAnimationSampler(animation: clip, gltf: animation.gltf)

        buildBindings(target: target)
    }

    // MARK: - Transport

    public func play() { isPlaying = true }
    public func pause() { isPlaying = false }

    /// Stops playback and restores the avatar's rest pose.
    public func stop() {
        isPlaying = false
        time = 0
        restorePose()
    }

    /// Moves the playback head to `time` (clamped to the clip range) and applies it.
    public func seek(to time: TimeInterval) {
        self.time = min(max(0, time), duration)
        applyPose(at: self.time)
    }

    /// Advances playback by `deltaTime` seconds and pushes the new pose to the avatar.
    ///
    /// Call once per frame. This also drives the avatar's skinning / spring bones
    /// via ``VRMEntity/update(at:)``.
    public func update(deltaTime: TimeInterval) {
        guard let target else { return }
        if isPlaying {
            advance(by: deltaTime * speed)
            applyPose(at: time)
        }
        target.update(at: deltaTime)
    }

    private func advance(by delta: TimeInterval) {
        guard duration > 0 else { time = 0; return }
        var t = time + delta
        if t > duration {
            if isLooping {
                t = t.truncatingRemainder(dividingBy: duration)
                if t < 0 { t += duration }
            } else {
                t = duration
                isPlaying = false
            }
        } else if t < 0 {
            t = isLooping ? t.truncatingRemainder(dividingBy: duration) + duration : 0
        }
        time = t
    }

    // MARK: - Setup

    private func buildBindings(target: VRMEntity) {
        let sourceNodes = animation.gltf.jsonData.nodes ?? []
        let sourceWorld = sourceWorldTranslations()

        for (boneName, sourceNode) in animation.humanoidBoneNodeMap {
            guard let bone = Humanoid.Bones(rawValue: boneName),
                  let targetEntity = target.humanoid.node(for: bone),
                  sourceNodes.indices.contains(sourceNode) else { continue }

            let sourceRest = sourceNodes[sourceNode].rotation.simdQuat
            let binding = BoneBinding(sourceNode: sourceNode,
                                      targetEntity: targetEntity,
                                      targetRestLocalRotation: targetEntity.transform.rotation,
                                      sourceRestLocalRotationInverse: sourceRest.inverse)
            boneBindings.append(binding)

            if bone == .hips {
                hipsEntity = targetEntity
                hipsSourceNode = sourceNode
                hipsTargetRestTranslation = targetEntity.transform.translation
                hipsSourceRestTranslation = sourceNodes[sourceNode].translation.simd
                let targetHipsWorldY = targetEntity.position(relativeTo: nil).y
                let sourceHipsWorldY = sourceWorld[sourceNode]?.y ?? hipsSourceRestTranslation.y
                if abs(sourceHipsWorldY) > 1e-5 {
                    hipsHeightScale = targetHipsWorldY / sourceHipsWorldY
                }
            }
        }
    }

    /// Rest-pose world translations of the clip's nodes (walking the glTF hierarchy).
    private func sourceWorldTranslations() -> [Int: SIMD3<Float>] {
        let nodes = animation.gltf.jsonData.nodes ?? []
        guard !nodes.isEmpty else { return [:] }

        var worldMatrices: [Int: simd_float4x4] = [:]
        let gltf = animation.gltf.jsonData
        let roots: [Int]
        if let scene = gltf.scenes?[safe: gltf.scene], let sceneNodes = scene.nodes {
            roots = sceneNodes
        } else {
            roots = Array(0..<nodes.count)
        }

        func visit(_ index: Int, parent: simd_float4x4) {
            guard nodes.indices.contains(index) else { return }
            let node = nodes[index]
            let local: simd_float4x4
            if let matrix = node._matrix {
                local = matrix.simdMatrix
            } else {
                local = Transform(scale: node.scale.simd,
                                  rotation: node.rotation.simdQuat,
                                  translation: node.translation.simd).matrix
            }
            let world = parent * local
            worldMatrices[index] = world
            for child in node.children ?? [] {
                visit(child, parent: world)
            }
        }

        for root in roots {
            visit(root, parent: matrix_identity_float4x4)
        }

        return worldMatrices.mapValues { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
    }

    // MARK: - Pose application

    private func applyPose(at time: TimeInterval) {
        let sample = sampler.sample(at: time)

        for binding in boneBindings {
            guard let nodeTransform = sample[binding.sourceNode],
                  let rotation = nodeTransform.rotation else { continue }
            let delta = binding.sourceRestLocalRotationInverse * rotation
            binding.targetEntity.transform.rotation = binding.targetRestLocalRotation * delta
        }

        if let hipsEntity, let hipsSourceNode,
           let translation = sample[hipsSourceNode]?.translation {
            let offset = (translation - hipsSourceRestTranslation) * hipsHeightScale
            hipsEntity.transform.translation = hipsTargetRestTranslation + offset
        }
    }

    private func restorePose() {
        for binding in boneBindings {
            binding.targetEntity.transform.rotation = binding.targetRestLocalRotation
        }
        hipsEntity?.transform.translation = hipsTargetRestTranslation
        target?.update(at: 0)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
