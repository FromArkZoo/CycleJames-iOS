import SceneKit
import simd

/// The rider and bike, posed on the road every frame.
///
/// A procedural road cyclist (1.80 m, 75 kg) on a 56 cm road bike, built
/// entirely in code at init. Each frame `update` turns the cranks and wheels,
/// picks a posture (seated, out of the saddle on steep ramps, or stopped with
/// the left foot down) and solves two-bone IK so the cleats stay locked on
/// the pedals and the hands on the hoods. Everything per frame is plain simd
/// maths on preallocated nodes, safe for SceneKit's render thread.
final class RiderRig {
    let node = SCNNode()
    /// Between the rider's eyes, facing along the gaze (−z), for a
    /// first-person camera. Moves with the head.
    let eyeNode = SCNNode()

    private let layout = RiderBodyLayout()
    /// Rolling resistance class per route surface index: 0 smooth … 1 cobbles.
    private let roughness: [Float]

    // Bike.
    private let bikeRoot = SCNNode()
    private let frontWheel = SCNNode(), rearWheel = SCNNode()
    private let frontSpokes: SCNNode, rearSpokes: SCNNode
    private let frontBlur: SCNNode, rearBlur: SCNNode
    private let crank = SCNNode()
    private let pedalRight: SCNNode, pedalLeft: SCNNode
    private let chainMaterial: SCNMaterial
    /// Every rider and bike material, for the sky light.
    private let skyMaterials: [SCNMaterial]
    private var sky: Float = 1, appliedSky: Float = 1, firstSky = true

    // Body segments, all direct children of `node` and posed in rig space.
    private let pelvis: SCNNode, torso: SCNNode, neck: SCNNode, head: SCNNode
    private let thighs: (r: SCNNode, l: SCNNode), shanks: (r: SCNNode, l: SCNNode), feet: (r: SCNNode, l: SCNNode)
    private let upperArms: (r: SCNNode, l: SCNNode), forearms: (r: SCNNode, l: SCNNode)

    // Motion state.
    private var crankAngle: Float = 0.9
    private var crankRate: Float = 0
    private var wheelAngle: Float = 0
    private var chainShift: Float = 0
    private var travel: Double = 0
    private var gradeS: Float = 0
    private var roughS: Float = 0
    private var blur: Float = 0
    private var standing = false, standHold: Float = 0, standRamp: Float = 0
    private var parked = false, parkHold: Float = 0, parkRamp: Float = 0
    private var firstFrame = true
    /// Hip height out of the saddle, solved at init so the leg nearly
    /// straightens at the bottom of the stroke.
    private let standHipHeight: Float

    /// Hip position out of the saddle, metres forward of the bottom bracket.
    private static let standHipF: Float = -0.020

    private typealias G = BikeGeometry
    private typealias M = RiderMath

