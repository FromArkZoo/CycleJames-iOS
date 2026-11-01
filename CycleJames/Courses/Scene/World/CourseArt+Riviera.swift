import Foundation

/// The Riviera's roadside, as `CourseArt` describes it: the walls at the
/// carriageway edge, the railings and fences, and the street furniture
/// (`BuildingBuilder.buildRivieraRoadside` builds them). Every Flemish
/// climb leaves them empty.
extension CourseArt {
    /// A wall at the carriageway edge: a retaining wall holding up the bank
    /// on the uphill side (its top follows the bank, within `height`), or a
    /// parapet standing `height` above the road.
    struct Masonry: Sendable {
        var span: Span
        var side: Double
        /// A retaining wall's least and most height above the road; a
        /// parapet's height is the upper bound.
        var height: ClosedRange<Double>
        var look: Stone
        /// Its road face beyond the carriageway edge: 0.14 m keeps it on the
        /// verge's first column, still at road level (`RoadBuilder`), so
        /// the verge never climbs its foot.
        var offset: Double = 0.14
        /// Holds up the bank behind it; a parapet (false) stands free, with
        /// a back face.
        var retains: Bool = true
        /// A grey concrete coping along its top (look.md section 3: paint
        /// #8f8c84).
        var coping: Bool = true
        /// What stands on it.
        var top: Railing? = nil
        /// Dry-stone terraces (fasce) stepping up the bank behind it, so many
        /// tiers about a metre high, where the photos show them and the
        /// CTR has none (`BuildingBuilder.buildFasce`).
        var terraces: Int = 0

        var thickness: Double { retains ? 0.55 : 0.3 }
    }

    /// The stones and finishes `WorldShaders.masonrySurface` draws; the raw
    /// value is the code it reads. Paints from look.md section 3.
    enum Stone: Int, Sendable, CaseIterable {
        /// The SP55's signature: honey sandstone, rough-squared blocks
        /// 20-60 cm long in loose courses 15-30 cm high, recessed dark
        /// joints, weeds in some (#bba984, #a8936c, #8a7d68, #a07a55; joints
        /// #4f4535).
        case honeyRubble = 0
        /// Newer, regular grey squared stone on the hairpins' outsides and
        /// behind the summit car park (#b4ab9b).
        case greySquared
        /// Dry-stone terraces (fasce): grey-ochre stone, open joints, a
        /// grassy top.
        case dryStone
        /// Concrete coping (#8f8c84).
        case coping
        /// Cast concrete: sea-side parapets (#b5b2aa).
        case concrete
        /// Grey precast blocks (hairpin 3).
        case precastBlocks
        /// Beige-rendered concrete with damp streaks (#c9bca2, #8a8070).
        case render
        /// The long dark-grey wall below the top (#6e6b64).
        case darkGrey
        /// Low mixed grey rubble (the summit car park's wall, #54514a-#918a7e).
        case greyRubble
        /// A reed screen, cannicciato (#6b5a43, strands #4a3e30).
        case reeds
        /// Rusty corrugated sheet (#9a6a3e to #6b4a30).
        case rustSheet
        /// Grey gneiss slabs in running bond (Piazza della Libertà, 2026: #a9aca6).
        case gneiss
        /// Red brick (the summit planter).
        case brick
        /// White render (the sculpture's plinth, gate pillars).
        case whiteRender
    }

    /// Railings, fences and screens, on a wall's top or on the verge.
    enum Railing: Sendable, Equatable {
        /// Galvanised tube, two rails on posts (the viewpoint lay-bys).
        case tubular
        /// A galvanised balustrade: top rail and vertical bars (the
        /// Aurelia's pavement, the parapet at look s 1840).
        case bars
        /// The same balustrade painted blue (the parapet over the sea at
        /// look s 1762-1912: the 2024 frame at 1840 m).
        case paintedBars
        /// Black steel bars and a top rail (the start ramp's wall).
        case blackBars
        /// Black wrought-iron spears between flats, with square pillars
        /// every few metres when `pillars` (villa frontages).
        case spear(pillars: Bool)
        /// Chain-link on posts, galvanised or green plastic-coated.
        case chainLink(green: Bool)
        /// Chain-link carrying dark-green shade netting (#33473a): the
        /// greenhouse plots. On a retaining wall it stands on the bank
        /// behind the crest.
        case shadeNet
        /// A reed screen, 2-2.5 m.
        case reedScreen
        /// Rusty corrugated sheets on timber posts.
        case corrugated
        /// A rusty red-brown steel railing.
        case rusty

        /// Its height above its foot, metres.
        var height: Double {
            switch self {
            case .tubular: 1.0
            case .bars, .paintedBars: 1.05
            case .blackBars: 1.1
            case .spear: 1.4
            case .chainLink: 1.6
            case .shadeNet: 1.8
            case .reedScreen: 2.2
            case .corrugated: 1.8
            case .rusty: 1.0
            }
        }
    }

    /// The Riviera's street furniture (`Furniture.Kind.riviera`).
    enum RivieraProp: Sendable {
        /// White and red concrete jersey blocks in a row.
        case jerseyBlocks(Int)
        /// A flower grower's old white van, nose to the road.
        case van
        /// The brick-and-concrete planter at the summit corner's tip.
        case planter
        /// The 2026 sculpture: three stylised riders in corten on a white
        /// wedge plinth, its inscriptions on the long faces.
        case riderSculpture
        /// A paved piazza: grey gneiss slabs edged in white marble, `width`
        /// along the road and `depth` back from the furniture's point.
        case piazza(width: Double, depth: Double)
        /// A dark timber bench on white blocks (the 2026 piazza).
        case bench
        /// Round concrete bollards in a row, 1.2 m apart.
        case bollards(Int)
        /// The red and silver Telecom phone box with its mast sign, removed
        /// in 2023/24: built only with the DEBUG launch argument
        /// `-poggioPhoneBox`.
        case phoneBox
        /// Sanremo's green, brown and blue wheelie bins.
        case wheelieBins
        /// A galvanised pole with a camera and a loudspeaker.
        case cctvPole
        /// Two square rendered gate pillars with caps, `gap` apart, and a
        /// black iron gate between them.
        case gatePillars(gap: Double)
        /// A dark-grey cast-iron lamp post with a lantern (the 2026 piazza).
        case castIronLamp
    }

