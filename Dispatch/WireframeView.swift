import SwiftUI
import SceneKit

struct WireframeView: UIViewRepresentable {
    var isPulsing: Bool
    var isDictating: Bool

    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.backgroundColor = .black
        sceneView.antialiasingMode = .multisampling4X
        sceneView.isUserInteractionEnabled = false

        let scene = SCNScene()
        sceneView.scene = scene

        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 4.2)
        scene.rootNode.addChildNode(cameraNode)

        // Build icosahedron wireframe
        let polyhedronNode = buildIcosahedron()
        polyhedronNode.name = "polyhedron"
        scene.rootNode.addChildNode(polyhedronNode)

        // Slow continuous rotation
        let rotateAction = SCNAction.repeatForever(
            SCNAction.rotateBy(
                x: CGFloat.pi * 2 * 0.07,
                y: CGFloat.pi * 2 * 0.13,
                z: CGFloat.pi * 2 * 0.03,
                duration: 10.0
            )
        )
        polyhedronNode.runAction(rotateAction, forKey: "rotate")

        // Ambient light (subtle)
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.color = UIColor(white: 0.15, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        return sceneView
    }

    func updateUIView(_ sceneView: SCNView, context: Context) {
        guard let polyhedron = sceneView.scene?.rootNode.childNode(
            withName: "polyhedron", recursively: false
        ) else { return }

        // Pulse effect
        if isPulsing {
            let scaleUp = SCNAction.scale(to: 1.15, duration: 0.1)
            let scaleDown = SCNAction.scale(to: 1.0, duration: 0.4)
            scaleDown.timingMode = .easeOut
            polyhedron.runAction(SCNAction.sequence([scaleUp, scaleDown]), forKey: "pulse")
        }

        // Dictation color shift
        let targetColor: UIColor = isDictating
            ? UIColor(white: 0.95, alpha: 1.0)
            : UIColor(white: 0.7, alpha: 1.0)

        polyhedron.enumerateChildNodes { node, _ in
            if let geo = node.geometry {
                for material in geo.materials {
                    if material.name == "wireEdge" {
                        SCNTransaction.begin()
                        SCNTransaction.animationDuration = 0.3
                        material.diffuse.contents = targetColor
                        material.emission.contents = isDictating
                            ? UIColor(white: 0.4, alpha: 1.0)
                            : UIColor(white: 0.1, alpha: 1.0)
                        SCNTransaction.commit()
                    } else if material.name == "face" {
                        SCNTransaction.begin()
                        SCNTransaction.animationDuration = 0.3
                        material.diffuse.contents = isDictating
                            ? UIColor(white: 1.0, alpha: 0.06)
                            : UIColor(white: 1.0, alpha: 0.03)
                        SCNTransaction.commit()
                    }
                }
            }
        }
    }

    // MARK: - Icosahedron Construction

    private func buildIcosahedron() -> SCNNode {
        let containerNode = SCNNode()

        let phi: Float = (1.0 + sqrt(5.0)) / 2.0
        let scale: Float = 0.85

        // 12 vertices of a regular icosahedron
        let vertices: [SCNVector3] = [
            SCNVector3(-1,  phi, 0), SCNVector3( 1,  phi, 0),
            SCNVector3(-1, -phi, 0), SCNVector3( 1, -phi, 0),
            SCNVector3(0, -1,  phi), SCNVector3(0,  1,  phi),
            SCNVector3(0, -1, -phi), SCNVector3(0,  1, -phi),
            SCNVector3( phi, 0, -1), SCNVector3( phi, 0,  1),
            SCNVector3(-phi, 0, -1), SCNVector3(-phi, 0,  1),
        ].map { SCNVector3($0.x * scale, $0.y * scale, $0.z * scale) }

        // 20 triangular faces
        let faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]

        // Semi-transparent face geometry
        let faceNode = buildFaces(vertices: vertices, faces: faces)
        containerNode.addChildNode(faceNode)

        // Wireframe edges
        let edgeSet = buildEdgeSet(faces: faces)
        for (a, b) in edgeSet {
            let edgeNode = buildEdge(from: vertices[a], to: vertices[b])
            containerNode.addChildNode(edgeNode)
        }

        // Small spheres at vertices
        for v in vertices {
            let sphere = SCNSphere(radius: 0.03)
            let mat = SCNMaterial()
            mat.name = "wireEdge"
            mat.diffuse.contents = UIColor(white: 0.7, alpha: 1.0)
            mat.emission.contents = UIColor(white: 0.1, alpha: 1.0)
            mat.lightingModel = .constant
            sphere.materials = [mat]
            let node = SCNNode(geometry: sphere)
            node.position = v
            containerNode.addChildNode(node)
        }

        return containerNode
    }

    private func buildFaces(vertices: [SCNVector3], faces: [(Int, Int, Int)]) -> SCNNode {
        var allVertices: [SCNVector3] = []
        var indices: [Int32] = []

        for (i, face) in faces.enumerated() {
            allVertices.append(vertices[face.0])
            allVertices.append(vertices[face.1])
            allVertices.append(vertices[face.2])
            let base = Int32(i * 3)
            indices.append(contentsOf: [base, base + 1, base + 2])
        }

        let vertexSource = SCNGeometrySource(vertices: allVertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])

        let faceMat = SCNMaterial()
        faceMat.name = "face"
        faceMat.diffuse.contents = UIColor(white: 1.0, alpha: 0.03)
        faceMat.lightingModel = .constant
        faceMat.isDoubleSided = true
        faceMat.blendMode = .add
        faceMat.writesToDepthBuffer = false
        geometry.materials = [faceMat]

        return SCNNode(geometry: geometry)
    }

    private func buildEdgeSet(faces: [(Int, Int, Int)]) -> [(Int, Int)] {
        var edgeDict: [String: (Int, Int)] = [:]
        for face in faces {
            let edges = [(face.0, face.1), (face.1, face.2), (face.2, face.0)]
            for (a, b) in edges {
                let key = "\(min(a, b))-\(max(a, b))"
                edgeDict[key] = (min(a, b), max(a, b))
            }
        }
        return Array(edgeDict.values)
    }

    private func buildEdge(from start: SCNVector3, to end: SCNVector3) -> SCNNode {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dz = end.z - start.z
        let distance = sqrt(dx * dx + dy * dy + dz * dz)

        let cylinder = SCNCylinder(radius: 0.012, height: CGFloat(distance))
        let mat = SCNMaterial()
        mat.name = "wireEdge"
        mat.diffuse.contents = UIColor(white: 0.7, alpha: 1.0)
        mat.emission.contents = UIColor(white: 0.1, alpha: 1.0)
        mat.lightingModel = .constant
        cylinder.materials = [mat]

        let node = SCNNode(geometry: cylinder)

        // Position at midpoint
        node.position = SCNVector3(
            (start.x + end.x) / 2,
            (start.y + end.y) / 2,
            (start.z + end.z) / 2
        )

        // Orient along the edge direction
        let up = SCNVector3(0, 1, 0)
        let dir = SCNVector3(dx, dy, dz)
        let cross = SCNVector3(
            up.y * dir.z - up.z * dir.y,
            up.z * dir.x - up.x * dir.z,
            up.x * dir.y - up.y * dir.x
        )
        let crossLen = sqrt(cross.x * cross.x + cross.y * cross.y + cross.z * cross.z)
        let dot = up.x * dir.x + up.y * dir.y + up.z * dir.z

        if crossLen > 0.0001 {
            let angle = atan2(crossLen, dot)
            let axis = SCNVector3(cross.x / crossLen, cross.y / crossLen, cross.z / crossLen)
            node.rotation = SCNVector4(axis.x, axis.y, axis.z, angle)
        } else if dot < 0 {
            node.rotation = SCNVector4(1, 0, 0, Float.pi)
        }

        return node
    }
}