    /// `surfaceNames` maps `RoutePose.surfaceIndex` to a surface (the
    /// course's `surfaces` array); cobbles and setts shake the bike.
    init(quality: GraphicsQuality, surfaceNames: [String] = ["asphalt", "cobbles"]) {
        roughness = surfaceNames.map { name in
            let n = name.lowercased()
            if n.contains("cobble") || n.contains("sett") || n.contains("pav") || n.contains("kassei") { return 1 }
            if n.contains("gravel") || n.contains("unpaved") || n.contains("dirt") { return 0.6 }
            return 0.07
        }
        node.name = "rider"
        let mats = RiderMaterials(quality: quality, layout: layout)
        let bd = RiderBodyMeshes.Detail(quality), kd = RiderBikeMeshes.Detail(quality)
        chainMaterial = mats.chain
        skyMaterials = mats.all

        func part(_ mesh: RiderMesh, _ materials: [SCNMaterial], _ name: String, shadow: Bool = true) -> SCNNode {
            let n = SCNNode(geometry: mesh.geometry(materials, name: name))
            n.name = name
            n.castsShadow = shadow
            return n
        }

        // MARK: Bike
        bikeRoot.name = "bike"
        node.addChildNode(bikeRoot)
        let frameMesh = RiderBikeMeshes.frame(kd, body: layout, bodyDetail: bd)
        bikeRoot.addChildNode(part(frameMesh, [mats.paint, mats.carbon, mats.rubber, mats.alloy, mats.steel, mats.glove, mats.bottle], "bike.frame"))

        let wheelMats = [mats.tyre, mats.rim, mats.alloy, mats.steel]
        let spokeMesh = { (rear: Bool) in RiderBikeMeshes.spokes(rear: rear, kd) }
        let blurMesh = RiderBikeMeshes.spokeBlur(kd)
        frontWheel.geometry = RiderBikeMeshes.wheel(rear: false, kd).geometry(wheelMats, name: "bike.frontWheel")
        rearWheel.geometry = RiderBikeMeshes.wheel(rear: true, kd).geometry(wheelMats, name: "bike.rearWheel")
        frontSpokes = part(spokeMesh(false), [mats.spokes], "bike.frontSpokes")
        rearSpokes = part(spokeMesh(true), [mats.spokes], "bike.rearSpokes")
        frontBlur = part(blurMesh, [mats.spokeBlur], "bike.frontBlur", shadow: false)
        rearBlur = part(blurMesh, [mats.spokeBlur], "bike.rearBlur", shadow: false)
        for (wheel, spokes, haze) in [(frontWheel, frontSpokes, frontBlur), (rearWheel, rearSpokes, rearBlur)] {
            wheel.addChildNode(spokes)
            wheel.addChildNode(haze)
            haze.isHidden = true
            bikeRoot.addChildNode(wheel)
        }
        frontWheel.simdPosition = G.frontAxle
        rearWheel.simdPosition = G.rearAxle

        crank.geometry = RiderBikeMeshes.crankset(kd).geometry([mats.alloy, mats.steel], name: "bike.crankset")
        bikeRoot.addChildNode(crank)
        let pedalMesh = RiderBikeMeshes.pedal(kd)
        pedalRight = part(pedalMesh, [mats.carbon, mats.steel], "bike.pedalRight")
        pedalLeft = part(pedalMesh.mirroredX(), [mats.carbon, mats.steel], "bike.pedalLeft")
        bikeRoot.addChildNode(pedalRight)
        bikeRoot.addChildNode(pedalLeft)
        bikeRoot.addChildNode(part(RiderBikeMeshes.chain(kd), [mats.chain], "bike.chain", shadow: false))

        // MARK: Rider
        let L = layout
        pelvis = part(RiderBodyMeshes.pelvis(bd), [mats.bib], "rider.pelvis")
        torso = part(RiderBodyMeshes.torso(bd), [mats.jersey], "rider.torso")
        neck = part(RiderBodyMeshes.neck(L, bd), [mats.skin], "rider.neck")
        head = part(RiderBodyMeshes.head(bd), [mats.head], "rider.head")
        head.addChildNode(part(RiderBodyMeshes.helmet(bd), [mats.helmet, mats.frameBlack], "rider.helmet"))
        head.addChildNode(part(RiderBodyMeshes.glasses(bd), [mats.lens, mats.frameBlack], "rider.glasses", shadow: false))
        eyeNode.name = "rider.eyes"
        eyeNode.simdPosition = L.eyes
        head.addChildNode(eyeNode)

        func pair(_ mesh: RiderMesh, _ mat: SCNMaterial, _ name: String) -> (r: SCNNode, l: SCNNode) {
            (part(mesh, [mat], name + "Right"), part(mesh.mirroredX(), [mat], name + "Left"))
        }
        thighs = pair(RiderBodyMeshes.thigh(L, bd), mats.thigh, "rider.thigh")
        shanks = pair(RiderBodyMeshes.shank(L, bd), mats.shank, "rider.shank")
        feet = pair(RiderBodyMeshes.shoe(bd), mats.shoe, "rider.foot")
        upperArms = pair(RiderBodyMeshes.upperArm(L, bd), mats.sleeve, "rider.upperArm")
        forearms = pair(RiderBodyMeshes.forearm(L, bd), mats.skin, "rider.forearm")
        for n in [pelvis, torso, neck, head, thighs.r, thighs.l, shanks.r, shanks.l, feet.r, feet.l,
                  upperArms.r, upperArms.l, forearms.r, forearms.l] {
            node.addChildNode(n)
        }

        standHipHeight = Self.solveStandingHipHeight(layout: L)
    }

