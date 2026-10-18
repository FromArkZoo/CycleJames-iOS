import SceneKit
import simd

enum CameraMode: String, CaseIterable, Sendable {
    /// Behind and above the rider, like Zwift's default view.
    case chase
    /// Low and tight behind the rear wheel.
    case close
    /// Rider's eye view over the bars.
    case firstPerson
    /// Side-on, slightly ahead, like a race moto camera.
    case broadcast

    var label: String {
        switch self {
        case .chase: "Chase"
        case .close: "Close"
        case .firstPerson: "Rider view"
        case .broadcast: "Broadcast"
        }
    }

    var next: CameraMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Follows the rider.
///
/// Each mode describes a shot (where the eye wants to be, what it turns
/// towards, where the rider sits in the frame, the lens). Shots are blended
/// when the mode changes and when the ride stops or starts (an idle orbit),
/// smoothed with critically damped springs on the offset from the rider, and
/// then kept out of the terrain: the camera rises and/or pulls in so it never
/// enters the ground, a bank, a hedge or a building and always has a clear
/// line to the rider. In a blend the positions are mixed, but each shot is
/// aimed on its own from where the camera actually is and the rotations are
/// mixed, so turning from looking up the road to looking back at the rider
/// is an even pan.
///
/// Everything runs on SceneKit's render thread in `update`; nothing here is
/// touched from the main thread once the view is showing.
///
/// Rider view sits on `riderEye` (the rider rig's eye node) when it is set.
/// Once the camera is that close, `hidesRiderHead` turns true and the owner
/// hides the head (`RiderRig.setHeadVisible(false)`); the near plane also
/// moves out to `riderViewNearClipM`, and nodes whose `categoryBitMask` is
/// exactly `riderViewHiddenCategory` are not drawn by this camera (they still
/// cast shadows), for any other near geometry that should go.
final class CameraRig {
    let node = SCNNode()
    var mode: CameraMode = .chase

    /// Width / height of the rendered viewport. The scene view sets this
    /// every frame; field of view adapts so portrait doesn't get a letterbox
    /// of a landscape lens.
    var viewportAspect: Float = 16.0 / 9.0
    /// Seconds a mode change takes.
    var transitionDuration: Double = 0.9
    /// Share of the viewport height covered by opaque-ish overlays at the
    /// top and bottom (a HUD over the scene). Third-person shots compose the
    /// rider in the part that stays visible; a change (a panel growing or
    /// folding away) eases in rather than jolting the view.
    var framingInsets: (top: Float, bottom: Float) = (0, 0)
    /// The rider's eyes, moving with the head. Rider view sits on it; without
    /// it the eye is a fixed point over the bars.
    weak var riderEye: SCNNode?
    /// True while the camera is at (or inside) the rider's head, so the
    /// head must not be drawn. Read it after `update`.
    private(set) var hidesRiderHead = false

    /// Category for rider-rig nodes (head, helmet, glasses) that rider view
    /// must not draw. Set a node's `categoryBitMask` to this value, replacing
    /// the default 1, to hide it from the camera only in rider view.
    static let riderViewHiddenCategory = 1 << 20
    static let riderViewNearClipM: Double = 0.2
    /// Closer than this to the eyes, the head is hidden.
    private static let headHideDistance: Float = 0.9

    let clearance: CameraClearance
    private let camera: SCNCamera
    private let baseCategoryMask: Int
    private let baseZNear: Double

    // Motion state (render thread only).
    private var started = false
    private var lastS = 0.0
    private var clock = 0.0
    private var crankPhase: Float = 0
    private var activeMode: CameraMode = .chase
    private var transition: Transition?
    private var lastModeShot: CameraShot?
    private var idle = CameraSpring1(0)
    private var orbitAngle = CameraSpring1(0)
    private var eyeOffset = CameraSpring3()
    /// The current mode's look target, relative to the rider.
    private var modeAim = CameraSpring3()
    private var raise = CameraSpring1(0)
    private var pull = CameraSpring1(1)
    private var cobbles = CameraSpring1(0)
    /// `framingInsets`, smoothed: x = top, y = bottom.
    private var framing = CameraSpring3()
    private var broadcastSide: Float = -1
    private var broadcastSideSpring = CameraSpring1(-1)
    private var broadcastSideTimer: Float = 0
    private var lastYaw = SIMD3<Float>(0, 0, -1)
    private var appliedZNear = 0.0
    private var appliedMask = 0

    /// Last frame's solve, for development checks.
    private(set) var debugState = DebugState()

