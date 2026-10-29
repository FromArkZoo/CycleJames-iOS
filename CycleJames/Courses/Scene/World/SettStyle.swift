import Foundation

extension CourseArt.SettLook {
    /// The look as uniforms for `WorldShaders.settSurface`. Matched to
    /// photos of each climb (scripts/courses/debug/<id>/research_summary.json
    /// and the Commons photos of the three climbs): warm-neutral greys, no
    /// pastel blues; the Koppenberg's rounded "kinderkoppen" near square,
    /// strongly domed, with a quarter of rust and ochre stones; the
    /// Kwaremont's pale split stones, grey, buff and bluish, uneven in size
    /// and lay, with rough, tilted tops and chipped corners, most close
    /// together and some well short of their neighbours on sandy joints
    /// (every joint wide rings each stone like grout on new pavers); the
    /// Paterberg's darker, regular, domed setts close together; the Muur's
    /// smaller grey setts, close and polished; the Molenberg's near-square
    /// grey and blue-grey setts on wide mossy joints; the Taaienberg's warm,
    /// oblong, domed setts on wide sandy joints.
    var style: CourseArt.SettStyle {
        switch self {
        case .mixedGrey:
            CourseArt.SettStyle(
                layout: SIMD4(0.165, 0.150, 0.30, 0.40), joint: SIMD4(0.007, 0.016, 0.40, 0.16),
                shape: SIMD4(0.024, 0.95, 0.005, 0.048),
                stoneA: SIMD4(0.126, 0.117, 0.103, 0.26), stoneB: SIMD4(0.097, 0.096, 0.098, 0.34),
                stoneC: SIMD4(0.158, 0.110, 0.079, 0.22),
                wear: SIMD4(0.70, 0.30, 0.8, 0.025), farMatch: 0.885, farAO: 1.03, grainNormal: 1.0)
        case .paleSplit:
            CourseArt.SettStyle(
                layout: SIMD4(0.150, 0.145, 0.45, 0.65), joint: SIMD4(0.004, 0.010, 0.30, 0.10),
                shape: SIMD4(0.015, 0.30, 0.007, 0.014),
                stoneA: SIMD4(0.128, 0.126, 0.121, 0.30), stoneB: SIMD4(0.102, 0.103, 0.106, 0.28),
                stoneC: SIMD4(0.142, 0.128, 0.108, 0.15),
                wear: SIMD4(0.80, 0.35, 0.5, 0.02), farMatch: 0.92, farAO: 1.03, grainNormal: 4.0,
                split: SIMD4(0.016, 0.035, 0.032, 1.1))
        case .darkRegular:
            CourseArt.SettStyle(
                layout: SIMD4(0.140, 0.135, 0.14, 0.24), joint: SIMD4(0.004, 0.009, 0.32, 0.14),
                shape: SIMD4(0.019, 0.90, 0.002, 0.030),
                stoneA: SIMD4(0.115, 0.111, 0.106, 0.18), stoneB: SIMD4(0.095, 0.096, 0.100, 0.28),
                stoneC: SIMD4(0.137, 0.120, 0.100, 0.08),
                wear: SIMD4(0.70, 0.30, 0.6, 0.012), farMatch: 0.886, farAO: 1.11, grainNormal: 1.0)
        case .smallWorn:
            // Domed between the Paterberg's and the Kwaremont's, so the far
            // calibration sits between theirs (not measured on its own).
            CourseArt.SettStyle(
                layout: SIMD4(0.125, 0.118, 0.16, 0.26), joint: SIMD4(0.004, 0.009, 0.32, 0.14),
                shape: SIMD4(0.016, 0.75, 0.002, 0.026),
                stoneA: SIMD4(0.118, 0.115, 0.110, 0.22), stoneB: SIMD4(0.092, 0.092, 0.094, 0.30),
                stoneC: SIMD4(0.140, 0.124, 0.100, 0.12),
                wear: SIMD4(0.70, 0.30, 0.9, 0.015), farMatch: 0.89, farAO: 1.09, grainNormal: 1.0)
        case .mossyGrey:
            // Photos (debug/molenberg/research_summary.json): 13-15 cm, joints
            // 1.5-3 cm of soil and moss, gently to moderately domed, the odd
            // sett sunk or missing, little polish on a lane with few cars.
            CourseArt.SettStyle(
                layout: SIMD4(0.140, 0.140, 0.20, 0.30), joint: SIMD4(0.006, 0.014, 0.40, 0.16),
                shape: SIMD4(0.018, 0.70, 0.004, 0.030),
                stoneA: SIMD4(0.110, 0.107, 0.104, 0.22), stoneB: SIMD4(0.092, 0.092, 0.096, 0.32),
                stoneC: SIMD4(0.140, 0.115, 0.088, 0.20),
                wear: SIMD4(0.70, 0.30, 0.5, 0.025), farMatch: 0.89, farAO: 1.04, grainNormal: 1.0)
        case .warmOblong:
            // Photos (debug/taaienberg/research_summary.json): 14-16 cm along
            // the road by 16-22 cm across, domed and worn smooth, some proud,
            // joints 1-3 cm of sand and grit; relaid in 1993 and intact.
            CourseArt.SettStyle(
                layout: SIMD4(0.150, 0.190, 0.20, 0.35), joint: SIMD4(0.006, 0.014, 0.40, 0.16),
                shape: SIMD4(0.022, 0.85, 0.005, 0.040),
                stoneA: SIMD4(0.122, 0.114, 0.103, 0.26), stoneB: SIMD4(0.094, 0.093, 0.094, 0.32),
                stoneC: SIMD4(0.155, 0.112, 0.082, 0.24),
                wear: SIMD4(0.70, 0.30, 0.7, 0.015), farMatch: 0.887, farAO: 1.04, grainNormal: 1.0)
        }
    }