    /// Hides the head, helmet and glasses (for a camera inside the head).
    func setHeadVisible(_ visible: Bool) {
        head.isHidden = !visible
        neck.isHidden = !visible
    }

    /// The rider's share of the sky light, from the route's sky visibility
    /// `v` (`LightProfile`, measured 0.3 m above the road): in a sunken lane
    /// the rider loses sky light as the road does, or the lane exposure
    /// would make him glow. The body, 1-1.5 m up, sees more of the sky than
    /// the road (`v`^0.6), and never less than the road's floor for the
    /// bounce light (`WorldMaterials.skyFloor`). Eased over a quarter of a
    /// second; written only when it moves by a hundredth. Render thread.
    func setSkyVisibility(_ v: Float, floor: Float, deltaTime: Double) {
        let target = max(pow(min(max(v, 0), 1), 0.6), floor)
        sky = firstSky ? target : approach(sky, target, Float(min(max(deltaTime, 0), 0.1)), 0.25)
        if abs(target - sky) < 0.005 { sky = target }
        firstSky = false
        guard abs(sky - appliedSky) > 0.01 || (sky == target && sky != appliedSky) else { return }
        appliedSky = sky
        let value = NSNumber(value: sky)
        for m in skyMaterials { m.setValue(value, forKey: "riderSky") }
    }

    // MARK: - Per frame