    struct DebugState {
        var eye = SIMD3<Float>.zero
        var focus = SIMD3<Float>.zero
        var raise: Float = 0
        var pull: Float = 1
        var blocked = false
        var lineOfSight: Float = 1
    }

    private static let up = SIMD3<Float>(0, 1, 0)
    /// Rider's chest above the road: what the line-of-sight checks protect.
    private static let sightFocusHeight: Float = 1.05
    /// Lowest point of the rear tyre on screen from behind: the contact
    /// patch (0.4 m behind the rider's anchor, `BikeGeometry.rearAxleF`) and
    /// a little of the tyre's back.
    private static let rearTyreBehindAnchor: Float = 0.5

    init(world: CourseWorld) {
        let camera = SCNCamera()
        world.configureCamera(camera)
        camera.projectionDirection = .vertical
        self.camera = camera
        baseCategoryMask = camera.categoryBitMask
        baseZNear = camera.zNear
        appliedZNear = camera.zNear
        appliedMask = camera.categoryBitMask
        clearance = CameraClearance(bundle: world.bundle)
        node.camera = camera
        node.name = "camera"
    }

    /// Called every frame on the render thread after the rider has moved.
    func update(riderPose: RoutePose, s: Double, route: CourseRoute, snapshot: RideSnapshot, deltaTime: Double) {
        let dt = Float(min(max(deltaTime, 0), 0.1))
        let frame = RiderFrame(pose: riderPose)
        let reset = !started || dt == 0 || abs(s - lastS) > 25
        started = true
        lastS = s
        clock += Double(dt)
        crankPhase = (crankPhase + Float(snapshot.cadenceRpm / 60) * 2 * .pi * dt)
            .truncatingRemainder(dividingBy: 2 * .pi)
        let onCobbles: Float = route.surfaceName(at: s) == "cobbles" ? 1 : 0
        if reset { cobbles.snap(to: onCobbles) } else { cobbles.step(toward: onCobbles, omega: 3, dt: dt) }
        let framingTarget = SIMD3<Float>(framingInsets.top, framingInsets.bottom, 0)
        if reset { framing.snap(to: framingTarget) } else { framing.step(toward: framingTarget, omega: 4, dt: dt) }
        updateBroadcastSide(frame: frame, s: s, snapshot: snapshot, dt: dt, reset: reset)

        // The selected mode, blended from wherever the camera was when it
        // changed. Longer moves (behind the rider to in front) take longer.
        let changed = mode != activeMode
        activeMode = mode
        let target = shot(for: activeMode, frame: frame, s: s, snapshot: snapshot)
        if changed {
            if reset || lastModeShot == nil {
                transition = nil
            } else if var from = lastModeShot {
                from.eye = frame.anchor + eyeOffset.value
                from.aim = frame.anchor + modeAim.value
                let distance = simd_distance(from.eye, target.eye)
                let duration = Float(max(transitionDuration, 0.05)) * min(max(0.7 + 0.05 * distance, 1), 1.8)
                // Room beside the rider for the path to swing round it,
                // measured once so the path doesn't step as the lane changes.
                let lateral = snapshot.lateralM
                transition = Transition(
                    from: LocalShot(from, in: frame), progress: 0, duration: duration,
                    roomLeft: Float(clearance.freeLateral(at: s, side: -1, maxOffset: 3) + lateral),
                    roomRight: Float(clearance.freeLateral(at: s, side: 1, maxOffset: 3) - lateral)
                )
            }
        }
        var shot = target
        var blendFrom: CameraShot?
        var blendW: Float = 0
        if var t = transition {
            t.progress += dt / t.duration
            if t.progress >= 1 {
                transition = nil
            } else {
                transition = t
                let from = t.from.world(in: frame)
                blendW = CameraMath.smootherstep(t.progress)
                blendFrom = from
                shot = Self.transitionBlend(from: from, to: target, blendW, frame: frame, room: (t.roomLeft, t.roomRight))
            }
        }
        let blending = blendFrom != nil
        if reset || blending {
            modeAim.snap(to: target.aim - frame.anchor)
        } else {
            modeAim.step(toward: target.aim - frame.anchor, omega: target.aimOmega, dt: dt)
        }
        lastModeShot = shot

        // Ready or paused: a slow orbit in chase framing. On resume the orbit
        // unwinds to behind the rider before handing back to the mode.
        let running = snapshot.isRunning
        if reset {
            idle.snap(to: running ? 0 : 1)
            orbitAngle.snap(to: 0)
        } else if !running {
            orbitAngle.value += Self.orbitRate * dt
            orbitAngle.velocity = Self.orbitRate
        } else {
            let home = (orbitAngle.value / (2 * .pi)).rounded() * 2 * .pi
            orbitAngle.step(toward: home, omega: 1.5, dt: dt)
        }
        let residual = abs(Float(CameraMath.wrap(Double(orbitAngle.value))))
        let idleTarget: Float = (!running || residual > 0.35) ? 1 : 0
        idle.step(toward: idleTarget, rising: 1.8, falling: 2.2, dt: dt)
        if running && idle.value < 0.002 && residual < 0.002 { orbitAngle.snap(to: 0) }
        let idleWeight = CameraMath.smootherstep(idle.value)
        var orbit: CameraShot?
        if idleWeight > 0.001 {
            let o = orbitShot(frame: frame, s: s, lateral: snapshot.lateralM)
            orbit = o
            shot = CameraShot.mix(shot, o, idleWeight)
        }

        // Smooth the offset from the rider, not the world position, so the
        // camera keeps up at any speed but swings wide through bends.
        let eyeTarget = shot.eye - frame.anchor
        if reset || blending {
            // A blend is already a smooth path; following it exactly keeps a
            // long lens from arriving before the camera does.
            eyeOffset.snap(to: eyeTarget)
        } else {
            eyeOffset.step(toward: eyeTarget, omega: shot.eyeOmega, dt: dt)
        }
        var eye = frame.anchor + eyeOffset.value
        let focus = frame.anchor + Self.up * Self.sightFocusHeight
        func station(_ p: SIMD3<Float>) -> Double { s + Double(simd_dot(p - frame.anchor, frame.forward)) }

        // Keep a clear line to the rider: rise over a bank, or come in under
        // it. Quick to react, slow to let go, so it doesn't hunt.
        var blocked = false
        if shot.lineOfSight > 0.01 {
            let fix = clearance.fixSightLine(
                focus: focus, eye: eye, focusS: s, eyeS: station(eye), maxRaise: shot.maxRaise
            )
            blocked = fix.blocked
            if reset {
                raise.snap(to: fix.raise)
                pull.snap(to: fix.pull)
            } else {
                raise.step(toward: fix.raise, rising: 9, falling: 1.6, dt: dt)
                pull.step(toward: fix.pull, rising: 1.4, falling: 10, dt: dt)
            }
        } else {
            raise.step(toward: 0, omega: 4, dt: dt)
            pull.step(toward: 1, omega: 4, dt: dt)
        }
        let los = min(max(shot.lineOfSight, 0), 1)
        let lift = raise.value * los
        let keep = 1 + (pull.value - 1) * los
        eye = focus + (eye + Self.up * lift - focus) * keep

        // Hard limits, whatever the springs are doing: never inside a
        // building or trunk, never closer than 0.35 m to the ground.
        if clearance.isInsideBlock(eye) {
            let toFocus = focus - eye
            let steps = max(1, Int(simd_length(toFocus) / 0.2))
            for k in 1...steps {
                let p = eye + toFocus * (Float(k) / Float(steps))
                if !clearance.isInsideBlock(p) || k == steps { eye = p; break }
            }
        }
        // Nor parked inside a tree's crown, where the lens sees only leaves:
        // come in towards the rider until clear of it (not in rider view,
        // which rides wherever the rider's head goes).
        if shot.riderView < 0.5, clearance.isInFoliage(eye) {
            let toFocus = focus - eye
            let steps = max(1, Int((simd_length(toFocus) - 1.5) / 0.2))
            for k in 1...steps {
                let p = eye + toFocus * (Float(k) * 0.2 / max(simd_length(toFocus), 0.01))
                if !clearance.isInFoliage(p) || k == steps { eye = p; break }
            }
        }
        let floor = clearance.groundTop(disc: eye, radius: 0.3, near: station(eye)) + 0.35
        if eye.y < floor { eye.y = floor }

        // Head bob, cobble buzz: after the springs so they stay crisp.
        eye += frame.right * shot.jitter.x + Self.up * shot.jitter.y + frame.forward * shot.jitter.z

        // Each shot aimed from where the camera is, the rotations blended.
        let lens = lens(for: shot)
        var aimed = target
        aimed.aim = frame.anchor + modeAim.value
        var q = orientation(of: aimed, eye: eye, frame: frame, lens: lens)
        if let from = blendFrom {
            q = simd_slerp(orientation(of: from, eye: eye, frame: frame, lens: lens), q, blendW)
        }
        if let orbit {
            q = simd_slerp(q, orientation(of: orbit, eye: eye, frame: frame, lens: lens), idleWeight)
        }
        // Between two level views the slerp tilts the horizon; level it.
        q = Self.levelled(q, fallbackYaw: lastYaw)
        if abs(shot.roll) > 1e-5 {
            q = q * simd_quatf(angle: shot.roll, axis: SIMD3(0, 0, 1))
        }
        q = simd_normalize(q)
        if let yaw = CameraMath.horizontalUnit(q.act(SIMD3(0, 0, -1))) { lastYaw = yaw }
        node.simdWorldPosition = eye
        node.simdWorldOrientation = q
        camera.fieldOfView = CGFloat(CameraMath.degrees(lens.vfov))
        applyLens(shot, eye: eye)
        debugState = DebugState(
            eye: eye, focus: focus, raise: lift, pull: keep, blocked: blocked, lineOfSight: shot.lineOfSight
        )
    }

