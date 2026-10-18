import Foundation

/// Longitudinal bike dynamics for course rides: the rider's power against
/// gravity, rolling resistance and air drag along the route.
///
///     m_eff · dv/dt = P·η / v − m·g·sin θ − Crr·m·g·cos θ − ½·ρ·CdA·v²
///
/// `m_eff` adds the wheels' rotational inertia to the system mass; gravity
/// and rolling use the plain mass. The P/v term is stiff as v → 0, so each
/// sub-step is split (Strang): half a step of the resistive forces in
/// velocity, the rider's work added as kinetic energy (½·m_eff·v² += P·η·h,
/// finite at v = 0), then the other half of the forces. Speed never goes
/// negative: with no power on a ramp the rider slows to a stop and stays
/// there, while a descent steep enough to beat rolling resistance pulls a
/// stopped bike forward.
///
/// Speed is along the road surface, but route distance is horizontal (the
/// course pipeline measures `s` on the map and `gradePct` is d(elev)/ds),
/// so the rider advances `s` by the horizontal part of that speed, v·cos θ.
enum RidePhysics {
    static let gravity = 9.80665
    /// Longest integration sub-step, seconds.
    static let maxSubstep = 1.0 / 120
    /// Safety cap; the Flemish bergs never get close.
    static let maxSpeedMps = 30.0

    struct Parameters: Sendable, Equatable {
        /// Rider + bike, kg.
        var massKg: Double
        /// Equivalent mass of both wheels' rotational inertia (ΣI / r²), kg.
        var wheelInertiaKg: Double = 1.5
        /// Drag area on the hoods, m².
        var cdA: Double = 0.32
        var drivetrainEfficiency: Double = 0.975
        /// Air density, kg/m³.
        var airDensity: Double = 1.225

        var effectiveMassKg: Double { massKg + wheelInertiaKg }

        static func rider(weightKg: Double, bikeKg: Double) -> Parameters {
            Parameters(massKg: max(weightKg + bikeKg, 1))
        }
    }

    /// The road under the wheels at one point.
    struct Terrain: Sendable, Equatable {
        var gradePct: Double
        var crr: Double
    }

    struct State: Sendable, Equatable {
        var distanceM: Double
        var speedMps: Double
    }

    /// Force opposing motion at `speedMps`, newtons. Negative on a descent
    /// steep enough for gravity to beat rolling resistance and drag.
    static func resistiveForce(speedMps v: Double, terrain: Terrain, params: Parameters) -> Double {
        let theta = atan(terrain.gradePct / 100)
        let mg = params.massKg * gravity
        return mg * sin(theta) + terrain.crr * mg * cos(theta)
            + 0.5 * params.airDensity * params.cdA * v * v
    }

    /// Advances the rider by `dt` seconds at constant `powerW` (crank power;
    /// drivetrain losses are applied here). `terrain` gives the gradient and
    /// rolling resistance at a (horizontal) distance along the route.
    static func step(
        _ state: State,
        powerW: Double,
        dt: Double,
        params: Parameters,
        terrain: (Double) -> Terrain
    ) -> State {
        guard dt > 0 else { return state }
        let substeps = max(1, Int((dt / maxSubstep).rounded(.up)))
        let h = dt / Double(substeps)
        let m = params.effectiveMassKg
        // Kinetic energy the rider adds per sub-step, expressed as v².
        let workV2 = 2 * max(0, powerW) * params.drivetrainEfficiency * h / m
        var s = state.distanceM
        var v = max(0, state.speedMps)

        for _ in 0..<substeps {
            let road = terrain(s)
            let v0 = v
            v = max(0, v - 0.5 * h * resistiveForce(speedMps: v, terrain: road, params: params) / m)
            v = (v * v + workV2).squareRoot()
            v = max(0, v - 0.5 * h * resistiveForce(speedMps: v, terrain: road, params: params) / m)
            v = min(v, maxSpeedMps)
            // Horizontal part of the distance along the slope: cos(atan g).
            let g = road.gradePct / 100
            s += 0.5 * (v0 + v) * h / (1 + g * g).squareRoot()
        }
        return State(distanceM: s, speedMps: v)
    }

    /// Speed at which `powerW` balances the resistive forces on a constant
    /// gradient (the speed `step` settles to). Bisection on P·η = v·F(v),
    /// which has exactly one root for v > 0.
    static func steadySpeed(powerW: Double, terrain: Terrain, params: Parameters) -> Double {
        let target = max(0, powerW) * params.drivetrainEfficiency
        func excess(_ v: Double) -> Double {
            v * resistiveForce(speedMps: v, terrain: terrain, params: params) - target
        }
        var lo = 0.0, hi = maxSpeedMps
        guard excess(hi) > 0 else { return hi }
        for _ in 0..<80 {
            let mid = 0.5 * (lo + hi)
            if excess(mid) > 0 { hi = mid } else { lo = mid }
        }
        return 0.5 * (lo + hi)
    }
}