    /// Whether the course carries anything `buildRivieraRoadside` builds.
    var hasRivieraRoadside: Bool {
        !masonry.isEmpty || !guardrails.isEmpty || !railings.isEmpty || !paintedWords.isEmpty || !chevrons.isEmpty
            || !trolleyWires.isEmpty || !placed.isEmpty
            || furniture.contains { if case .riviera = $0.kind { true } else { false } }
    }

    #if DEBUG
    /// `-courseLook riviera` on a course without a Riviera roadside: a
    /// sample of every piece along its climb, to judge the look on a
    /// familiar road. Not for any shipped course.
    mutating func addRivieraSample(climb: ClosedRange<Double>, length: Double) {
        guard !hasRivieraRoadside else { return }
        let a = climb.lowerBound, l = max(climb.upperBound - a, 200)
        func at(_ f: Double) -> Double { min(max(a + l * f, 1), length - 1) }
        func span(_ f0: Double, _ f1: Double) -> Span { at(f0)...at(f1) }
        // Clear the Flemish pieces this sample stands in for.
        walls = []; stoneWalls = []; fences = []; rails = []; palings = []; hedges = []; kerbs = []
        masonry = [
            Masonry(span: span(-0.2, 0.25), side: 1, height: 3.0...5.5, look: .honeyRubble, top: .blackBars),
            Masonry(span: span(0.25, 0.4), side: 1, height: 1.2...3.0, look: .honeyRubble, top: .shadeNet),
            Masonry(span: span(0.4, 0.5), side: 1, height: 0.5...0.6, look: .honeyRubble, retains: false, top: .reedScreen),
            Masonry(span: span(0.5, 0.62), side: 1, height: 2.0...4.0, look: .greySquared),
            Masonry(span: span(0.62, 0.75), side: 1, height: 2.0...3.5, look: .render, coping: false),
            Masonry(span: span(0.75, 0.95), side: 1, height: 1.0...2.5, look: .precastBlocks),
            Masonry(span: span(0.05, 0.3), side: -1, height: 0.75...0.75, look: .concrete, retains: false,
                    coping: false, top: .tubular),
            Masonry(span: span(0.45, 0.62), side: -1, height: 0.6...0.6, look: .greyRubble, retains: false, top: .spear(pillars: true)),
            Masonry(span: span(0.66, 0.9), side: -1, height: 2.0...3.0, look: .darkGrey, coping: false),
        ]
        guardrails = [(span(-0.25, 0.05), -1, 0.5), (span(0.3, 0.44), -1, 0.5)]
        railings = [(span(0.9, 1.0), -1, 0.8, .chainLink(green: true)), (span(0.95, 1.05), 1, 0.6, .corrugated)]
        paintedWords = [(at(0.78), -1, "IL POGGIO", 1.2)]
        chevrons = [(at(0.55), 1, true), (at(0.57), 1, true)]
        trolleyWires = [max(0, a - 250)...max(a - 10, 20)]
        lamps = [(span(-0.2, 1.0), 45, 1, .galvanisedLED)]
        poles = [(span(0.0, 1.0), 38, -1, .woodBundle)]
        gutters = [(span(-0.2, 0.62), 1, 0.45)]
        signs = [
            SignPost(s: at(-0.15), side: -1, offset: 1.0, plates: ["it.dir.sp55.baiardo", "it.dir.sp55.ceriana", "it.dir.sp55.poggio"]),
            SignPost(s: at(0.1), side: 1, offset: 0.8, plates: ["it.tri.doublecurve.right"]),
            SignPost(s: at(0.35), side: -1, offset: 1.0, plates: ["it.mirror"], turn: -40),
            SignPost(s: at(0.6), side: 1, offset: 0.8, plates: ["it.c.3_5t"]),
            SignPost(s: at(0.85), side: 1, offset: 1.0, plates: ["it.place.poggio"]),
        ]
        furniture = [
            Furniture(kind: .riviera(.jerseyBlocks(4)), s: at(0.3), side: -1, offset: 1.0),
            Furniture(kind: .riviera(.van), s: at(0.36), side: -1, offset: 1.4),
            Furniture(kind: .riviera(.gatePillars(gap: 3.2)), s: at(0.54), side: -1, offset: 0.2),
            Furniture(kind: .riviera(.planter), s: at(0.97), side: -1, offset: 0.6),
            Furniture(kind: .riviera(.phoneBox), s: at(0.985), side: -1, offset: 1.6),
            Furniture(kind: .riviera(.piazza(width: 16, depth: 10)), s: at(1.0), side: 1, offset: 1.0),
            Furniture(kind: .riviera(.riderSculpture), s: at(1.0), side: 1, offset: 4.5, turn: 10),
            Furniture(kind: .riviera(.bench), s: at(1.0) + 5, side: 1, offset: 3.0),
            Furniture(kind: .riviera(.bollards(4)), s: at(1.0) - 6, side: 1, offset: 0.5),
            Furniture(kind: .riviera(.wheelieBins), s: at(0.92), side: 1, offset: 0.8),
            Furniture(kind: .riviera(.cctvPole), s: at(0.99), side: -1, offset: 1.2),
        ]
    }
    #endif
}