    // MARK: Shots

    private static let orbitRate: Float = 2 * .pi / 50

    /// 0 on landscape screens, rising to 1 on a portrait phone.
    private var portraitness: Float {
        min(max((1.3 - viewportAspect) / 0.8, 0), 1)
    }

    private func shot(for mode: CameraMode, frame: RiderFrame, s: Double, snapshot: RideSnapshot) -> CameraShot {
        let speed = Float(max(snapshot.speedMps, 0))
        let lateral = snapshot.lateralM
        let up = Self.up
        let tall = portraitness
        switch mode {
        case .chase:
            // Path-following: the eye sits on the road behind, so in the
            // sunken lane it stays between the banks through the bend. On a
            // tall screen it sits higher so the road ahead fills the frame
            // above the rider instead of sky.
            let back = 5.3 + Double(min(speed, 14)) * 0.06 + 0.5 * Double(tall)
            let eye = clearance.pose(at: s - back, lateral: lateral * 0.85).position + up * (2.3 + 1.2 * tall)
            let aim = clearance.pose(at: s + 14, lateral: lateral * 0.5).position + up * 1.3
            return CameraShot(
                eye: eye, aim: aim, focusHeight: 1.0, screenY: -0.36 - 0.08 * tall, aimPitch: 0, hfov: 72,
                maxRaise: 1.6, eyeOmega: 4.5, aimOmega: 3.5, lineOfSight: 1, riderView: 0
            )

        case .close:
            // Low over the cobbles just behind the rear wheel, a touch to the
            // left so the road ahead shows past the rider. The rider stays
            // near the middle of the frame even on the bend (the lens is
            // narrow across a portrait screen); on a tall screen the rider
            // sits a little higher so the cobbles fill the bottom, not sky
            // the top.
            let eye = clearance.pose(at: s - 2.0, lateral: lateral - 0.3).position + up * 0.62
            let aim = clearance.pose(at: s + 8, lateral: lateral * 0.7).position + up * 1.0
            let buzz = cobbleBuzz(speed: speed, amplitude: 0.004)
            return CameraShot(
                eye: eye, aim: aim, focusHeight: 0.95, screenY: -0.04 + 0.16 * tall, aimPitch: 0, hfov: 84,
                maxRaise: 0.8, eyeOmega: 7, aimOmega: 5, lineOfSight: 1, riderView: 0,
                frameKeep: 0.3, jitter: SIMD3(0, buzz, 0)
            )

        case .firstPerson:
            let cadence = Float(snapshot.cadenceRpm)
            let pedalling = min(cadence / 60, 1)
            // Climbing out of the saddle on the steep ramps rocks the head more.
            let rocking: Float = snapshot.gradePct > 12 && speed < 5 ? 1.8 : 1
            // The rider rig already moves the head (rocking out of the
            // saddle, the bike's buzz); add only a little on top of it.
            let anchor = riderEye
            let amp = pedalling * rocking * (anchor == nil ? 1 : 0.3)
            let bob = SIMD3<Float>(
                0.014 * amp * sin(crankPhase),
                0.008 * amp * sin(2 * crankPhase) + cobbleBuzz(speed: speed, amplitude: anchor == nil ? 0.006 : 0.003),
                0
            )
            let eye: SIMD3<Float>
            var roll = 0.006 * amp * sin(crankPhase)
            if let anchor {
                // Just in front of the eyes, so nothing of the face is in
                // front of the lens. The gaze itself stays on the road (as a
                // rider's does); only part of the head's lean comes through.
                let t = anchor.simdWorldTransform
                eye = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z) + frame.forward * 0.03
                let headRight = simd_normalize(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z))
                roll += 0.4 * asin(min(max(simd_dot(headRight, up), -0.5), 0.5))
            } else {
                eye = frame.world(SIMD3(0, 1.45, 0.42))
            }
            let aim = clearance.pose(at: s + 9, lateral: lateral).position + up * 1.15
            return CameraShot(
                eye: eye, aim: aim, focusHeight: 1.0, screenY: 0, aimPitch: 1, hfov: 82,
                maxRaise: 0, eyeOmega: 40, aimOmega: 6, lineOfSight: 0, riderView: 1,
                narrowKeep: 0.85, pitchBias: -0.16 * tall,
                jitter: bob, roll: roll
            )

