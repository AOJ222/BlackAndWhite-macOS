// make-icon.swift: draws the icon of "Black & White.app".
//
//   swiftc -O native/app/make-icon.swift -o /tmp/make-icon
//   /tmp/make-icon <folder>.iconset [--plain] [--art <logo-art.txt>] [--font <PostScript name>]
//   iconutil --convert icns --output AppIcon.icns <folder>.iconset
//
// build-app.py does these three steps. The picture is a macOS app-icon tile (824 of 1024 units, with
// the smooth corners Apple's own tile has) cut corner to corner into a black half (lower left) and a
// white half (upper right). Across the cut sits the game's logo: the dragon and the idol, and BLACK &
// WHITE in the game's lettering. The logo is drawn once, by inverting what is under it, so it is white
// on the black half and black on the white half with no seam where the halves meet; the dragon's eye is
// the one spot of colour. Edge light, a soft shadow on the white half, a faint glow on the black half,
// a glossy streak and a hairline of warm light along the cut give it depth.
//
// The logo is the game's own artwork, stored as curves in
// native/app/icon-art/logo-art.txt. That file is not tracked by git (see the README).
// Without it, or with --plain, the logo is replaced by one big ampersand from a system
// typeface and everything else is drawn the same.
//
// The picture is composed at twice the size of the biggest file, as planes of floating-point
// numbers, and averaged down to each size (the three smallest are sharpened a little, so the lettering
// survives), which keeps the smallest files as clean as the largest. The ten pictures an .iconset
// needs are written (16 to 512 points, each at 1x and 2x).
//
// Exit status 0 when the pictures are written, 1 with a message on stderr when they are not.

import CoreGraphics
import CoreText
import Foundation
import ImageIO

// ------------------------------------------------------------------------------------------ the design
// Lengths are in units of a 1024-unit picture; the drawing is SUPER pixels to the unit.
let DESIGN = 1024
let SUPER = 2
let N = DESIGN * SUPER                 // pixels each way while drawing
let U = Float(SUPER)                   // pixels to a unit
let ROOT2 = Float(2).squareRoot()

let TILE: Float = 824                  // the tile covers 824 of the 1024 units, as macOS app icons do; the rest is shadow
let TILE_RADIUS: Float = 215           // corner radius of the tile before it is smoothed
let TILE_SMOOTHING: Float = 0.7        // how far the corner eases into the straight edge (Apple's tile is not a plain rounded square)
let LOGO_HEIGHT: Float = 700           // the logo's height; it is centred, a touch low
let LOGO_DROP: Float = 2
let GLYPH_HEIGHT: Float = 540          // the ampersand of the plain icon

// Preferred first. A name this Mac lacks is skipped (CoreText would otherwise substitute a face
// without saying so).
let FONTS = ["Baskerville-Bold", "Georgia-Bold", "TimesNewRomanPS-BoldMT", "Times-Bold"]

typealias Colour = SIMD3<Float>
func hex(_ rgb: UInt32) -> Colour {
    Colour(Float((rgb >> 16) & 255) / 255, Float((rgb >> 8) & 255) / 255, Float(rgb & 255) / 255)
}
func clamped(_ c: Colour) -> Colour { c.clamped(lowerBound: Colour(repeating: 0), upperBound: Colour(repeating: 1)) }
func distance(_ c: Colour, from grey: Float) -> Colour { Colour(abs(c.x - grey), abs(c.y - grey), abs(c.z - grey)) }

let WHITE_NEAR = hex(0xE2DED3), WHITE_FAR = hex(0xFFFFFF)     // the white half, at the cut and in its far corner
let BLACK_NEAR = hex(0x2D2E35), BLACK_FAR = hex(0x040405)     // the black half
let AMBER = hex(0xFFAE45), AMBER_HOT = hex(0xFFE6B0)          // the dragon's eye
let HAIRLINE = hex(0xFFE0A0)                                  // the light along the cut
let COOL = hex(0xF2F5FF), WARM = hex(0xFFFAF2), GLOSS = hex(0xE8EEFF)

// What the logo does to the picture under it (see compose).
let EMBLEM_GREY: Float = 0.95          // the emblem inverts the ground against this grey, the lettering against white
let LETTER_GREY: Float = 1.0
let CONTRAST: Float = 1.10
let KNOCKOUT: Float = 2.8              // the emblem is cut away this far round the letters
let SHADOW: Float = 0.42               // the logo's shadow on the white half
let GLOW: Float = 0.07                 // and its glow on the black half
let GRAIN: Float = 0.016               // a little noise so the gradients do not band
let HAIR: Float = 0.7, BLOOM: Float = 0.07, STREAK: Float = 0.05
let SHEEN: Float = 0.045               // light from the top over the whole tile
let TILE_SHADOW: Float = 0.38

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("make-icon: " + message + "\n").utf8))
    exit(1)
}