    /// Mixed into the shader's hashes, so the climbs never share a stone.
    var seed: Int {
        switch self {
        case .mixedGrey: 0
        case .paleSplit: 1
        case .darkRegular: 2
        case .smallWorn: 3
        case .mossyGrey: 4
        case .warmOblong: 5
        }
    }
}

extension CourseArt {
    /// Uniforms for `WorldShaders.settSurface` (lengths in metres, colours
    /// linear).
    struct SettStyle: Sendable {
        /// Course depth along the road, sett length across it, and their
        /// jitter as fractions.
        var layout: SIMD4<Float>
        /// Joint half width, least and most; joint depth over its width (how
        /// soon a joint hides behind the stone in front at grazing angles);
        /// the share of the surface in the stones' own sun shadows, which
        /// the far mean draws in and beside its joints in place of them.
        var joint: SIMD4<Float>
        /// Crown height above the joint fill, dome (0..1), tilt across a
        /// sett, rounding of corners and arrises.
        var shape: SIMD4<Float>
        /// Stone families: the main one with its lightness spread, then two
        /// more with their shares.
        var stoneA: SIMD4<Float>
        var stoneB: SIMD4<Float>
        var stoneC: SIMD4<Float>
        /// Wheel tracks' offset from the centre and half width, their polish
        /// (0..1), and the damaged share (sunk setts; a tenth of them
        /// missing; a relaid band in about 16 times that share of 250 m
        /// sections, so at most one in 250 m).
        var wear: SIMD4<Float>
        /// The far mean's albedo against the near setts' average: the
        /// domes' shading it cannot draw (`SettFarMap` has the shoulders'
        /// darkening). Calibrated in sun, with `farAO` in shade, so near and
        /// far match within 3 % in both (`-cobbleLod near|far`).
        var farMatch: Float
        /// The far mean's ambient occlusion on its stones (its joints take
        /// the near joints' 0.35), calibrated in shade. Above 1: the near
        /// domes' sides, turned to the camera, catch more of the sky and its
        /// reflection than the flat mean does, more so the rounder the setts.
        var farAO: Float
        /// Strength of the stone grain's normals (split, fractured tops).
        var grainNormal: Float
        /// Split stones: the most a side falls short of its neighbour
        /// (metres, drawn r⁴ on top of `joint`, so a few joints gape), the
        /// longest edge of a chipped corner (metres, drawn r²), the
        /// outline's fracture (metres peak to peak, from the grain's
        /// height) and the grain's mottle (the stone's lightness per unit
        /// of the grain's albedo factor). The default splits nothing.
        var split: SIMD4<Float> = SIMD4(0, 0, 0.016, 0.48)