    /// Called every frame on the render thread.
    func update(pose: RoutePose, snapshot: RideSnapshot, deltaTime: Double) {
        node.simdTransform = pose.transform
        let L = layout
        let first = firstFrame
        firstFrame = false
        let dt = first ? 0 : Float(min(max(deltaTime, 0), 0.1))
        let running = snapshot.isRunning
        let speed = running ? Float(max(snapshot.speedMps, 0)) : 0
        let cadence = running ? Float(max(snapshot.cadenceRpm, 0)) : 0

        gradeS = first ? Float(pose.gradePct) : approach(gradeS, Float(pose.gradePct), dt, 0.8)
        let rough = roughness.indices.contains(pose.surfaceIndex) ? roughness[pose.surfaceIndex] : 0.07
        roughS = first ? rough : approach(roughS, rough, dt, 0.25)
        travel += Double(speed * dt)

        // MARK: Posture
        let wantPark = speed < 0.25 && cadence < 3
        parkHold = wantPark ? parkHold + dt : 0
        parked = wantPark && (parked || parkHold > 0.4 || first)
        parkRamp = first ? (parked ? 1 : 0) : ramp(parkRamp, parked ? 1 : 0, dt, parked ? 0.9 : 1.8)

        let omega = cadence / 60 * 2 * .pi
        let torque = omega > 0.5 ? Float(snapshot.powerW) / omega : 0
        let steep = gradeS
        let wantStand = !parked && speed > 0.6 && cadence > 25
            && ((steep > 14 && (cadence < 70 || torque > 40)) || (steep > 17.5 && cadence < 90))
        standHold = wantStand != standing ? standHold + dt : 0
        if first || standHold > (standing ? 1.2 : 0.5) {
            standing = wantStand
            standHold = 0
        }
        standRamp = first ? (standing ? 1 : 0) : ramp(standRamp, standing ? 1 : 0, dt, 1.4)
        let parkW = M.smoothstep(0, 1, parkRamp)
        let standW = M.smoothstep(0, 1, standRamp) * (1 - parkW)
        let seatW = max(0, 1 - standW - parkW)
        let climb = M.smoothstep(3, 14, steep)

        // MARK: Cranks, wheels, chain
        let previousCrank = crankAngle
        let targetRate = cadence > 1 && !parked ? omega : 0
        if targetRate > 0 {
            crankRate = first ? targetRate : approach(crankRate, targetRate, dt, 0.3)
        } else {
            crankRate = approach(crankRate, 0, dt, 0.3)
            if abs(crankRate) < 1.2 {
                // Coasting riders level the pedals; stopped, the right foot
                // waits at two o'clock ready to push off.
                let rest: Float
                if parked || parkRamp > 0 {
                    rest = 0.96
                } else {
                    rest = abs(wrapPi(.pi / 2 - crankAngle)) < abs(wrapPi(3 * .pi / 2 - crankAngle)) ? .pi / 2 : 3 * .pi / 2
                }
                let delta = wrapPi(rest - crankAngle)
                crankAngle += first ? delta : delta * (1 - exp(-dt / 0.35))
            }
        }
        crankAngle += crankRate * dt
        crankAngle = crankAngle.truncatingRemainder(dividingBy: 2 * .pi)
        if crankAngle < 0 { crankAngle += 2 * .pi }
        chainShift += wrapPi(crankAngle - previousCrank) * G.bigRingPitchRadius / 0.0254
        chainShift = chainShift.truncatingRemainder(dividingBy: 1)
        wheelAngle = (wheelAngle + speed / G.wheelRadius * dt).truncatingRemainder(dividingBy: 2 * .pi)
        blur = first ? M.smoothstep(1.4, 4.2, speed) : approach(blur, M.smoothstep(1.4, 4.2, speed), dt, 0.25)

        // MARK: Bike pose: rocking out of the saddle, leaning when stopped, cobble shake
        let s1 = sin(crankAngle)
        let amp = roughS * min(speed / 6, 1.3)
        let vibY = amp * 0.0060 * (0.65 * noise(travel / 0.16) + 0.35 * noise(travel / 0.43 + 31.7))
        let vibRoll = amp * 0.008 * noise(travel / 0.37 + 7.1)
        let vibPitch = amp * 0.005 * noise(travel / 0.29 + 3.3)
        let rock = standW * 0.12 * sin(crankAngle - 0.25)
        let bikeRoll = rock + parkW * 0.105 + vibRoll
        let bikeX = M.translation(SIMD3(0, vibY, 0)) * M.rotZ(bikeRoll) * M.rotX(vibPitch)
        bikeRoot.simdTransform = bikeX

        frontWheel.simdTransform = M.translation(G.frontAxle) * M.rotX(-wheelAngle)
        rearWheel.simdTransform = M.translation(G.rearAxle) * M.rotX(-wheelAngle)
        crank.simdTransform = M.translation(G.bb) * M.rotX(-crankAngle)
        let spokeOpacity = CGFloat(1 - 0.8 * blur)
        frontSpokes.opacity = spokeOpacity
        rearSpokes.opacity = spokeOpacity
        frontBlur.opacity = CGFloat(blur)
        rearBlur.opacity = CGFloat(blur)
        frontBlur.isHidden = blur < 0.02
        rearBlur.isHidden = blur < 0.02
        chainMaterial.diffuse.contentsTransform = SCNMatrix4(M.translation(SIMD3(0, -chainShift, 0)))

        // MARK: Feet on the pedals (bike space), left foot to the ground when stopped
        let footR = pedalFoot(side: 1, standW: standW, parkW: parkW)
        let footLPedal = pedalFoot(side: -1, standW: standW, parkW: 0)
        pedalRight.simdTransform = footR.pedal
        let unclip = M.smoothstep(0.1, 0.85, parkW)
        pedalLeft.simdTransform = unclip > 0.5
            ? M.translation(footLPedal.pedal.columns.3.vec3) * M.rotX(0.22)
            : footLPedal.pedal
        let footRRig = bikeX * footR.foot
        var footLRig = bikeX * footLPedal.foot
        if unclip > 0 {
            let ground = M.translation(SIMD3(-0.30, 0.082, G.zBB - 0.03)) * M.rotY(0.16)
            footLRig = blend(footLRig, ground, unclip, lift: 0.07 * sin(.pi * unclip))
        }

        // MARK: Pelvis
        let seatHip = (bikeX * SIMD4(G.p(-0.200 + 0.022 * climb, 1.050 - 0.004 * climb), 1)).vec3
        let standHip = (M.rotZ(0.15 * bikeRoll) * SIMD4(G.p(Self.standHipF, standHipHeight - 0.014 * abs(s1), 0.010 * s1), 1)).vec3
        let parkHip = G.p(-0.045, 0.915, -0.065)
        var hip = seatHip * seatW + standHip * standW + parkHip * parkW
        let tilt = 0.454 * seatW + 0.50 * standW + 0.14 * parkW
        let pelvisRoll = (bikeRoll - 0.02 * s1) * seatW + (0.15 * bikeRoll - 0.07 * s1) * standW - 0.05 * parkW
        let pelvisYaw = 0.015 * s1 * seatW + 0.05 * s1 * standW
        let pelvisRot = M.rotZ(pelvisRoll) * M.rotY(pelvisYaw) * M.rotX(-tilt)

        // Never over-extend a leg: if a pedal is out of reach, the hips drop
        // toward it (the natural hip rock) instead of the foot leaving it.
        let ankleR = footRRig.columns.3.vec3, ankleL = footLRig.columns.3.vec3
        let reach = 0.985 * (L.thighLength + L.shankLength)
        for _ in 0..<2 {
            let hr = hip + (pelvisRot * SIMD4(L.hipHalfWidth, 0, 0, 0)).vec3
            let hl = hip + (pelvisRot * SIMD4(-L.hipHalfWidth, 0, 0, 0)).vec3
            let er = distance(ankleR, hr) - reach, el = distance(ankleL, hl) - reach
            if er <= 0 && el <= 0 { break }
            if er > el {
                hip += normalize(ankleR - hr) * er
            } else {
                hip += normalize(ankleL - hl) * el
            }
        }
        let pelvisM = M.translation(hip) * pelvisRot
        pelvis.simdTransform = pelvisM

        // MARK: Legs
        let bodyRoll = bikeRoll * seatW + 0.15 * bikeRoll * standW
        let bodyRot = M.rotZ(bodyRoll)
        leg(side: 1, pelvis: pelvisM, foot: footRRig, bodyRot: bodyRot, thigh: thighs.r, shank: shanks.r, footNode: feet.r)
        leg(side: -1, pelvis: pelvisM, foot: footLRig, bodyRot: bodyRot, thigh: thighs.l, shank: shanks.l, footNode: feet.l)

        // MARK: Torso: a target lean (further forward as the road steepens),
        // limited so the arms reach the hoods with the elbows between
        // slightly and well bent.
        let waist = (pelvisM * SIMD4(L.waist, 1)).vec3
        let wristR = (bikeX * SIMD4(G.wrist(1), 1)).vec3, wristL = (bikeX * SIMD4(G.wrist(-1), 1)).vec3
        let slope = atan(max(steep, 0) / 100)
        let lean = (0.716 - 0.30 * slope) * seatW + (0.560 - 0.50 * slope) * standW + 0.960 * parkW
        let inv = bodyRot.transpose
        let wl = (inv * SIMD4(waist, 1)).vec3, ml = (inv * SIMD4((wristR + wristL) / 2, 1)).vec3
        let dx = abs(G.wrist(1).x) - L.shoulder.x
        let w2 = SIMD2(-wl.z, wl.y), m2 = SIMD2(-ml.z, ml.y)
        var s2 = w2 + SIMD2(cos(lean), sin(lean)) * L.shoulder.y
        let armMax = (0.552 * 0.552 - dx * dx).squareRoot(), armMin = (0.405 * 0.405 - dx * dx).squareRoot()
        let reachNow = distance(s2, m2)
        if reachNow > armMax {
            s2 = nearestIntersection(w2, L.shoulder.y, m2, armMax, near: s2)
        } else if reachNow < armMin {
            s2 = nearestIntersection(w2, L.shoulder.y, m2, armMin, near: s2)
        }
        let shoulderMid = (bodyRot * SIMD4(wl.x, s2.y, -s2.x, 1)).vec3
        let twist = 0.05 * s1 * standW + 0.01 * s1 * seatW
        let torsoM = frame(origin: waist, y: shoulderMid - waist, xHint: (bodyRot * SIMD4(1, 0, 0, 0)).vec3) * M.rotY(twist)
        torso.simdTransform = torsoM

        // MARK: Arms
        // Elbows point out and back; tucked in a little more when standing.
        let elbowOut = 0.75 - 0.30 * standW, elbowBack = 0.35 + 0.30 * standW
        arm(side: 1, torso: torsoM, wrist: wristR, bodyRot: bodyRot, elbow: SIMD2(elbowOut, elbowBack), upper: upperArms.r, fore: forearms.r)
        arm(side: -1, torso: torsoM, wrist: wristL, bodyRot: bodyRot, elbow: SIMD2(elbowOut, elbowBack), upper: upperArms.l, fore: forearms.l)

        // MARK: Neck and head, eyes up the road
        let neckBase = (torsoM * SIMD4(L.neckBase, 1)).vec3
        let ty = torsoM.columns.1.vec3, tz = torsoM.columns.2.vec3
        let ext: Float = 0.36 - 0.10 * parkW
        let atlas = neckBase + normalize(ty * cos(ext) + tz * sin(ext)) * L.neckLength
        let headRot = M.rotZ(bodyRoll * 0.3)
        let nod: Float = amp * 0.01 * noise(travel / 0.8 + 5.5)
        let gazeDown: Float = 0.16 + 0.05 * standW - 0.08 * parkW + nod
        let gaze = (headRot * SIMD4(0, -sin(gazeDown), -cos(gazeDown), 0)).vec3
        let headM = frame(origin: atlas, zAxis: -gaze, yHint: (headRot * SIMD4(0, 1, 0, 0)).vec3)
        head.simdTransform = headM
        neck.simdTransform = frame(origin: neckBase, y: neckBase - atlas, zHint: tz)
    }