// ------------------------------------------------------------------------------------------ planes
/// A picture's worth of numbers, one per drawing pixel, row 0 on top.
final class Plane {
    let p: UnsafeMutablePointer<Float>
    init(_ value: Float = 0) {
        p = UnsafeMutablePointer<Float>.allocate(capacity: N * N)
        p.initialize(repeating: value, count: N * N)
    }
    deinit { p.deallocate() }
}

/// Gaussian blur (sigma in pixels); the picture is zero outside its edge.
func blurred(_ a: Plane, sigma: Float) -> Plane {
    let r = Int((3 * sigma).rounded(.up))
    var kernel = (-r...r).map { exp(-0.5 * Float($0 * $0) / (sigma * sigma)) }
    let total = kernel.reduce(0, +)
    kernel = kernel.map { $0 / total }
    let across = Plane(), out = Plane()
    for y in 0..<N {
        let src = a.p + y * N, dst = across.p + y * N
        for j in -r...r {
            let w = kernel[j + r], lo = max(0, -j), hi = min(N, N - j)
            if lo < hi { for x in lo..<hi { dst[x] += w * src[x + j] } }
        }
    }
    for y in 0..<N {
        let dst = out.p + y * N
        for j in -r...r where y + j >= 0 && y + j < N {
            let w = kernel[j + r], src = across.p + (y + j) * N
            for x in 0..<N { dst[x] += w * src[x] }
        }
    }
    return out
}

/// The picture moved right by `dx` and down by `dy` pixels (fractions allowed), zero where nothing comes from.
func shifted(_ a: Plane, dx: Float, dy: Float) -> Plane {
    let ix = Int(dx.rounded(.down)), iy = Int(dy.rounded(.down))
    let fx = dx - Float(ix), fy = dy - Float(iy)
    let out = Plane()
    for y in 0..<N {
        let dst = out.p + y * N
        for b in 0...1 {
            let sy = y - iy - 1 + b
            if sy < 0 || sy >= N { continue }
            let wy = b == 0 ? fy : 1 - fy, src = a.p + sy * N
            for c in 0...1 {
                let wx = c == 0 ? fx : 1 - fx, shift = ix + 1 - c     // source x = x - shift
                let lo = max(0, shift), hi = min(N, N + shift)
                if lo < hi && wx * wy != 0 { for x in lo..<hi { dst[x] += wx * wy * src[x - shift] } }
            }
        }
    }
    return out
}

func clamped(_ x: Float, _ lo: Float = 0, _ hi: Float = 1) -> Float { min(max(x, lo), hi) }

func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = clamped((x - a) / (b - a))
    return t * t * (3 - 2 * t)
}

/// Where a shape's edge faces the light (up and to the left): `lit` is a rim along those edges, `dark` the
/// rim along the opposite ones. The rims are `dx`, `dy` units wide.
func edgeLight(_ mask: Plane, dx: Float, dy: Float) -> (lit: Plane, dark: Plane) {
    let down = shifted(mask, dx: dx * U, dy: dy * U), up = shifted(mask, dx: -dx * U, dy: -dy * U)
    let lit = Plane(), dark = Plane()
    for i in 0..<N * N {
        lit.p[i] = clamped(mask.p[i] - down.p[i])
        dark.p[i] = clamped(mask.p[i] - up.p[i])
    }
    return (lit, dark)
}

// ------------------------------------------------------------------------------------------ shapes
func radians(_ degrees: Double) -> Double { degrees * Double.pi / 180 }