        case .broadcast:
            // A moto a few metres up the road, drifting slowly, the camera
            // turned back on the rider.
            let t = Float(clock)
            let ahead = 7.2 + 1.4 * sin(t * 0.21) + min(speed, 14) * 0.15
            let st = s + Double(ahead)
            let freeLeft = clearance.freeLateral(at: st, side: -1, maxOffset: 3.4)
            let freeRight = clearance.freeLateral(at: st, side: 1, maxOffset: 3.4)
            let swing = 1.7 + 0.25 * Double(sin(t * 0.17))
            let left = max(lateral - swing, -(freeLeft - 0.35))
            let right = min(lateral + swing, freeRight - 0.35)
            let side = Double((broadcastSideSpring.value + 1) / 2)
            let camLateral = left + (right - left) * side
            let height: Float = 1.4 + 0.2 * sin(t * 0.13 + 1.3)
            let eye = clearance.pose(at: st, lateral: camLateral).position + up * height
            let aim = frame.anchor + up * 1.0
            return CameraShot(
                eye: eye, aim: aim, focusHeight: 1.0, screenY: -0.08, aimPitch: 0, hfov: 38,
                maxRaise: 1.0, eyeOmega: 2.0, aimOmega: 3.0, lineOfSight: 1, riderView: 0,
                narrowKeep: 0.55, frameKeep: 0.5
            )
        }
    }

    /// The idle orbit: a circle where there's room, flattening to an
    /// ellipse inside a sunken lane or between house walls (and rising a
    /// little at the sides) so it stays in the open instead of being pushed
    /// out of the banks.
    private func orbitShot(frame: RiderFrame, s: Double, lateral: Double) -> CameraShot {
        let radius: Float = 5.4
        let angle = orbitAngle.value
        let across = sin(angle)
        let room: Double = across >= 0
            ? clearance.freeLateral(at: s, side: 1, maxOffset: 6) - lateral
            : clearance.freeLateral(at: s, side: -1, maxOffset: 6) + lateral
        let side = min(radius, max(Float(room) - 0.35, 0.8))
        let rise = 1.0 * across * across * (1 - side / radius)
        let eye = frame.anchor
            + frame.forward * (-cos(angle) * radius)
            + frame.right * (across * side)
            + Self.up * (2.4 + 0.6 * portraitness + rise)
        // Widen the lens where the ellipse comes in close, so the rider stays
        // about the same size in frame all the way round.
        let distance = simd_distance(eye, frame.anchor + Self.up * 1.0)
        let hfov = min(88, 70 * (5.8 / max(distance, 1)).squareRoot())
        return CameraShot(
            eye: eye,
            aim: frame.anchor + Self.up * 1.0,
            focusHeight: 1.0, screenY: -0.2, aimPitch: 0, hfov: max(70, hfov),
            maxRaise: 1.6, eyeOmega: 3, aimOmega: 3, lineOfSight: 1, riderView: 0
        )
    }

    /// Small vertical buzz on cobbles, scaled with speed. Sum of
    /// incommensurate sines, so it never visibly repeats.
    private func cobbleBuzz(speed: Float, amplitude: Float) -> Float {
        let t = Float(clock.truncatingRemainder(dividingBy: 1000))
        let strength = (0.15 + 0.85 * cobbles.value) * min(speed / 5, 1)
        let wave = sin(t * 37.1) + 0.6 * sin(t * 53.7 + 1.3) + 0.4 * sin(t * 71.9 + 2.1)
        return amplitude * strength * wave / 2
    }

    /// Picks which side of the road the moto rides: the one with more room
    /// beside the rider, or the outside of a coming bend so the inside bank
    /// doesn't come between camera and rider. Changes sides only after the
    /// reason has held for a while, then drifts across slowly.
    private func updateBroadcastSide(frame: RiderFrame, s: Double, snapshot: RideSnapshot, dt: Float, reset: Bool) {
        let ahead = s + 9
        let roomLeft = snapshot.lateralM + clearance.freeLateral(at: ahead, side: -1, maxOffset: 3.4)
        let roomRight = clearance.freeLateral(at: ahead, side: 1, maxOffset: 3.4) - snapshot.lateralM
        var preferred: Float = roomLeft >= roomRight - 0.2 ? -1 : 1
        let route = clearance.route
        let turn = CameraMath.wrap(
            route.pose(at: min(s + 18, route.length)).headingRadians - route.pose(at: s).headingRadians
        )
        if abs(turn) > 0.3 { preferred = turn > 0 ? -1 : 1 }
        if reset {
            broadcastSide = preferred
            broadcastSideTimer = 0
            broadcastSideSpring.snap(to: preferred)
            return
        }
        if preferred != broadcastSide {
            broadcastSideTimer += dt
            if broadcastSideTimer > 2.5 {
                broadcastSide = preferred
                broadcastSideTimer = 0
            }
        } else {
            broadcastSideTimer = 0
        }
        broadcastSideSpring.step(toward: broadcastSide, omega: 0.9, dt: dt)
    }

    /// Mode-change blend in rider-local space, with a lift and a swing round
    /// the rider when the straight path would pass through them: sideways
    /// where the road leaves `room` (metres free left and right of the
    /// rider), over the top where banks or walls are close. Into or out of
    /// rider view it goes over the shoulder rather than past the bike.
    private static func transitionBlend(
        from a: CameraShot, to b: CameraShot, _ w: Float, frame: RiderFrame, room: (left: Float, right: Float)
    ) -> CameraShot {
        var shot = CameraShot.mix(a, b, w)
        // Zoom in late and out early, so a long lens never meets a camera
        // that is still passing close to the rider.
        let lensW = b.hfov < a.hfov ? w * w : 1 - (1 - w) * (1 - w)
        shot.hfov = a.hfov + (b.hfov - a.hfov) * lensW
        shot.narrowKeep = a.narrowKeep + (b.narrowKeep - a.narrowKeep) * lensW
        let la = frame.local(a.eye), lb = frame.local(b.eye)
        let arc = sin(.pi * w)
        let distance = simd_distance(la, lb)
        var swing = SIMD3<Float>(0, min(0.15 * distance, 2.0) * arc, 0)
        // Closest approach of the straight path to the rider's vertical axis.
        let pa = SIMD2(la.x, la.z), pb = SIMD2(lb.x, lb.z)
        let ab = pb - pa
        let t = simd_length_squared(ab) > 1e-6 ? min(max(-simd_dot(pa, ab) / simd_length_squared(ab), 0), 1) : 0
        let closest = pa + ab * t
        let gap = simd_length(closest)
        if gap < 2 {
            let away = gap > 1e-3 ? closest / gap : SIMD2<Float>(-1, 0)
            let push = (2 - gap) * arc
            var side = away.x * push
            let shoulder: Float = max(a.riderView, b.riderView) > 0.5 ? 0.5 : .infinity
            let allowed = min(max((side < 0 ? room.left : room.right) - 0.4, 0), shoulder)
            if abs(side) > allowed {
                swing.y += (abs(side) - allowed) * 0.9
                side = side < 0 ? -allowed : allowed
            }
            swing.x += side
            swing.z += away.y * push
        }
        shot.eye += frame.right * swing.x + Self.up * swing.y + frame.forward * swing.z
        return shot
    }

    // MARK: Output

    /// The same view direction with the horizon level.
    private static func levelled(_ q: simd_quatf, fallbackYaw: SIMD3<Float>) -> simd_quatf {
        let forward = simd_normalize(q.act(SIMD3(0, 0, -1)))
        let flat = CameraMath.horizontalUnit(forward, minLength: 0.02) ?? fallbackYaw
        let pitch = min(max(asin(min(max(forward.y, -1), 1)), -1.2), 1.1)
        let f = flat * cos(pitch) + up * sin(pitch)
        let right = simd_normalize(simd_cross(f, up))
        return simd_quatf(simd_float3x3(columns: (right, simd_cross(right, f), -f)))
    }

    private struct Lens {
        var vfov: Float
        var halfV: Float
        var halfH: Float
    }

    private func lens(for shot: CameraShot) -> Lens {
        let aspect = max(viewportAspect, 0.2)
        let vfov = Self.verticalFOV(hfov16x9: shot.hfov, aspect: aspect, narrowKeep: shot.narrowKeep)
        return Lens(vfov: vfov, halfV: vfov / 2, halfH: atan(tan(vfov / 2) * aspect))
    }

    /// Turns towards the shot's aim point, pitched so the rider sits at the
    /// shot's screen height (or at the aim, in rider view), keeping the rider
    /// horizontally inside the frame.
    private func orientation(of shot: CameraShot, eye: SIMD3<Float>, frame: RiderFrame, lens: Lens) -> simd_quatf {
        let focus = frame.anchor + Self.up * shot.focusHeight
        let aim = shot.aim
        var yaw = CameraMath.horizontalUnit(aim - eye, minLength: 0.3) ?? lastYaw
        if shot.aimPitch < 0.999, let toFocus = CameraMath.horizontalUnit(focus - eye, minLength: 0.5) {
            let angle = atan2(yaw.x * toFocus.z - yaw.z * toFocus.x, simd_dot(yaw, toFocus))
            let limit = atan(shot.frameKeep * tan(lens.halfH)) + shot.aimPitch * .pi
            if abs(angle) > limit {
                yaw = CameraMath.rotateAboutUp(yaw, angle - (angle > 0 ? limit : -limit))
            }
        }

        let toAim = aim - eye
        let aimPitch = atan2(toAim.y, max(simd_length(SIMD2(toAim.x, toAim.z)), 0.01))
        let toFocus = focus - eye
        let along = max(simd_dot(SIMD3(toFocus.x, 0, toFocus.z), yaw), 0.3)
        // The shot's screen height, within the band the overlays leave clear.
        let lo = -1 + 2 * min(max(framing.value.y, 0), 0.4)
        let hi = 1 - 2 * min(max(framing.value.x, 0), 0.4)
        let screenY = (lo + hi) / 2 + shot.screenY * (hi - lo) / 2
        let tanV = tan(lens.halfV)
        var composePitch = atan2(toFocus.y, along) - atan(screenY * tanV)
        // From a following distance, look down far enough that the rear
        // tyre stays just above the band's floor (a bottom panel, or the
        // screen edge on a short landscape frame). Close in, the bike fills
        // the frame anyway and the rider's head matters more.
        let toTyre = frame.anchor - frame.forward * Self.rearTyreBehindAnchor - eye
        let tyreAlong = max(simd_dot(SIMD3(toTyre.x, 0, toTyre.z), yaw), 0.3)
        let tyrePitch = atan2(toTyre.y, tyreAlong) - atan((lo + 0.05) * tanV)
        let following = CameraMath.smootherstep((along - 3) / 1.5)
        composePitch += (min(composePitch, tyrePitch) - composePitch) * following
        let pitch = min(max(composePitch + (aimPitch - composePitch) * shot.aimPitch + shot.pitchBias, -1.2), 1.1)

        let forward = yaw * cos(pitch) + Self.up * sin(pitch)
        let right = simd_normalize(simd_cross(forward, Self.up))
        let camUp = simd_cross(right, forward)
        return simd_quatf(simd_float3x3(columns: (right, camUp, -forward)))
    }

    private func applyLens(_ shot: CameraShot, eye: SIMD3<Float>) {
        let riderView = shot.riderView
        // Hide the head as the camera arrives at it during a blend, not when
        // the blend starts (the head would vanish from a camera metres away).
        if let riderEye {
            hidesRiderHead = simd_distance(eye, riderEye.simdWorldPosition) < Self.headHideDistance
        } else {
            hidesRiderHead = riderView > 0.9
        }
        let zNear = riderView > 0.5 && hidesRiderHead ? max(baseZNear, Self.riderViewNearClipM) : baseZNear
        if zNear != appliedZNear {
            camera.zNear = zNear
            appliedZNear = zNear
        }
        let mask = riderView > 0.6 ? baseCategoryMask & ~Self.riderViewHiddenCategory : baseCategoryMask
        if mask != appliedMask {
            camera.categoryBitMask = mask
            appliedMask = mask
        }
    }

    /// Vertical field of view for a lens described by its horizontal field
    /// on a 16:9 frame: wider screens see more to the sides; narrower ones
    /// keep at least `narrowKeep` of that width until the vertical reaches 70°.
    static func verticalFOV(hfov16x9 degrees: Float, aspect: Float, narrowKeep: Float = 0.8) -> Float {
        let h = CameraMath.radians(degrees)
        let vLandscape = 2 * atan(tan(h / 2) / (16.0 / 9.0))
        let vNarrow = 2 * atan(tan(h * narrowKeep / 2) / aspect)
        return min(max(vLandscape, vNarrow), CameraMath.radians(70))
    }

}