    // MARK: - Pose helpers

    /// Pedal node and attached foot (ankle frame) in bike space.
    private func pedalFoot(side s: Float, standW: Float, parkW: Float) -> (pedal: simd_float4x4, foot: simd_float4x4) {
        let phi = crankAngle + (s > 0 ? 0 : .pi)
        let L = G.crankLength
        let spindle = G.bb + SIMD3(s * G.pedalLateral, L * cos(phi), -L * sin(phi))
        // Ankling: heel drops through the power phase, toes point down on the upstroke.
        let seated = (14 + 9 * cos(phi - 250 * .pi / 180)) * .pi / 180
        let standingPitch = (20 + 10 * cos(phi - 235 * .pi / 180)) * .pi / 180
        var pitch = seated + (standingPitch - seated) * standW
        pitch += (0.14 - pitch) * parkW
        let pedal = M.translation(spindle) * M.rotX(-pitch)
        let foot = pedal * M.rotY(-s * 0.06) * M.translation(layout.ankleFromSpindle)
        return (pedal, foot)
    }

    private func leg(side s: Float, pelvis: simd_float4x4, foot: simd_float4x4, bodyRot: simd_float4x4,
                     thigh: SCNNode, shank: SCNNode, footNode: SCNNode) {
        let L = layout
        let hip = (pelvis * SIMD4(s * L.hipHalfWidth, 0, 0, 1)).vec3
        let pole = normalize((bodyRot * SIMD4(s * 0.10, 0.25, -1, 0)).vec3)
        let ik = twoBone(root: hip, target: foot.columns.3.vec3, a: L.thighLength, b: L.shankLength, pole: pole)
        thigh.simdTransform = frame(origin: hip, y: hip - ik.mid, zHint: -pole)
        shank.simdTransform = frame(origin: ik.mid, y: ik.mid - ik.end, zHint: -pole)
        var f = foot
        f.columns.3 = SIMD4(ik.end, 1)
        footNode.simdTransform = f
    }