/// The tile: a square `TILE` units across whose corners ease in over a longer run than a plain round
/// corner does (what design tools call corner smoothing, and what Apple's own tile has). Each corner is
/// three cubic curves: an easing curve, a short circular arc, and an easing curve back to the next edge.
func tilePath() -> CGPath {
    let w = Double(TILE * U), r = Double(TILE_RADIUS * U), budget = w / 2
    let run = min((1 + Double(TILE_SMOOTHING)) * r, budget)          // how far from the corner the easing starts
    let s = min(Double(TILE_SMOOTHING), budget / r - 1)
    let arc = 90 * (1 - s)                                             // degrees of true circle left in the corner
    let arcChord = sin(radians(arc / 2)) * r * 2.0.squareRoot()        // the arc's reach along each axis
    let p3p4 = r * tan(radians((90 - arc) / 4))
    let beta = 45 * s
    let c = p3p4 * cos(radians(beta)), d = c * tan(radians(beta))
    let b = (run - arcChord - c - d) / 3, a = 2 * b
    let k = 4.0 / 3.0 * tan(radians(arc) / 4) * r                      // handle length of a cubic that draws the arc

    // The top right corner in a box that runs 0...w each way: from the top edge to the right edge.
    let p0 = CGPoint(x: w - run, y: 0)
    let p3 = CGPoint(x: p0.x + a + b + c, y: d)
    let q = CGPoint(x: p3.x + arcChord, y: p3.y + arcChord)
    let into = (x: c / hypot(c, d), y: d / hypot(c, d)), outof = (x: d / hypot(c, d), y: c / hypot(c, d))
    let corner: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: p0.x + a, y: 0), CGPoint(x: p0.x + a + b, y: 0), p3),
        (CGPoint(x: p3.x + into.x * k, y: p3.y + into.y * k), CGPoint(x: q.x - outof.x * k, y: q.y - outof.y * k), q),
        (CGPoint(x: q.x + d, y: q.y + c), CGPoint(x: q.x + d, y: q.y + b + c), CGPoint(x: q.x + d, y: q.y + a + b + c)),
    ]
    let centre = CGFloat(N) / 2, origin = centre - CGFloat(w / 2)
    func turn(_ pt: CGPoint, _ quarter: Int) -> CGPoint {              // a quarter turn clockwise about the box's middle
        var x = pt.x - CGFloat(w / 2), y = pt.y - CGFloat(w / 2)
        for _ in 0..<quarter { (x, y) = (-y, x) }
        return CGPoint(x: origin + CGFloat(w / 2) + x, y: origin + CGFloat(w / 2) + y)
    }
    let path = CGMutablePath()
    for quarter in 0..<4 {
        if quarter == 0 { path.move(to: turn(p0, 0)) } else { path.addLine(to: turn(p0, quarter)) }
        for (c1, c2, end) in corner {
            path.addCurve(to: turn(end, quarter), control1: turn(c1, quarter), control2: turn(c2, quarter))
        }
    }
    path.closeSubpath()
    return path
}

/// Fills shapes white on black at drawing size and returns how much of each pixel they cover. The drawing
/// has y downwards, like the rows of the picture.
func coverage(_ path: CGPath?) -> Plane {
    let plane = Plane()
    guard let path = path, !path.isEmpty else { return plane }
    guard let ctx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: N,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
        fail("cannot make a \(N) pixel drawing")
    }
    ctx.setShouldAntialias(true)
    ctx.translateBy(x: 0, y: CGFloat(N))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.addPath(path)
    ctx.fillPath(using: .evenOdd)
    guard let data = ctx.data else { fail("cannot read back a \(N) pixel drawing") }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    for i in 0..<N * N { plane.p[i] = Float(bytes[i]) / 255 }
    return plane
}

// ------------------------------------------------------------------------------------------ the logo
/// The traced logo: shapes in units centred on the middle of the logo's box, y downwards.
struct Art {
    var box = CGRect.zero
    var groups: [String: CGMutablePath] = [:]
}

func loadArt(_ url: URL) -> Art {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { fail("cannot read \(url.path)") }
    var art = Art(), group: CGMutablePath?, current: CGPoint?
    for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let field = line.split(separator: " ").map(String.init)
        func bad(_ why: String) -> Never { fail("\(url.path), line \(number + 1): \(why)") }
        if field[0] == "group" {
            guard field.count == 2, ["emblem", "wordmark", "eye"].contains(field[1]) else { bad("cannot read \"\(line)\"") }
            group = CGMutablePath()
            art.groups[field[1]] = group
            current = nil
            continue
        }
        let values = field.dropFirst().compactMap { Double($0) }
        guard values.count == field.count - 1 else { bad("a number is expected after \(field[0])") }
        switch (field[0], values.count) {
        case ("box", 4):
            art.box = CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
        case ("M", 2):
            guard let g = group else { bad("a shape outside a group") }
            current = CGPoint(x: values[0], y: values[1])
            g.move(to: current!)
        case ("C", 6) where current != nil:
            current = CGPoint(x: values[4], y: values[5])
            group!.addCurve(to: current!, control1: CGPoint(x: values[0], y: values[1]), control2: CGPoint(x: values[2], y: values[3]))
        case ("Z", 0) where group != nil:
            group!.closeSubpath()
            current = nil
        default:
            bad("cannot read \"\(line)\"")
        }
    }
    guard !art.box.isEmpty, art.groups["emblem"] != nil, art.groups["wordmark"] != nil else {
        fail("\(url.path) has no box, emblem or wordmark")
    }
    return art
}