// MARK: - Shot description

/// One camera set-up. Positions are world space.
private struct CameraShot {
    var eye: SIMD3<Float>
    /// What the camera turns towards (and pitches at, by `aimPitch`).
    var aim: SIMD3<Float>
    /// Rider point that the composition places at `screenY`, above the road.
    var focusHeight: Float
    /// Normalised height of the rider in frame, −1 bottom … 1 top.
    var screenY: Float
    /// 0 = pitch from the rider composition, 1 = pitch straight at `aim`.
    var aimPitch: Float
    /// Horizontal field of view on a 16:9 frame, degrees.
    var hfov: Float
    /// How far the camera may rise to see over a bank before it pulls in.
    var maxRaise: Float
    var eyeOmega: Float
    var aimOmega: Float
    /// 0…1: how strictly the line to the rider is kept clear.
    var lineOfSight: Float
    /// 0…1: rider view (near clip and hidden head).
    var riderView: Float
    /// Share of the horizontal field kept on screens narrower than 16:9.
    var narrowKeep: Float = 0.8
    /// How far off-centre the rider may sit, as a share of the half width.
    var frameKeep: Float = 0.62
    /// Extra pitch, radians (rider view looks further down on tall screens).
    var pitchBias: Float = 0
    /// Offset added after smoothing, rider-local (x right, y up, z forward).
    var jitter: SIMD3<Float> = .zero
    var roll: Float = 0

