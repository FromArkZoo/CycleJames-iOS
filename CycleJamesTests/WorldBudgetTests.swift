import XCTest
import simd
import SceneKit
@testable import CycleJames

/// The Riviera's world budget (`WorldBudget.swift`): cutting a mesh into
/// tiles keeps every triangle exactly once, with every vertex channel and
/// its material part, on a grid shared by every mesh; a tile's far level
/// keeps only the parts asked for; the light-only plant clusters merge
/// without losing a triangle; the high tier builds the Riviera as the
/// constants it replaced did.
final class WorldBudgetTests: XCTestCase {
    /// A strip of quads 600 m long across x, in two parts, with every
    /// optional channel filled from the vertex's own position.
    private func strip() -> MeshBuffer {
        var m = MeshBuffer(parts: 2)
        for i in 0..<300 {
            let x0 = Float(i) * 2, x1 = x0 + 2
            let first = UInt32(m.vertexCount)
            for (x, z) in [(x0, 0), (x1, 0), (x1, -1.5), (x0, -1.5)] as [(Float, Float)] {
                m.vertex(x, 0.5, z, 0, 1, 0, x, z)
                m.texcoord2(x * 2, z * 2)
                m.texcoord3(x * 3, z * 3)
                m.texcoord4(x * 4, z * 4)
                m.color(x / 600, 0.5, 0.25, 1)
            }
            m.quad(first, first + 1, first + 2, first + 3, part: i % 3 == 0 ? 1 : 0)
        }
        return m
    }

    /// Each triangle as its three corners with all their channels, sorted,
    /// with its part: the same set whichever way the mesh is cut.
    private func triangleSet(_ m: MeshBuffer) -> [String] {
        var out: [String] = []
        for (k, part) in m.parts.enumerated() {
            for t in stride(from: 0, to: part.count, by: 3) {
                let corners = (0..<3).map { j -> String in
                    let v = Int(part[t + j])
                    let p = m.positions[(3 * v)..<(3 * v + 3)], uv = m.uvs[(2 * v)..<(2 * v + 2)]
                    let a = m.uv2[(2 * v)..<(2 * v + 2)], b = m.uv3[(2 * v)..<(2 * v + 2)]
                    let c = m.uv4[(2 * v)..<(2 * v + 2)], col = m.colors[(4 * v)..<(4 * v + 4)]
                    return "\(Array(p)) \(Array(uv)) \(Array(a)) \(Array(b)) \(Array(c)) \(Array(col))"
                }
                out.append("\(k): " + corners.sorted().joined(separator: " | "))
            }
        }
        return out.sorted()
    }

    func test_tilesKeepEveryTriangleOnceWithItsChannels() {
        let m = strip()
        let tiles = m.tiles(size: 192)
        // 600 m from x = 0 on a grid from the origin: 4 tiles.
        XCTAssertEqual(tiles.count, 4)
        var joined = MeshBuffer(parts: 2)
        for t in tiles {
            XCTAssertTrue(t.sameChannels(as: m))
            XCTAssertLessThan(t.vertexCount, m.vertexCount)
            joined.appendExactly(t)
        }
        XCTAssertEqual(joined.triangleCount, m.triangleCount)
        XCTAssertEqual(triangleSet(joined), triangleSet(m))
    }

    func test_tilesLineUpOnTheWorldGrid() {
        // The same strip moved 100 m: its tiles still break at x = 192, 384.
        var m = strip()
        m.translate(by: SIMD3(100, 0, 0))
        for t in m.tiles(size: 192) {
            var lo = Float.greatestFiniteMagnitude, hi = -lo
            for v in 0..<t.vertexCount { lo = min(lo, t.positions[3 * v]); hi = max(hi, t.positions[3 * v]) }
            let cell = ((lo + hi) / 2 / 192).rounded(.down)
            XCTAssertGreaterThanOrEqual(lo, cell * 192 - 2, "tile \(lo)...\(hi)")
            XCTAssertLessThanOrEqual(hi, (cell + 1) * 192 + 2, "tile \(lo)...\(hi)")
        }
    }

    func test_farLevelKeepsOnlyItsParts() {
        var m = strip()
        m.parts[0] = []
        let c = m.compacted()
        XCTAssertEqual(c.triangleCount, m.triangleCount)
        XCTAssertEqual(c.vertexCount, m.parts[1].count / 6 * 4)
        XCTAssertEqual(triangleSet(c), triangleSet(m))
        let nodes = WorldTiles.nodes(strip(), materials: [SCNMaterial(), SCNMaterial()], size: 192, hideBeyond: 500,
                                     keepBeyond: [1], casts: true)
        XCTAssertEqual(nodes.count, 4)
        for n in nodes {
            let far = n.geometry?.levelsOfDetail?.first
            XCTAssertEqual(far?.worldSpaceDistance, 500)
            XCTAssertEqual(far?.geometry?.elements.count, 1)
            XCTAssertEqual(n.geometry?.elements.count, 2)
        }
    }