/// Moves traced shapes to where the logo sits on the drawing.
func place(_ path: CGPath?, box: CGRect) -> CGPath? {
    guard let path = path else { return nil }
    let k = CGFloat(LOGO_HEIGHT * U) / box.height
    var move = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: CGFloat(N) / 2, ty: CGFloat(N) / 2 + CGFloat(LOGO_DROP * U))
    return path.copy(using: &move)
}

func chooseFont(named wanted: String?) -> CTFont {
    for name in (wanted.map { [$0] } ?? FONTS) {
        let font = CTFontCreateWithName(name as CFString, 100, nil)
        if (CTFontCopyPostScriptName(font) as String) == name {
            print("make-icon: ampersand from \(name)")
            return font
        }
    }
    fail("none of the typefaces " + (wanted.map { [$0] } ?? FONTS).joined(separator: ", ") + " is installed")
}

/// The ampersand's outline, scaled to GLYPH_HEIGHT and centred, y downwards.
func ampersand(_ font: CTFont) -> CGPath {
    var characters: [UniChar] = [0x26]
    var glyphs: [CGGlyph] = [0]
    guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1),
          let outline = CTFontCreatePathForGlyph(font, glyphs[0], nil) else {
        fail("the typeface has no ampersand")
    }
    let box = outline.boundingBoxOfPath
    let k = CGFloat(GLYPH_HEIGHT * U) / box.height
    var place = CGAffineTransform(a: k, b: 0, c: 0, d: -k,
                                  tx: CGFloat(N) / 2 - box.midX * k, ty: CGFloat(N) / 2 + box.midY * k)
    return outline.copy(using: &place)!
}

// ------------------------------------------------------------------------------------------ the picture
struct Noise {                                    // the same grain every run
    var state: UInt64 = 7
    mutating func next() -> Float {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)          // 0..<1
    }
    mutating func normal() -> Float {              // Box-Muller
        let a = max(next(), 1e-7), b = next()
        return (-2 * log(a)).squareRoot() * cos(2 * Float.pi * b)
    }
}