    private func arm(side s: Float, torso: simd_float4x4, wrist: SIMD3<Float>, bodyRot: simd_float4x4, elbow: SIMD2<Float>,
                     upper: SCNNode, fore: SCNNode) {
        let L = layout
        let shoulder = (torso * SIMD4(s * L.shoulder.x, L.shoulder.y, L.shoulder.z, 1)).vec3
        let pole = normalize((bodyRot * SIMD4(s * elbow.x, -0.5, elbow.y, 0)).vec3)
        let ik = twoBone(root: shoulder, target: wrist, a: L.upperArmLength, b: L.forearmLength, pole: pole)
        upper.simdTransform = frame(origin: shoulder, y: shoulder - ik.mid, zHint: pole)
        fore.simdTransform = frame(origin: ik.mid, y: ik.mid - ik.end, zHint: (bodyRot * SIMD4(s, 0.25, 0, 0)).vec3)
    }

    /// Analytic two-bone IK: the middle joint bends toward `pole`.
    private func twoBone(root: SIMD3<Float>, target: SIMD3<Float>, a: Float, b: Float, pole: SIMD3<Float>) -> (mid: SIMD3<Float>, end: SIMD3<Float>) {
        let d = target - root
        let len = length(d)
        let u = len > 1e-6 ? d / len : SIMD3<Float>(0, -1, 0)
        let dist = min(max(len, abs(a - b) + 1e-3), (a + b) * 0.9995)
        let cosA = min(max((a * a + dist * dist - b * b) / (2 * a * dist), -1), 1)
        let sinA = (1 - cosA * cosA).squareRoot()
        var v = pole - dot(pole, u) * u
        let vl = length(v)
        v = vl > 1e-6 ? v / vl : SIMD3<Float>(0, 0, -1)
        return (root + u * (a * cosA) + v * (a * sinA), root + u * dist)
    }