    func test_lightClustersMergeWithoutLosingTriangles() {
        func cluster(_ x: Float, full: Bool) -> VegetationBuilder.Cluster {
            var c = VegetationBuilder.Cluster()
            var card = MeshBuffer(parts: 2)
            card.vertex(x, 0, 0, 0, 1, 0, 0, 0); card.vertex(x + 1, 0, 0, 0, 1, 0, 1, 0); card.vertex(x, 1, 0, 0, 1, 0, 0, 1)
            card.tri(0, 1, 2, part: 1)
            c.light = card
            c.impostor = card
            if full { c.full = card }
            return c
        }
        // Four light-only clusters in one 96 m cell, one in the next, one
        // with full trees in the first.
        let input = [cluster(5, full: false), cluster(20, full: false), cluster(50, full: false),
                     cluster(80, full: false), cluster(100, full: false), cluster(30, full: true)]
        let merged = WorldTiles.mergeLightClusters(input)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.reduce(0) { $0 + $1.light.triangleCount }, input.reduce(0) { $0 + $1.light.triangleCount })
        XCTAssertEqual(merged.reduce(0) { $0 + $1.impostor.triangleCount },
                       input.reduce(0) { $0 + $1.impostor.triangleCount })
        XCTAssertEqual(merged.filter { !$0.full.isEmpty }.count, 1)
    }

    /// High builds the Riviera with the constants `RivieraDetail` replaced.
    func test_highTierKeepsTheBuildersDistances() {
        let high = RivieraDetail.make(.high)
        XCTAssertEqual(high.fineRailM, 35)
        XCTAssertEqual(high.houseDetailM, BuildingBuilder.detailRouteDistance)
        XCTAssertEqual(high.greenhouseDetailM, BuildingBuilder.greenhouseDetailDistance)
        XCTAssertEqual(high.terraceWallM, 250)
        XCTAssertEqual(high.otherWallM, 120)
        XCTAssertEqual(high.fenceM, 60)
        // The ironwork lets go no further out than the rest of the props.
        XCTAssertLessThanOrEqual(high.ironM, 500)
        XCTAssertGreaterThan(high.ironM, 300)
        // High keeps its 1 m terrain (the side roads are draped on it) and
        // its plants; the 2 m and 4 m lattices end nearer (round 2).
        let base = WorldConfig.make(.high), riviera = base.riviera()
        XCTAssertEqual(riviera.terrain1mRadius, base.terrain1mRadius)
        XCTAssertLessThan(riviera.terrain2mRadius, base.terrain2mRadius)
        XCTAssertGreaterThan(riviera.terrain2mRadius, riviera.terrain1mRadius)
        XCTAssertGreaterThan(riviera.terrain4mRadius, riviera.terrain2mRadius)
        XCTAssertEqual(riviera.treeDetailRouteRadius, base.treeDetailRouteRadius)
        XCTAssertEqual(riviera.shrubMaxRouteRadius, base.shrubMaxRouteRadius)
        // The lower tiers only ever draw less.
        for q in [GraphicsQuality.balanced, .battery] {
            let b = WorldConfig.make(q), r = b.riviera(), d = RivieraDetail.make(q)
            XCTAssertLessThanOrEqual(r.terrain1mRadius, b.terrain1mRadius)
            XCTAssertLessThanOrEqual(r.terrain2mRadius, b.terrain2mRadius)
            XCTAssertLessThanOrEqual(r.terrain4mRadius, b.terrain4mRadius)
            XCTAssertLessThanOrEqual(r.shrubMaxRouteRadius, b.shrubMaxRouteRadius)
            XCTAssertEqual(r.treeDetailRouteRadius, b.treeDetailRouteRadius)
            XCTAssertLessThanOrEqual(d.fineRailM, high.fineRailM)
            XCTAssertLessThanOrEqual(d.greenhouseMaxM, high.greenhouseMaxM)
            XCTAssertLessThanOrEqual(d.ironM, high.ironM)
            XCTAssertLessThanOrEqual(r.terrain2mRadius, riviera.terrain2mRadius)
            XCTAssertGreaterThan(r.terrain2mRadius, r.terrain1mRadius)
            XCTAssertGreaterThan(r.terrain4mRadius, r.terrain2mRadius)
        }
    }
}