/// Composes the tile and the logo as premultiplied red, green, blue and alpha planes.
/// `emblem`, `wordmark` and `eye` are the logo's shapes at drawing size (the plain icon has only a wordmark).
func compose(emblem emblemPath: CGPath?, wordmark wordmarkPath: CGPath?, eye eyePath: CGPath?) -> [Plane] {
    let tile = coverage(tilePath())
    let emblem = coverage(emblemPath)
    let wordmark = coverage(wordmarkPath), eye = coverage(eyePath)

    // The emblem is cut away round the letters so that they read cleanly.
    let around = blurred(wordmark, sigma: KNOCKOUT * U)
    for i in 0..<N * N { emblem.p[i] *= 1 - clamped(around.p[i] * 3) }
    let both = Plane()
    for i in 0..<N * N { both.p[i] = clamped(emblem.p[i] + wordmark.p[i]) }
    let drop = shifted(blurred(both, sigma: 7 * U), dx: 3 * U, dy: 7 * U)     // the logo's shadow on the white half
    let glow = blurred(both, sigma: 12 * U)                                   // and its glow on the black half
    let (emblemLit, emblemDark) = edgeLight(emblem, dx: 1.2, dy: 1.8)
    let (letterLit, letterDark) = edgeLight(wordmark, dx: 1.2, dy: 1.8)
    let eyeGlow = blurred(eye, sigma: 8 * U)

    // The tile's own light: a lit rim on its upper left edges and a thin darker line all round.
    let (tileLit, _) = edgeLight(tile, dx: 1.6, dy: 2.4)
    let rim = blurred(tileLit, sigma: 0.6 * U)
    let edge = Plane()
    for y in 0..<N {
        for x in 0..<N {
            var low: Float = 1                                                // darkest tile coverage in the 3 x 3 around
            for yy in max(0, y - 1)...min(N - 1, y + 1) {
                for xx in max(0, x - 1)...min(N - 1, x + 1) { low = min(low, tile.p[yy * N + xx]) }
            }
            edge.p[y * N + x] = clamped(tile.p[y * N + x] - low)
        }
    }
    let line = blurred(edge, sigma: 0.6 * U)
    let under = shifted(blurred(tile, sigma: 13 * U), dx: 0, dy: 12 * U)      // the shadow under the tile

    var noise = Noise()
    let planes = (0..<4).map { _ in Plane() }
    let half = Float(N) / 2, body = TILE / 2 * U

    /// Inverts the ground under a logo shape against `grey` and lays it over `c`, lit along the edges that face the light.
    func inlay(_ c: inout Colour, ground: Colour, mask: Float, grey: Float, lit: Float, dark: Float) {
        if mask <= 0 { return }
        var inverse = clamped((distance(ground, from: grey) - 0.5) * CONTRAST + 0.5)
        if (inverse.x + inverse.y + inverse.z) / 3 > 0.5 {
            inverse *= 1 - 0.20 * dark                                  // light on dark: a touch darker on the far rim
        } else {
            inverse += (Colour(repeating: 1) - inverse) * (0.38 * lit)   // dark on light: a lit rim on the near one
        }
        c = c * (1 - mask) + clamped(inverse) * mask
    }

    for y in 0..<N {
        let cy = Float(y) - half + 0.5
        for x in 0..<N {
            let i = y * N + x
            let cx = Float(x) - half + 0.5
            let dd: Float = (cx - cy) / ROOT2                                  // distance from the cut; > 0 on the white half

            // The ground: two halves, each easing from its colour at the cut to another in its far corner.
            let white = clamped(0.5 + dd)
            let toWhite = pow(clamped(dd / (body * 0.95)), 0.9), toBlack = pow(clamped(-dd / (body * 0.95)), 0.8)
            let ground = clamped((WHITE_NEAR + (WHITE_FAR - WHITE_NEAR) * toWhite) * white
                                 + (BLACK_NEAR + (BLACK_FAR - BLACK_NEAR) * toBlack) * (1 - white)
                                 + Colour(repeating: noise.normal() * GRAIN))
            var c = ground
            let lum = (c.x + c.y + c.z) / 3

            // Shadow of the logo on light ground, glow on dark ground.
            c = c * (1 - SHADOW * drop.p[i] * smoothstep(0.35, 0.8, lum))
            c += COOL * (GLOW * glow.p[i] * (1 - smoothstep(0.25, 0.6, lum)))

            // The cut: a hairline of warm light, a bloom and a glossy streak on the black side, a soft shadow on the white.
            if dd < 0 {
                let hair = HAIR * exp(-pow(abs(dd) / (1.7 * U), 2)), bloom = BLOOM * exp(-pow(abs(dd) / (34 * U), 2))
                let gloss = STREAK * (exp(-pow((dd + 175 * U) / (34 * U), 2)) + 0.5 * exp(-pow((dd + 245 * U) / (12 * U), 2)))
                c += HAIRLINE * hair + WARM * bloom + GLOSS * gloss
            } else if dd > 0 {
                c *= 1 - 0.22 * exp(-pow(dd / (6 * U), 2))
            }

            // The logo, emblem then letters.
            inlay(&c, ground: ground, mask: emblem.p[i], grey: EMBLEM_GREY, lit: emblemLit.p[i], dark: emblemDark.p[i])
            inlay(&c, ground: ground, mask: wordmark.p[i], grey: LETTER_GREY, lit: letterLit.p[i], dark: letterDark.p[i])

            // The dragon's eye: a glow round an amber disc with a hot core.
            if eye.p[i] > 0 || eyeGlow.p[i] > 0.001 {
                c += (Colour(repeating: 1) - c) * AMBER * (0.5 * eyeGlow.p[i])
                c = c * (1 - eye.p[i]) + (AMBER * 0.3 + AMBER_HOT * 0.7) * eye.p[i]
            }

            // The tile's rim light, edge line and top light.
            let top = clamped(1 - (cy / body + 1) / 2)
            c += (Colour(repeating: 1) - c) * (0.5 * rim.p[i])
            c *= 1 - 0.16 * line.p[i]
            c = clamped(c + Colour(repeating: SHEEN * top * top))

            let inside = tile.p[i]
            planes[0].p[i] = c.x * inside
            planes[1].p[i] = c.y * inside
            planes[2].p[i] = c.z * inside
            planes[3].p[i] = inside + under.p[i] * TILE_SHADOW * (1 - inside)
        }
    }
    return planes
}