    /// The intersection of two circles (in a 2D forward/up plane) nearest
    /// `near`; if they don't meet, the point on the first toward the second.
    private func nearestIntersection(_ c0: SIMD2<Float>, _ r0: Float, _ c1: SIMD2<Float>, _ r1: Float, near: SIMD2<Float>) -> SIMD2<Float> {
        let d = c1 - c0
        let len = length(d)
        guard len > 1e-5 else { return near }
        let u = d / len
        if len >= r0 + r1 || len <= abs(r0 - r1) { return c0 + u * r0 }
        let a = (r0 * r0 - r1 * r1 + len * len) / (2 * len)
        let h = max(r0 * r0 - a * a, 0).squareRoot()
        let perp = SIMD2<Float>(-u.y, u.x)
        let p1 = c0 + u * a + perp * h, p2 = c0 + u * a - perp * h
        return distance(p1, near) <= distance(p2, near) ? p1 : p2
    }

    /// Segment frame: `y` exact, `z` as close to `zHint` as possible.
    private func frame(origin: SIMD3<Float>, y: SIMD3<Float>, zHint: SIMD3<Float>) -> simd_float4x4 {
        let yy = safeNormalize(y, SIMD3(0, 1, 0))
        let zz = safeNormalize(zHint - dot(zHint, yy) * yy, abs(yy.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0))
        let xx = cross(yy, zz)
        return simd_float4x4(columns: (SIMD4(xx, 0), SIMD4(yy, 0), SIMD4(zz, 0), SIMD4(origin, 1)))
    }

    private func frame(origin: SIMD3<Float>, y: SIMD3<Float>, xHint: SIMD3<Float>) -> simd_float4x4 {
        let yy = safeNormalize(y, SIMD3(0, 1, 0))
        let zz = safeNormalize(cross(xHint, yy), SIMD3(0, 0, 1))
        let xx = cross(yy, zz)
        return simd_float4x4(columns: (SIMD4(xx, 0), SIMD4(yy, 0), SIMD4(zz, 0), SIMD4(origin, 1)))
    }