    static func mix(_ a: CameraShot, _ b: CameraShot, _ w: Float) -> CameraShot {
        func m(_ x: Float, _ y: Float) -> Float { x + (y - x) * w }
        return CameraShot(
            eye: simd_mix(a.eye, b.eye, SIMD3(repeating: w)),
            aim: simd_mix(a.aim, b.aim, SIMD3(repeating: w)),
            focusHeight: m(a.focusHeight, b.focusHeight),
            screenY: m(a.screenY, b.screenY),
            aimPitch: m(a.aimPitch, b.aimPitch),
            hfov: m(a.hfov, b.hfov),
            maxRaise: m(a.maxRaise, b.maxRaise),
            eyeOmega: m(a.eyeOmega, b.eyeOmega),
            aimOmega: m(a.aimOmega, b.aimOmega),
            lineOfSight: m(a.lineOfSight, b.lineOfSight),
            riderView: m(a.riderView, b.riderView),
            narrowKeep: m(a.narrowKeep, b.narrowKeep),
            frameKeep: m(a.frameKeep, b.frameKeep),
            pitchBias: m(a.pitchBias, b.pitchBias),
            jitter: simd_mix(a.jitter, b.jitter, SIMD3(repeating: w)),
            roll: m(a.roll, b.roll)
        )
    }
}