// ------------------------------------------------------------------------------------------ the files
/// The drawing averaged down to `size` pixels each way, as four lists of numbers: premultiplied red,
/// green, blue and alpha.
func average(_ planes: [Plane], to size: Int) -> [[Float]] {
    let block = N / size, scale = 1 / Float(block * block)
    return planes.map { plane in
        var small = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                var sum: Float = 0
                for yy in 0..<block {
                    let row = plane.p + (y * block + yy) * N + x * block
                    for xx in 0..<block { sum += row[xx] }
                }
                small[y * size + x] = sum * scale
            }
        }
        return small
    }
}

/// Unsharp mask for the small pictures, where averaging alone leaves the lettering too soft to read: each
/// value goes up by `amount` times its difference from a 3 x 3 blur of itself.
func sharpened(_ small: [[Float]], size: Int, amount: Float) -> [[Float]] {
    let weight: [Float] = [1, 2, 1]
    var out = small
    for k in 0..<4 {
        for y in 0..<size {
            for x in 0..<size {
                var blur: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let yy = min(max(y + dy, 0), size - 1), xx = min(max(x + dx, 0), size - 1)
                        blur += small[k][yy * size + xx] * weight[dy + 1] * weight[dx + 1]
                    }
                }
                let here = small[k][y * size + x]
                out[k][y * size + x] = here + amount * (here - blur / 16)
            }
        }
    }
    for i in 0..<size * size {                                  // keep it a valid premultiplied colour
        out[3][i] = clamped(out[3][i])
        for k in 0..<3 { out[k][i] = clamped(out[k][i], 0, out[3][i]) }
    }
    return out
}

/// The picture as 8-bit premultiplied RGBA.
func picture(_ small: [[Float]], size: Int) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    for i in 0..<size * size {
        for k in 0..<4 { bytes[i * 4 + k] = UInt8(clamped(small[k][i]) * 255 + 0.5) }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
        fail("cannot make a \(size) pixel picture")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let out = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(out, image, nil)
    guard CGImageDestinationFinalize(out) else { fail("cannot write \(url.path)") }
}

// ------------------------------------------------------------------------------------------ main
func usage() -> Never {
    fail("usage: make-icon <folder>.iconset [--plain] [--art <logo-art.txt>] [--font <PostScript name>]")
}

var folderArgument: String?, plain = false, artArgument: String?, fontArgument: String?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--plain": plain = true
    case "--art": guard let value = arguments.next() else { usage() }; artArgument = value
    case "--font": guard let value = arguments.next() else { usage() }; fontArgument = value
    default:
        if argument.hasPrefix("-") || folderArgument != nil { usage() }
        folderArgument = argument
    }
}
guard let folderArgument = folderArgument else { usage() }
let folder = URL(fileURLWithPath: folderArgument, isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

// The logo art sits beside this file, unless another is named.
let defaultArt = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("icon-art/logo-art.txt")
var artURL: URL? = nil
if !plain {
    if let named = artArgument {
        artURL = URL(fileURLWithPath: named)
    } else if FileManager.default.fileExists(atPath: defaultArt.path) {
        artURL = defaultArt
    }
}

let planes: [Plane]
if let url = artURL {
    let art = loadArt(url)
    print("make-icon: logo from \(url.path)")
    planes = compose(emblem: place(art.groups["emblem"], box: art.box),
                     wordmark: place(art.groups["wordmark"], box: art.box),
                     eye: place(art.groups["eye"], box: art.box))
} else {
    if !plain { print("make-icon: no logo art at \(defaultArt.path); drawing the plain icon") }
    planes = compose(emblem: nil, wordmark: ampersand(chooseFont(named: fontArgument)), eye: nil)
}

// (pixels, file names): each distinct size is made once and written under both of its names.
let names: [(Int, [String])] = [
    (16, ["icon_16x16.png"]),
    (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64, ["icon_32x32@2x.png"]),
    (128, ["icon_128x128.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]
for (pixels, files) in names {
    var small = average(planes, to: pixels)
    if pixels <= 64 { small = sharpened(small, size: pixels, amount: pixels <= 32 ? 0.5 : 0.4) }
    let image = picture(small, size: pixels)
    for file in files { writePNG(image, to: folder.appendingPathComponent(file)) }
}
print("make-icon: wrote \(names.reduce(0) { $0 + $1.1.count }) pictures to \(folder.path)")
