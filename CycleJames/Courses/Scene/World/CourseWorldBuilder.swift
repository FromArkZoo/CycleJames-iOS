import SceneKit
import UIKit

/// Builds the 3D environment for a course.
///
/// PLACEHOLDER: a plain terrain grid, a flat road ribbon, a sky colour and a
/// sun, so the rider, camera and HUD can be developed against something real.
/// The full world (carved LiDAR terrain, cobbles, verges, trees, buildings,
/// sky, post-processing) replaces this file; keep the `build` signature.
enum CourseWorldBuilder {
    static func build(
        bundle: CourseBundle,
        quality: GraphicsQuality,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> CourseWorld {
        progress(0.1, "Shaping the hills")
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.62, green: 0.76, blue: 0.92, alpha: 1)
        scene.fogStartDistance = 150
        scene.fogEndDistance = 900
        scene.fogColor = UIColor(red: 0.74, green: 0.82, blue: 0.9, alpha: 1)

        let terrain = SCNNode(geometry: terrainGeometry(bundle.terrainNear, step: 2))
        terrain.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.33, green: 0.45, blue: 0.22, alpha: 1)
        terrain.geometry?.firstMaterial?.lightingModel = .lambert
        scene.rootNode.addChildNode(terrain)

        progress(0.6, "Laying the cobbles")
        let road = SCNNode(geometry: roadGeometry(bundle.route))
        road.geometry?.firstMaterial?.diffuse.contents = UIColor(white: 0.42, alpha: 1)
        road.geometry?.firstMaterial?.lightingModel = .lambert
        scene.rootNode.addChildNode(road)

        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.intensity = 1000
        sunLight.castsShadow = true
        let sun = SCNNode()
        sun.light = sunLight
        sun.eulerAngles = SCNVector3(-0.8, 0.6, 0)
        scene.rootNode.addChildNode(sun)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)

        let dynamicRoot = SCNNode()
        dynamicRoot.name = "dynamic"
        scene.rootNode.addChildNode(dynamicRoot)

        progress(1, "Ready")
        return CourseWorld(
            scene: scene,
            bundle: bundle,
            quality: quality,
            dynamicRoot: dynamicRoot,
            sun: sun,
            preferredFramesPerSecond: quality == .battery ? 30 : 60,
            configureCamera: { camera in
                camera.zNear = 0.05
                camera.zFar = 4000
            }
        )
    }

    private static func terrainGeometry(_ r: HeightRaster, step: Int) -> SCNGeometry {
        let cols = (r.cols - 1) / step + 1
        let rows = (r.rows - 1) / step + 1
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(cols * rows)
        for gr in 0..<rows {
            for gc in 0..<cols {
                let row = gr * step, col = gc * step
                var h = r.value(row: row, col: col)
                if h.isNaN { h = 0 }
                let east = r.originEast + (Double(col) + 0.5) * r.cellM
                let north = r.originNorth - (Double(row) + 0.5) * r.cellM
                let p = CourseSpace.scene(east: east, north: north, elev: Double(h))
                vertices.append(SCNVector3(p.x, p.y, p.z))
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity((cols - 1) * (rows - 1) * 6)
        for gr in 0..<(rows - 1) {
            for gc in 0..<(cols - 1) {
                let a = UInt32(gr * cols + gc), b = a + 1
                let c = UInt32((gr + 1) * cols + gc), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        return meshGeometry(vertices: vertices, indices: indices)
    }

    private static func roadGeometry(_ route: CourseRoute) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        var d = 0.0
        while d <= route.length {
            let half = route.width(at: d) / 2
            for side in [-half, half] {
                var p = route.pose(at: d, lateral: side).position
                p.y += 0.06
                vertices.append(SCNVector3(p.x, p.y, p.z))
            }
            d += 1
        }
        let pairs = vertices.count / 2
        for i in 0..<(pairs - 1) {
            let l0 = UInt32(i * 2), r0 = l0 + 1, l1 = l0 + 2, r1 = l0 + 3
            indices += [l0, r0, l1, r0, r1, l1]
        }
        return meshGeometry(vertices: vertices, indices: indices)
    }

    /// Triangle mesh with smooth per-vertex normals.
    private static func meshGeometry(vertices: [SCNVector3], indices: [UInt32]) -> SCNGeometry {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let i0 = Int(indices[t]), i1 = Int(indices[t + 1]), i2 = Int(indices[t + 2])
            let p0 = SIMD3<Float>(vertices[i0]), p1 = SIMD3<Float>(vertices[i1]), p2 = SIMD3<Float>(vertices[i2])
            let n = simd_cross(p1 - p0, p2 - p0)
            normals[i0] += n; normals[i1] += n; normals[i2] += n
        }
        let normalVectors = normals.map { n -> SCNVector3 in
            let u = simd_length(n) > 0 ? simd_normalize(n) : SIMD3<Float>(0, 1, 0)
            return SCNVector3(u.x, u.y, u.z)
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normalVectors)],
            elements: [element]
        )
    }
}