/// A shot frozen relative to the rider, so a blend that starts from it
/// keeps moving with the rider.
private struct LocalShot {
    private var shot: CameraShot

    init(_ shot: CameraShot, in frame: RiderFrame) {
        var local = shot
        local.eye = frame.local(shot.eye)
        local.aim = frame.local(shot.aim)
        self.shot = local
    }

    func world(in frame: RiderFrame) -> CameraShot {
        var world = shot
        world.eye = frame.world(shot.eye)
        world.aim = frame.world(shot.aim)
        return world
    }
}

/// A mode change in progress.
private struct Transition {
    var from: LocalShot
    var progress: Float
    var duration: Float
    /// Free road beside the rider when it started, metres.
    var roomLeft: Float
    var roomRight: Float
}

/// The rider's position with a level heading frame.
private struct RiderFrame {
    let anchor: SIMD3<Float>
    let forward: SIMD3<Float>
    let right: SIMD3<Float>

    init(pose: RoutePose) {
        anchor = pose.position
        forward = CameraMath.horizontalUnit(pose.forward) ?? SIMD3(0, 0, -1)
        right = SIMD3(-forward.z, 0, forward.x)
    }

    /// (x right, y up, z forward) relative to the rider.
    func local(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let d = p - anchor
        return SIMD3(simd_dot(d, right), d.y, simd_dot(d, forward))
    }

    func world(_ l: SIMD3<Float>) -> SIMD3<Float> {
        anchor + right * l.x + SIMD3(0, l.y, 0) + forward * l.z
    }
}
