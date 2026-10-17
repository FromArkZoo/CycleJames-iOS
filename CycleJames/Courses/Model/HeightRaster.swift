import Foundation

/// A north-up grid of heights in metres, decoded from a `u16le_cm` file.
/// Row 0 is the north edge, column 0 the west edge; the header origin is the
/// north-west corner of cell (0,0). No-data cells decode to `nan`.
struct HeightRaster: Sendable {
    let cols: Int
    let rows: Int
    let cellM: Double
    let originEast: Double
    let originNorth: Double
    /// Row-major, `rows * cols` values.
    let values: [Float]

    var widthM: Double { Double(cols) * cellM }
    var heightM: Double { Double(rows) * cellM }
    var minEast: Double { originEast }
    var maxEast: Double { originEast + widthM }
    var maxNorth: Double { originNorth }
    var minNorth: Double { originNorth - heightM }

    init(cols: Int, rows: Int, cellM: Double, originEast: Double, originNorth: Double, values: [Float]) {
        precondition(values.count == cols * rows, "raster value count does not match dimensions")
        self.cols = cols
        self.rows = rows
        self.cellM = cellM
        self.originEast = originEast
        self.originNorth = originNorth
        self.values = values
    }

    static func load(from url: URL, header: CourseFile.RasterHeader) throws -> HeightRaster {
        guard header.encoding == "u16le_cm" else {
            throw CourseDataError.badRaster("unsupported encoding \(header.encoding) in \(header.file)")
        }
        guard header.cols > 0, header.rows > 0, header.cellM > 0 else {
            throw CourseDataError.badRaster("bad dimensions in \(header.file)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw CourseDataError.missingFile(header.file)
        }
        let count = header.cols * header.rows
        guard data.count == count * 2 else {
            throw CourseDataError.badRaster("\(header.file) is \(data.count) bytes, expected \(count * 2)")
        }
        let base = Float(header.baseM)
        var values = [Float](repeating: .nan, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let lo = UInt16(raw[2 * i])
                let hi = UInt16(raw[2 * i + 1])
                let v = lo | (hi << 8)
                if v != 0xFFFF {
                    values[i] = base + Float(v) / 100
                }
            }
        }
        return HeightRaster(
            cols: header.cols, rows: header.rows, cellM: header.cellM,
            originEast: header.originEast, originNorth: header.originNorth,
            values: values
        )
    }

    @inline(__always)
    func value(row: Int, col: Int) -> Float {
        let r = min(max(row, 0), rows - 1)
        let c = min(max(col, 0), cols - 1)
        return values[r * cols + c]
    }

    func contains(east: Double, north: Double) -> Bool {
        east >= minEast && east <= maxEast && north >= minNorth && north <= maxNorth
    }

    /// Fractional (col, row) of a local point, in cell-centre space.
    @inline(__always)
    func gridPosition(east: Double, north: Double) -> (col: Double, row: Double) {
        ((east - originEast) / cellM - 0.5, (originNorth - north) / cellM - 0.5)
    }

    /// Bilinear sample, clamped to the grid edge. Falls back to the nearest
    /// valid neighbour when some of the four cells are no-data.
    func sample(east: Double, north: Double) -> Float {
        let (fc, fr) = gridPosition(east: east, north: north)
        let c0 = Int(floor(fc)), r0 = Int(floor(fr))
        let tx = Float(fc - Double(c0)), ty = Float(fr - Double(r0))
        let v00 = value(row: r0, col: c0)
        let v10 = value(row: r0, col: c0 + 1)
        let v01 = value(row: r0 + 1, col: c0)
        let v11 = value(row: r0 + 1, col: c0 + 1)
        if !v00.isNaN, !v10.isNaN, !v01.isNaN, !v11.isNaN {
            let top = v00 + (v10 - v00) * tx
            let bottom = v01 + (v11 - v01) * tx
            return top + (bottom - top) * ty
        }
        let nearest: [(Float, Float)] = [
            (v00, (1 - tx) * (1 - ty)), (v10, tx * (1 - ty)),
            (v01, (1 - tx) * ty), (v11, tx * ty),
        ]
        return nearest.filter { !$0.0.isNaN }.max { $0.1 < $1.1 }?.0 ?? .nan
    }
}