    private func frame(origin: SIMD3<Float>, zAxis: SIMD3<Float>, yHint: SIMD3<Float>) -> simd_float4x4 {
        let zz = safeNormalize(zAxis, SIMD3(0, 0, 1))
        let yy = safeNormalize(yHint - dot(yHint, zz) * zz, SIMD3(0, 1, 0))
        let xx = cross(yy, zz)
        return simd_float4x4(columns: (SIMD4(xx, 0), SIMD4(yy, 0), SIMD4(zz, 0), SIMD4(origin, 1)))
    }

    /// Position lerp plus rotation slerp, with an upward arc.
    private func blend(_ a: simd_float4x4, _ b: simd_float4x4, _ t: Float, lift: Float) -> simd_float4x4 {
        let q = simd_slerp(simd_quatf(a), simd_quatf(b), t)
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4(simd_mix(a.columns.3.vec3, b.columns.3.vec3, SIMD3(repeating: t)) + SIMD3(0, lift, 0), 1)
        return m
    }

    @inline(__always)
    private func safeNormalize(_ v: SIMD3<Float>, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        let l = length(v)
        return l > 1e-6 ? v / l : fallback
    }

    @inline(__always)
    private func approach(_ x: Float, _ target: Float, _ dt: Float, _ tau: Float) -> Float {
        x + (target - x) * (1 - exp(-dt / tau))
    }

    @inline(__always)
    private func ramp(_ x: Float, _ target: Float, _ dt: Float, _ rate: Float) -> Float {
        x < target ? min(x + rate * dt, target) : max(x - rate * dt, target)
    }

    @inline(__always)
    private func wrapPi(_ a: Float) -> Float {
        var r = (a + .pi).truncatingRemainder(dividingBy: 2 * .pi)
        if r < 0 { r += 2 * .pi }
        return r - .pi
    }

    /// Smooth 1D value noise in [−1, 1].
    @inline(__always)
    private func noise(_ x: Double) -> Float {
        let fl = x.rounded(.down)
        let i = Int32(truncatingIfNeeded: Int64(fl))
        let f = Float(x - fl)
        let u = f * f * (3 - 2 * f)
        let a = hash(i), b = hash(i &+ 1)
        return a + (b - a) * u
    }

    @inline(__always)
    private func hash(_ i: Int32) -> Float {
        var x = UInt32(bitPattern: i) &* 0x27d4_eb2d
        x ^= x >> 15
        x = x &* 0x85eb_ca6b
        x ^= x >> 13
        return Float(x & 0xffff) / 32767.5 - 1
    }

    /// Hip height (above the road) out of the saddle such that the leg is
    /// 96.5 % extended at the bottom of the stroke.
    private static func solveStandingHipHeight(layout: RiderBodyLayout) -> Float {
        let full = layout.thighLength + layout.shankLength
        func maxReach(_ h: Float) -> Float {
            let hip = G.p(standHipF, h, layout.hipHalfWidth)
            var best: Float = 0
            for k in 0..<72 {
                let phi = Float(k) / 72 * 2 * .pi
                let spindle = G.bb + SIMD3(G.pedalLateral, G.crankLength * cos(phi), -G.crankLength * sin(phi))
                let pitch = (20 + 10 * cos(phi - 235 * .pi / 180)) * .pi / 180
                let ankle = (M.translation(spindle) * M.rotX(-pitch) * SIMD4(layout.ankleFromSpindle, 1)).vec3
                best = max(best, distance(hip, ankle))
            }
            return best
        }
        var lo: Float = 0.9, hi: Float = 1.25
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if maxReach(mid) > 0.965 * full { hi = mid } else { lo = mid }
        }
        return lo
    }
}

private extension SIMD4 where Scalar == Float {
    var vec3: SIMD3<Float> { SIMD3(x, y, z) }
}