        // How far the shader lets a boundary stray from its nominal place
        // (`settSurface`'s cjsCourseEdge and cjsSettEdge); its neighbour
        // search holds while that stays under half a course or half a sett.
        /// Largest slow turn of a course boundary, metres along per metre
        /// across (0.0045 + 0.002).
        static let courseTurn: Float = 0.0065
        /// Largest wave of a course boundary, metres.
        static let courseWave: Float = 0.003
        /// Skew of a sett boundary, metres across per metre from the
        /// course's middle line.
        static let settSkew: Float = 0.06
        /// Shortest batch length of a course, as a share of the sett length
        /// (0.88, less a little where it is rounded to a whole number of
        /// setts in `SettFarMap.span`).
        static let shortestBatch: Float = 0.86

        /// The far mean's uniform: the share of its joints that run across
        /// the road (between courses; they hide first at grazing angles),
        /// the rounded and chipped corners' share of the surface
        /// (`SettFarMap` lays the setts out as rectangles), `farMatch` and
        /// `farAO`. Half widths are drawn as mix(least, most, r²) +
        /// split.x r⁴, whose mean is a third of the way up plus a fifth of
        /// split.x; corner radii as shape.w x (0.2 + 0.9 r), whose mean
        /// square is 0.4 shape.w², and chips as split.y r², whose mean
        /// square is 0.2 split.y².
        var mean: SIMD4<Float> {
            SIMD4(courseJointShare / (courseJointShare + lateralJointShare), cornerShare, farMatch, farAO)
        }

        /// Mean joint half width.
        var meanJoint: Float { joint.x + (joint.y - joint.x) / 3 + split.x / 5 }

        /// Share of the surface in joints between courses.
        var courseJointShare: Float { 2 * meanJoint / layout.x }

        /// Share of the road's width in joints between setts.
        var lateralJointShare: Float { 2 * meanJoint / layout.y }

        /// Share of the surface outside the setts' rounded and chipped
        /// corners (a chip of edge c takes c² / 2; where it cuts deeper
        /// than the rounding the two overlap, which the far mean's
        /// calibration takes up).
        var cornerShare: Float {
            ((4 - .pi) * 0.4 * shape.w * shape.w + 2 * 0.2 * split.y * split.y) / (layout.x * layout.y)
        }

        /// Share of the surface in joints of any kind (the far mean's mean
        /// joint share: the far map's alpha and the corners).
        var jointShare: Float {
            let stones = (1 - courseJointShare) * (1 - lateralJointShare)
            return 1 - stones + cornerShare
        }

        /// Fade from full setts to the mean, as the pixel footprint over the
        /// course depth (start, end; beyond the end the per-sett work is
        /// skipped); normal strength; grain texture scale (1 / its 0.36 m
        /// tile). Balanced fades early (setts in full down to about 4.5 px a
        /// course) until the cost is measured on an iPhone 14.
        static func lod(_ q: GraphicsQuality) -> SIMD4<Float> {
            switch q {
            case .high: SIMD4(0.28, 0.70, 1.0, 1 / 0.36)
            case .balanced: SIMD4(0.22, 0.55, 1.0, 1 / 0.36)
            case .battery: SIMD4(0.18, 0.45, 0.8, 1 / 0.36)
            }
        }

        /// Strength of the stones' own sun shadows (the sun-to-sky
        /// irradiance ratio κ; 0 turns them off).
        static func microShadow(_ q: GraphicsQuality) -> Float {
            q == .battery ? 0 : 2.0
        }

        /// The uniforms that don't change with the tier. The stone colours
        /// reach the shader through `SettFarMap`; settJoint.w is the sun
        /// shadows' share per unit of joint share, as the far mean draws
        /// them.
        var uniforms: [(String, SIMD4<Float>)] {
            let j = SIMD4(joint.x, joint.y, joint.z, joint.w / jointShare)
            return [("settLayout", layout), ("settJoint", j), ("settShape", shape), ("settWear", wear), ("settMean", mean),
                    ("settSplit", split)]
        }
    }
}
