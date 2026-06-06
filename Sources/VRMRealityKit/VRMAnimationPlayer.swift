#if canImport(RealityKit)
import CoreGraphics
import Foundation
import RealityKit
import simd
import VRMKit
import VRMKitRuntime

/// Plays a VRM Animation (`.vrma`) clip on a loaded `VRMEntity`, retargeting the
/// clip's humanoid bones, expressions and look-at onto the avatar. Call
/// `update(deltaTime:)` once per frame (e.g. from `SceneEvents.Update`).
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public final class VRMAnimationPlayer {
    public private(set) var animation: VRMAnimation
    private weak var target: VRMEntity?
    private let rootEntity: Entity
    private var sampler: VRMAnimationSampler

    public var isLooping: Bool = true
    public var speed: Double = 1.0
    public private(set) var isPlaying: Bool = false
    public private(set) var time: TimeInterval = 0
    public var duration: TimeInterval { sampler.duration }

    private struct BoneBinding {
        let sourceNode: Int
        let targetEntity: Entity
        let targetRestLocalRotation: simd_quatf  // local, for restoring
        let targetRestWorldRotation: simd_quatf  // relative to the avatar root
        let depth: Int                           // entity depth, for parent-first ordering
    }

    private var boneBindings: [BoneBinding] = []

    // Clip-side rest data (per glTF node), all relative to the clip root.
    private var sourceParent: [Int] = []
    private var sourceRestLocalRotation: [simd_quatf] = []
    private var sourceRestWorldRotation: [simd_quatf] = []
    private var sourceTopoOrder: [Int] = []

    private let flipY: Bool
    private let yFlip = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)) // its own inverse
    private let identityQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    // Hips translation.
    private var hipsEntity: Entity?
    private var hipsSourceNode: Int?
    private var hipsTargetRestTranslation: SIMD3<Float> = .zero
    private var hipsSourceRestTranslation: SIMD3<Float> = .zero
    private var hipsHeightScale: Float = 1

    // Expressions and look-at.
    private struct ExpressionBinding {
        let sourceNode: Int
        let key: BlendShapeKey
    }
    private var expressionBindings: [ExpressionBinding] = []
    private var lookAtNode: Int?
    private var eyeBones: [(entity: Entity, restLocalRotation: simd_quatf)] = []

    public init(animation: VRMAnimation, target: VRMEntity) throws {
        self.animation = animation
        self.target = target
        self.rootEntity = target.entity

        switch target.vrm {
        case .v0: self.flipY = true
        case .v1: self.flipY = false
        }

        let clip = try animation.clips.first ??? VRMError._dataInconsistent("vrma contains no animation clip")
        self.sampler = try VRMAnimationSampler(animation: clip, gltf: animation.gltf)
        rebuild()
    }

    // MARK: - Transport

    public func play() { isPlaying = true }
    public func pause() { isPlaying = false }

    /// Switches to a different `.vrma` clip on the same avatar, restoring the
    /// rest pose first so retargeting stays correct. Preserves the play state.
    public func setAnimation(_ animation: VRMAnimation) throws {
        let wasPlaying = isPlaying
        isPlaying = false
        restorePose()
        clearBindings()

        self.animation = animation
        let clip = try animation.clips.first ??? VRMError._dataInconsistent("vrma contains no animation clip")
        self.sampler = try VRMAnimationSampler(animation: clip, gltf: animation.gltf)
        rebuild()

        time = 0
        isPlaying = wasPlaying
    }

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

    /// Advances playback by `deltaTime` and pushes the new pose to the avatar,
    /// also driving its skinning and spring bones.
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

    private func rebuild() {
        precomputeSource()
        guard let target else { return }
        buildBindings(target: target)
        buildExpressionsAndLookAt(target: target)
    }

    private func clearBindings() {
        boneBindings.removeAll()
        expressionBindings.removeAll()
        eyeBones.removeAll()
        hipsEntity = nil
        hipsSourceNode = nil
        hipsHeightScale = 1
    }

    /// Precomputes the clip's node hierarchy, rest local/world rotations and a
    /// root-to-leaf traversal order.
    private func precomputeSource() {
        let nodes = animation.gltf.jsonData.nodes ?? []
        let count = nodes.count
        sourceParent = Array(repeating: -1, count: count)
        sourceRestLocalRotation = nodes.map { Self.localRotation(of: $0) }
        sourceRestWorldRotation = Array(repeating: identityQuat, count: count)

        for (index, node) in nodes.enumerated() {
            for child in node.children ?? [] where nodes.indices.contains(child) {
                sourceParent[child] = index
            }
        }

        // Root-to-leaf order via DFS from scene roots (fallback: all nodes).
        let gltf = animation.gltf.jsonData
        let roots: [Int]
        if let scene = gltf.scenes?[safe: gltf.scene], let sceneNodes = scene.nodes {
            roots = sceneNodes
        } else {
            roots = (0..<count).filter { sourceParent[$0] == -1 }
        }
        var order: [Int] = []
        order.reserveCapacity(count)
        var stack = roots.reversed().map { $0 }
        var visited = Set<Int>()
        while let node = stack.popLast() {
            guard nodes.indices.contains(node), visited.insert(node).inserted else { continue }
            order.append(node)
            for child in (nodes[node].children ?? []).reversed() { stack.append(child) }
        }
        sourceTopoOrder = order

        for node in order {
            let parent = sourceParent[node]
            sourceRestWorldRotation[node] = parent >= 0
                ? simd_mul(sourceRestWorldRotation[parent], sourceRestLocalRotation[node])
                : sourceRestLocalRotation[node]
        }
    }

    private func buildBindings(target: VRMEntity) {
        let sourceNodes = animation.gltf.jsonData.nodes ?? []
        let sourceWorldPositions = sourceRestWorldPositions()

        for (boneName, sourceNode) in animation.humanoidBoneNodeMap {
            guard let bone = Humanoid.Bones(rawValue: boneName),
                  let targetEntity = target.humanoid.node(for: bone),
                  sourceNodes.indices.contains(sourceNode) else { continue }

            let binding = BoneBinding(
                sourceNode: sourceNode,
                targetEntity: targetEntity,
                targetRestLocalRotation: targetEntity.orientation,
                targetRestWorldRotation: targetEntity.orientation(relativeTo: rootEntity),
                depth: depth(of: targetEntity)
            )
            boneBindings.append(binding)

            if bone == .hips {
                hipsEntity = targetEntity
                hipsSourceNode = sourceNode
                hipsTargetRestTranslation = targetEntity.transform.translation
                hipsSourceRestTranslation = sourceNodes[sourceNode].translation.simd
                let targetHipsWorldY = targetEntity.position(relativeTo: rootEntity).y
                let sourceHipsWorldY = sourceWorldPositions[sourceNode]?.y ?? hipsSourceRestTranslation.y
                if abs(sourceHipsWorldY) > 1e-5 {
                    hipsHeightScale = targetHipsWorldY / sourceHipsWorldY
                }
            }
        }

        // Apply parents before children so parent world rotations are up to date.
        boneBindings.sort { $0.depth < $1.depth }
    }

    private func buildExpressionsAndLookAt(target: VRMEntity) {
        if let expressions = animation.vrmAnimation.expressions {
            for (name, expression) in expressions.preset ?? [:] {
                expressionBindings.append(ExpressionBinding(sourceNode: expression.node,
                                                            key: Self.blendShapeKey(forExpression: name)))
            }
            for (name, expression) in expressions.custom ?? [:] {
                expressionBindings.append(ExpressionBinding(sourceNode: expression.node, key: .custom(name)))
            }
        }

        lookAtNode = animation.vrmAnimation.lookAt?.node
        for bone in [Humanoid.Bones.leftEye, .rightEye] {
            if let eye = target.humanoid.node(for: bone) {
                eyeBones.append((eye, eye.orientation))
            }
        }
    }

    /// Maps a VRM 1.0 expression name to the avatar's blend-shape key (which uses
    /// VRM 0.x preset naming after migration).
    private static func blendShapeKey(forExpression name: String) -> BlendShapeKey {
        let preset: BlendShapePreset
        switch name {
        case "happy": preset = .joy
        case "angry": preset = .angry
        case "sad": preset = .sorrow
        case "relaxed": preset = .fun
        case "aa": preset = .a
        case "ih": preset = .i
        case "ou": preset = .u
        case "ee": preset = .e
        case "oh": preset = .o
        case "blink": preset = .blink
        case "blinkLeft": preset = .blinkL
        case "blinkRight": preset = .blinkR
        case "lookUp": preset = .lookUp
        case "lookDown": preset = .lookDown
        case "lookLeft": preset = .lookLeft
        case "lookRight": preset = .lookRight
        case "neutral": preset = .neutral
        default: return .custom(name) // e.g. "surprised" (no VRM 0.x equivalent)
        }
        return .preset(preset)
    }

    private func depth(of entity: Entity) -> Int {
        var d = 0
        var current: Entity? = entity
        while let node = current, node !== rootEntity {
            d += 1
            current = node.parent
        }
        return d
    }

    /// Rest-pose world positions of the clip's nodes (relative to the clip root).
    private func sourceRestWorldPositions() -> [Int: SIMD3<Float>] {
        let nodes = animation.gltf.jsonData.nodes ?? []
        guard !nodes.isEmpty else { return [:] }
        var worldMatrices = [Int: simd_float4x4]()
        for node in sourceTopoOrder {
            let gltfNode = nodes[node]
            let local: simd_float4x4
            if let matrix = gltfNode._matrix {
                local = matrix.simdMatrix
            } else {
                local = Transform(scale: gltfNode.scale.simd,
                                  rotation: gltfNode.rotation.simdQuat,
                                  translation: gltfNode.translation.simd).matrix
            }
            let parent = sourceParent[node]
            let parentMatrix = parent >= 0 ? (worldMatrices[parent] ?? matrix_identity_float4x4) : matrix_identity_float4x4
            worldMatrices[node] = parentMatrix * local
        }
        return worldMatrices.mapValues { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
    }

    private static func localRotation(of node: GLTF.Node) -> simd_quatf {
        if let matrix = node._matrix {
            return Transform(matrix: matrix.simdMatrix).rotation
        }
        return node.rotation.simdQuat
    }

    // MARK: - Pose application

    private func applyPose(at time: TimeInterval) {
        let sample = sampler.sample(at: time)

        // 1. Accumulate the clip's animated world rotations (root → leaf).
        var worldRot = sourceRestWorldRotation
        for node in sourceTopoOrder {
            let local = sample[node]?.rotation ?? sourceRestLocalRotation[node]
            let parent = sourceParent[node]
            worldRot[node] = parent >= 0 ? simd_mul(worldRot[parent], local) : local
        }

        // 2. Apply each bone's world-space delta onto the avatar (parents first).
        for binding in boneBindings {
            let animWorld = worldRot[binding.sourceNode]
            var delta = simd_mul(animWorld, sourceRestWorldRotation[binding.sourceNode].inverse)
            if flipY {
                delta = simd_mul(simd_mul(yFlip, delta), yFlip)
            }
            let desiredWorld = simd_mul(delta, binding.targetRestWorldRotation)
            let parentWorld = binding.targetEntity.parent?.orientation(relativeTo: rootEntity) ?? identityQuat
            binding.targetEntity.orientation = simd_mul(parentWorld.inverse, desiredWorld)
        }

        // 3. Hips translation (normalized by height ratio).
        if let hipsEntity, let hipsSourceNode,
           let translation = sample[hipsSourceNode]?.translation {
            var offset = (translation - hipsSourceRestTranslation) * hipsHeightScale
            if flipY { offset.x = -offset.x; offset.z = -offset.z }
            hipsEntity.transform.translation = hipsTargetRestTranslation + offset
        }

        // 4. Expressions: the X component of the node's translation is the weight.
        for binding in expressionBindings {
            guard let weight = sample[binding.sourceNode]?.translation?.x else { continue }
            target?.setBlendShape(value: CGFloat(max(0, min(1, weight))), for: binding.key)
        }

        // 5. Look-at: the node's local rotation is the eye gaze direction.
        if let lookAtNode, !eyeBones.isEmpty, var gaze = sample[lookAtNode]?.rotation {
            if flipY { gaze = simd_mul(simd_mul(yFlip, gaze), yFlip) }
            for eye in eyeBones {
                eye.entity.orientation = simd_mul(eye.restLocalRotation, gaze)
            }
        }
    }

    private func restorePose() {
        for binding in boneBindings {
            binding.targetEntity.orientation = binding.targetRestLocalRotation
        }
        for eye in eyeBones {
            eye.entity.orientation = eye.restLocalRotation
        }
        for binding in expressionBindings {
            target?.setBlendShape(value: 0, for: binding.key)
        }
        hipsEntity?.transform.translation = hipsTargetRestTranslation
        target?.update(at: 0)
    }
}
#endif
