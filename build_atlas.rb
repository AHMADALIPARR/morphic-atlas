#!/usr/bin/env ruby
# frozen_string_literal: true

# build_atlas.rb -- "Morphic" 2D Human Anatomy Atlas generator.
#
#   ruby build_atlas.rb [output.html]      (default: atlas.html next to this script)
#
# Plain Ruby stdlib only. The anatomy lives below as Ruby data (see the
# "ANATOMY" section): every piece is a *morph definition* with
#   id, system, label, shape (path / ellipse data), fill, stroke,
#   stroke width, opacity, dash ...
# The generator serialises the whole world to JSON and inlines it, together
# with CSS, JS and an SVG stage, into ONE self-contained atlas.html
# (no external requests of any kind).
#
# Coordinate system: SVG user units, canvas 400 x 840, body centre line x = 200.
# "Right" / "R" always means the PATIENT's right, i.e. the viewer's LEFT (x < 200).
#
# SCHEMATIC EDUCATIONAL MODEL - NOT FOR DIAGNOSIS OR CLINICAL USE.

require 'json'

# --------------------------------------------------------------------------
# Geometry helpers: smooth closed/open curves, tapered "tubes", mirroring.
# --------------------------------------------------------------------------
module Geo
  CX = 200.0
  module_function

  def f(n)
    r = n.round(1)
    r == r.round ? r.round.to_s : r.to_s
  end

  def pt(p) = "#{f(p[0])} #{f(p[1])}"

  def mx(p) = [2 * CX - p[0], p[1], *p[2..]]

  # Catmull-Rom -> cubic Bezier. A point written [x, y, :c] is a sharp corner.
  def smooth(pts, closed: true, tension: 1.0)
    n = pts.size
    d = +"M#{pt(pts[0])}"
    (closed ? n : n - 1).times do |i|
      p0 = closed ? pts[(i - 1) % n] : pts[[i - 1, 0].max]
      p1 = pts[i]
      p2 = pts[(i + 1) % n]
      p3 = closed ? pts[(i + 2) % n] : pts[[i + 2, n - 1].min]
      c1 = p1[2] == :c ? p1 : [p1[0] + (p2[0] - p0[0]) / 6.0 * tension, p1[1] + (p2[1] - p0[1]) / 6.0 * tension]
      c2 = p2[2] == :c ? p2 : [p2[0] - (p3[0] - p1[0]) / 6.0 * tension, p2[1] - (p3[1] - p1[1]) / 6.0 * tension]
      d << "C#{pt(c1)} #{pt(c2)} #{pt(p2)}"
    end
    d << 'Z' if closed
    d
  end

  def closed(pts) = smooth(pts, closed: true)
  def line(pts)   = smooth(pts, closed: false)

  def dedupe(pts)
    out = []
    pts.each { |p| out << p unless out.last && (out.last[0] - p[0]).abs < 0.01 && (out.last[1] - p[1]).abs < 0.01 }
    out.pop if out.size > 1 && (out.first[0] - out.last[0]).abs < 0.01 && (out.first[1] - out.last[1]).abs < 0.01
    out
  end

  # A half outline (viewer-left side, listed centre-line -> outwards -> back to
  # centre-line) becomes a symmetric closed smooth shape.
  def sym_closed(half)
    closed(dedupe(half + half.reverse.map { |p| mx(p) }))
  end

  # Dense Catmull-Rom sampling of an open polyline; third value = parameter.
  def sample(pts, per = 8)
    out = []
    (pts.size - 1).times do |i|
      p0 = pts[[i - 1, 0].max]
      p1 = pts[i]
      p2 = pts[i + 1]
      p3 = pts[[i + 2, pts.size - 1].min]
      per.times do |k|
        t = k / per.to_f
        t2 = t * t
        t3 = t2 * t
        x = 0.5 * (2 * p1[0] + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
        y = 0.5 * (2 * p1[1] + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
        out << [x, y, i + t]
      end
    end
    out << [pts.last[0], pts.last[1], (pts.size - 1).to_f]
  end

  # Tapered tube (bones, muscle bellies): half-widths per control point.
  def tube(pts, widths, per = 8)
    s = sample(pts, per)
    ws = widths.is_a?(Numeric) ? Array.new(pts.size, widths) : widths
    left = []
    right = []
    s.each_with_index do |(x, y, u), i|
      a = s[[i - 1, 0].max]
      b = s[[i + 1, s.size - 1].min]
      dx = b[0] - a[0]
      dy = b[1] - a[1]
      l = Math.hypot(dx, dy)
      l = 1.0 if l.zero?
      nx = -dy / l
      ny = dx / l
      i0 = u.floor
      i1 = [i0 + 1, ws.size - 1].min
      i0 = [i0, ws.size - 1].min
      w = ws[i0] * (1 - (u - u.floor)) + ws[i1] * (u - u.floor)
      left << [x + nx * w, y + ny * w, nx, ny, w, l, dx, dy]
      right << [x - nx * w, y - ny * w]
    end
    # rounded end caps
    h = left.first
    t = left.last
    cap_s = [s.first[0] - h[6] / h[5] * h[4] * 0.9, s.first[1] - h[7] / h[5] * h[4] * 0.9]
    cap_e = [s.last[0] + t[6] / t[5] * t[4] * 0.9, s.last[1] + t[7] / t[5] * t[4] * 0.9]
    poly = [cap_s] + left.map { |p| p[0, 2] } + [cap_e] + right.reverse
    'M' + poly.map { |p| pt(p) }.join('L') + 'Z'
  end

  def ell(c, rx, ry = rx, rot = 0)
    "M#{f(c[0] - rx)} #{f(c[1])}A#{f(rx)} #{f(ry)} #{rot} 1 0 #{f(c[0] + rx)} #{f(c[1])}A#{f(rx)} #{f(ry)} #{rot} 1 0 #{f(c[0] - rx)} #{f(c[1])}Z"
  end

  def rrect(cx, cy, w, h, r = 2)
    x = cx - w / 2.0
    y = cy - h / 2.0
    r = [r, w / 2.0, h / 2.0].min
    "M#{f(x + r)} #{f(y)}H#{f(x + w - r)}Q#{f(x + w)} #{f(y)} #{f(x + w)} #{f(y + r)}V#{f(y + h - r)}" \
      "Q#{f(x + w)} #{f(y + h)} #{f(x + w - r)} #{f(y + h)}H#{f(x + r)}Q#{f(x)} #{f(y + h)} #{f(x)} #{f(y + h - r)}" \
      "V#{f(y + r)}Q#{f(x)} #{f(y)} #{f(x + r)} #{f(y)}Z"
  end

  def compose(*paths) = paths.join

  def tx_all(t, pts) = pts.map { |p| t.call(p) }
end

# ==========================================================================
# GEOMETRY II -- path parsing, hulls, polygon clipping (used by the scene
# graph, the liver segmentation and the branching vessel generator)
# ==========================================================================
module Geo
  PX_PER_CM = 4.57          # the 840 px tall schematic stands for a ~175 cm adult
  module_function

  # Absolute-only SVG path reader (everything Geo emits: M L C Q H V A Z).
  def path_segments(d)
    toks = d.scan(/[MLCQHVAZ]|-?\d*\.?\d+(?:[eE]-?\d+)?/)
    subs = []
    cur = nil
    pos = [0.0, 0.0]
    start = pos
    i = 0
    cmd = nil
    take = ->(n) { v = toks[i, n].map(&:to_f); i += n; v }
    while i < toks.size
      if toks[i] =~ /\A[A-Z]\z/
        cmd = toks[i]
        i += 1
        if cmd == 'Z'
          cur << { c: 'Z' } if cur
          pos = start
          next
        end
      end
      case cmd
      when 'M' then x, y = take.(2); pos = start = [x, y]; cur = [{ c: 'M', p: pos }]; subs << cur; cmd = 'L'
      when 'L' then x, y = take.(2); pos = [x, y]; cur << { c: 'L', p: pos }
      when 'H' then x, = take.(1); pos = [x, pos[1]]; cur << { c: 'L', p: pos }
      when 'V' then y, = take.(1); pos = [pos[0], y]; cur << { c: 'L', p: pos }
      when 'Q' then a, b, x, y = take.(4); cur << { c: 'Q', q: [a, b], p: [x, y] }; pos = [x, y]
      when 'C' then a, b, c, e, x, y = take.(6); cur << { c: 'C', c1: [a, b], c2: [c, e], p: [x, y] }; pos = [x, y]
      when 'A' then rx, ry, _rot, _la, _sw, x, y = take.(7); cur << { c: 'A', rx: rx, ry: ry, from: pos, p: [x, y] }; pos = [x, y]
      else raise "bad path command #{cmd.inspect}"
      end
    end
    subs
  end

  # every endpoint / control point (conservative cover of the shape)
  def path_points(d)
    pts = []
    path_segments(d).each do |sub|
      sub.each do |s|
        case s[:c]
        when 'M', 'L' then pts << s[:p]
        when 'Q' then pts << s[:q] << s[:p]
        when 'C' then pts << s[:c1] << s[:c2] << s[:p]
        when 'A'
          cx = (s[:from][0] + s[:p][0]) / 2.0
          cy = (s[:from][1] + s[:p][1]) / 2.0
          pts << s[:from] << s[:p] << [cx, cy - s[:ry]] << [cx, cy + s[:ry]]
        end
      end
    end
    pts
  end

  # first sub-path as a dense polygon (curves flattened)
  def path_polygon(d, per = 8)
    poly = []
    pos = nil
    path_segments(d).first.each do |s|
      case s[:c]
      when 'M', 'L' then poly << s[:p]; pos = s[:p]
      when 'C'
        1.upto(per) do |k|
          t = k / per.to_f
          u = 1 - t
          poly << [0, 1].map { |a| u**3 * pos[a] + 3 * u * u * t * s[:c1][a] + 3 * u * t * t * s[:c2][a] + t**3 * s[:p][a] }
        end
        pos = s[:p]
      end
    end
    poly.pop if poly.size > 1 && (poly.first[0] - poly.last[0]).abs < 0.01 && (poly.first[1] - poly.last[1]).abs < 0.01
    poly
  end

  # approximate length of a drawn path (sum of chords between end points)
  def path_len(d)
    sub = path_segments(d)
    sub.sum do |ss|
      prev = nil
      ss.sum do |s|
        next 0 unless s[:p]
        l = prev ? Math.hypot(s[:p][0] - prev[0], s[:p][1] - prev[1]) : 0
        l *= 1.04 if s[:c] == 'C'
        prev = s[:p]
        l
      end
    end
  end

  def shoelace(poly) = poly.each_with_index.sum { |p, i| q = poly[(i + 1) % poly.size]; p[0] * q[1] - q[0] * p[1] } / 2.0

  def hull(points)
    pts = points.map { |p| [p[0].to_f, p[1].to_f] }.uniq.sort
    return pts if pts.size < 3
    cross = ->(o, a, b) { (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]) }
    lo = []
    pts.each { |p| lo.pop while lo.size >= 2 && cross.(lo[-2], lo[-1], p) <= 0; lo << p }
    up = []
    pts.reverse_each { |p| up.pop while up.size >= 2 && cross.(up[-2], up[-1], p) <= 0; up << p }
    lo[0..-2] + up[0..-2]
  end

  def inside?(poly, pt)
    x, y = pt
    c = false
    j = poly.size - 1
    poly.each_with_index do |p, i|
      q = poly[j]
      c = !c if (p[1] > y) != (q[1] > y) && x < (q[0] - p[0]) * (y - p[1]) / (q[1] - p[1]) + p[0]
      j = i
    end
    c
  end

  def side(a, b, p) = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])

  def seg_inter(s, e, a, b)
    ds = side(a, b, s)
    de = side(a, b, e)
    t = ds / (ds - de)
    [s[0] + (e[0] - s[0]) * t, s[1] + (e[1] - s[1]) * t]
  end

  # keep the part of `poly` on the inner (or outer) side of the directed line a->b
  def clip_half(poly, a, b, keep_inside = true)
    out = []
    return out if poly.empty?
    s = poly.last
    poly.each do |e|
      ein = keep_inside ? side(a, b, e) >= 0 : side(a, b, e) <= 0
      sin = keep_inside ? side(a, b, s) >= 0 : side(a, b, s) <= 0
      if ein
        out << seg_inter(s, e, a, b) unless sin
        out << e
      elsif sin
        out << seg_inter(s, e, a, b)
      end
      s = e
    end
    out
  end

  def clip_convex(subject, clip)
    clip = clip.reverse if shoelace(clip) < 0
    out = subject
    clip.each_with_index do |a, i|
      out = clip_half(out, a, clip[(i + 1) % clip.size], true)
      return [] if out.size < 3
    end
    out
  end

  # subject minus a convex hole -> list of polygons
  def clip_outside(subject, hole)
    hole = hole.reverse if shoelace(hole) < 0
    pieces = []
    rest = subject
    hole.each_with_index do |a, i|
      b = hole[(i + 1) % hole.size]
      o = clip_half(rest, a, b, false)
      pieces << o if o.size >= 3
      rest = clip_half(rest, a, b, true)
    end
    pieces
  end

  def poly_path(poly) = 'M' + poly.map { |p| pt(p) }.join('L') + 'Z'

  def offset_line(pts, off)
    pts.each_with_index.map do |p, i|
      a = pts[[i - 1, 0].max]
      b = pts[[i + 1, pts.size - 1].min]
      dx = b[0] - a[0]
      dy = b[1] - a[1]
      l = Math.hypot(dx, dy)
      l = 1.0 if l.zero?
      [p[0] - dy / l * off, p[1] + dx / l * off]
    end
  end

  def polylen(pts) = pts.each_cons(2).sum { |a, b| Math.hypot(b[0] - a[0], b[1] - a[1]) }
end

# ==========================================================================
# ANATOMY -- the world as Ruby data.  Each morph definition:
#   id, system, label, shape {type: path|ellipse|rect ...}, fill, stroke,
#   stroke_width, opacity, dash (optional), rule (optional fill-rule)
# ==========================================================================
module Atlas
  extend Geo

  W = 400
  H = 840

  # `order` = row in the layer panel / explode stack (top -> bottom),
  # `z`     = paint order (low = drawn first = furthest back).
  LAYERS = [
    { id: 'skin',     label: 'Skin / outline',      color: '#e3b79c', order: 0, z: 0 },
    { id: 'skeleton', label: 'Skeleton',            color: '#d8c89a', order: 1, z: 1 },
    { id: 'muscles',  label: 'Muscles',             color: '#c4565a', order: 2, z: 2 },
    { id: 'arteries', label: 'Systemic arteries',   color: '#d1222f', order: 3, z: 6 },
    { id: 'veins',    label: 'Systemic veins & portal', color: '#1d4ea3', order: 4, z: 5 },
    { id: 'pulmonary', label: 'Pulmonary circulation', color: '#8a4a9b', order: 5, z: 7 },
    { id: 'organs',   label: 'Organs',              color: '#e08c8c', order: 6, z: 3 },
    { id: 'nerves',   label: 'Nervous system',      color: '#e0b020', order: 7, z: 4 }
  ].freeze

  MORPHS = []

  module_function

  def path(d) = { type: 'path', d: d }
  def ellipse(cx, cy, rx, ry) = { type: 'ellipse', cx: cx, cy: cy, rx: rx, ry: ry }

  def add(id, system, label, shape, fill: nil, stroke: nil, sw: 1, op: 1, dash: nil, rule: nil)
    shape = path(shape) if shape.is_a?(String)
    raise "duplicate morph id #{id}" if MORPHS.any? { |m| m[:id] == id }

    MORPHS << { id: id, system: system, label: label, shape: shape, fill: fill, stroke: stroke,
                stroke_width: sw, opacity: op, dash: dash, rule: rule }
  end

  # Bilateral pair. Block receives a point mapper `t` (identity for the patient's
  # right = viewer-left, mirror for the left) and returns a path string / shape.
  def pair(id, system, label, **style)
    { 'r' => ['Right', ->(p) { p }], 'l' => ['Left', ->(p) { Geo.mx(p) }] }.each do |suffix, (side, t)|
      shape = yield(t)
      add("#{id}_#{suffix}", system, "#{side} #{label}", shape, **style)
    end
  end

  def pts(t, arr) = arr.map { |p| t.call(p) }
  def tube(t, arr, w) = Geo.tube(pts(t, arr), w)
  def circ(t, c, rx, ry = rx, rot = 0) = Geo.ell(t.call(c), rx, ry, rot)
  def line(t, arr) = Geo.line(pts(t, arr))
  def shp(t, arr) = Geo.closed(pts(t, arr))

  # ------------------------------------------------------------------ SKIN
  def build_skin
    half = [
      [200, 30], [178, 35], [166, 52], [164, 76], [168, 100], [177, 118], [183, 132], [184, 148],
      [166, 156], [142, 162], [122, 166], [104, 174], [91, 192], [86, 230], [81, 270], [77, 300],
      [75, 318], [68, 352], [62, 400], [60, 440],
      [54, 462], [49, 486], [50, 508], [58, 520], [70, 523], [82, 518], [89, 502], [90, 480], [86, 450], [86, 442],
      [93, 400], [102, 352], [106, 318], [110, 290], [117, 262], [122, 236], [128, 214, :c],
      [131, 240], [133, 270], [137, 296], [134, 322], [129, 350], [127, 380], [127, 402],
      [123, 430], [125, 470], [133, 510], [143, 550], [148, 584], [146, 625], [146, 650], [150, 690],
      [156, 730], [158, 748], [153, 768], [146, 790], [143, 803], [150, 808], [172, 809], [190, 807],
      [192, 798], [184, 782], [180, 760], [178, 746], [181, 705], [185, 660], [187, 625], [187, 584],
      [189, 560], [192, 520], [197, 480], [200, 440], [200, 418, :c]
    ]
    add('skin_body', 'skin', 'Body silhouette', Geo.sym_closed(half), fill: '#f4d6c0', stroke: '#c48f72', sw: 1.8, op: 0.96)

    face = compose_face
    add('skin_face', 'skin', 'Facial features', face, stroke: '#a9755c', sw: 1.2, op: 0.9)
    navel = Geo.compose(Geo.ell([200, 326], 2.6, 3.6), Geo.ell([167, 210], 2.4, 2.4), Geo.ell([233, 210], 2.4, 2.4))
    add('skin_marks', 'skin', 'Navel & nipples', navel, fill: '#d79d84', stroke: '#b97b64', sw: 0.8, op: 0.9)
    add('skin_neckline', 'skin', 'Clavicular fold', Geo.compose(Geo.line([[148, 158], [172, 160], [196, 164]]), Geo.line([[252, 158], [228, 160], [204, 164]])),
        stroke: '#c9977c', sw: 0.9, op: 0.6)
  end

  def compose_face
    r = [
      Geo.line([[178, 70], [186, 67], [194, 69]]),                       # brow
      Geo.closed([[179, 77], [186, 74], [194, 77], [186, 80]]),          # eye
      Geo.line([[165, 77], [159, 82], [160, 91], [166, 96]])             # ear
    ]
    both = r.flat_map { |d| [d, mirror_path(d)] }
    nose_mouth = [Geo.line([[200, 78], [196, 93], [200, 97], [204, 93]]), Geo.line([[189, 108], [200, 111], [211, 108]])]
    Geo.compose(*both, *nose_mouth)
  end

  # mirror an already-built path string (absolute M/C/Z/L only)
  def mirror_path(d)
    d.gsub(/(-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?)/) { "#{Geo.f(400 - Regexp.last_match(1).to_f)} #{Regexp.last_match(2)}" }
  end

  # -------------------------------------------------------------- SKELETON
  BONE = '#efe4c8'
  BONE_L = '#a8966c'

  def bone(id, label, d, **o) = add(id, 'skeleton', label, d, fill: BONE, stroke: BONE_L, sw: 0.9, op: 0.97, **o)

  def rib_paths(t)
    paths = []
    12.times do |i|
      w = [44, 52, 58, 63, 66, 68, 68, 66, 63, 58, 44, 34][i]
      ys = 158 + i * 9.5
      if i < 7
        ye = 172 + i * 11.7
        p = [[197, ys], [200 - w * 0.62, ys - 6], [200 - w, ys + 18], [200 - w * 0.78, ye + 5], [192, ye]]
      elsif i < 10
        ye = [250, 257, 264][i - 7]
        xe = [188, 180, 172][i - 7]
        p = [[197, ys], [200 - w * 0.62, ys - 4], [200 - w, ys + 20], [200 - w * 0.72, ye + 8], [xe, ye]]
      else
        p = [[197, ys], [200 - w * 0.62, ys - 2], [200 - w, ys + 14], [200 - w * 0.9, ys + 24]]
      end
      paths << Geo.line(pts(t, p))
    end
    paths.join
  end

  def build_skeleton
    cranium = Geo.sym_closed([[200, 31], [180, 36], [168, 50], [165, 70], [167, 86], [173, 98], [182, 106], [192, 110], [200, 111]])
    bone('sk_cranium', 'Cranium', cranium)
    add('sk_sutures', 'skeleton', 'Cranial sutures', Geo.compose(Geo.line([[169, 58], [185, 49], [200, 46], [215, 49], [231, 58]]), Geo.line([[200, 32], [200, 46]])),
        stroke: '#b5a47b', sw: 0.8, op: 0.9)
    pair('sk_orbit', 'skeleton', 'orbit', fill: '#6b5f46', stroke: '#4a4130', sw: 0.6, op: 0.9) { |t| circ(t, [187, 77], 8, 6.3, 0) }
    add('sk_nasal', 'skeleton', 'Nasal aperture', Geo.sym_closed([[200, 84], [196, 92], [196, 100], [200, 100]]), fill: '#6b5f46', stroke: '#4a4130', sw: 0.6, op: 0.9)
    bone('sk_mandible', 'Mandible', Geo.sym_closed([[200, 128], [188, 126], [177, 118], [171, 101], [175, 99], [179, 109], [188, 115], [200, 117]]))

    cerv = 7.times.map { |i| Geo.rrect(200, 137 + i * 5.4, 12 + i * 0.7, 4.4, 1.6) }
    bone('sk_cervical', 'Cervical vertebrae (C1-C7)', Geo.compose(*cerv))
    thor = 12.times.map { |i| Geo.rrect(200, 173 + i * 8.0, 16 + i * 0.7, 6.4, 2) }
    bone('sk_thoracic', 'Thoracic vertebrae (T1-T12)', Geo.compose(*thor))
    lumb = 5.times.map { |i| Geo.rrect(200, 270 + i * 10.6, 25 + i * 0.6, 8.6, 3) }
    bone('sk_lumbar', 'Lumbar vertebrae (L1-L5)', Geo.compose(*lumb))
    sacrum = Geo.sym_closed([[200, 320], [188, 321], [184, 334], [188, 350], [194, 368], [200, 379]])
    coccyx = Geo.sym_closed([[200, 381], [197, 386], [199, 393], [200, 393]])
    bone('sk_sacrum', 'Sacrum & coccyx', Geo.compose(sacrum, coccyx))
    bone('sk_sternum', 'Sternum', Geo.sym_closed([[200, 163], [192, 164], [189, 174], [191, 180], [191, 222], [194, 238], [200, 252]]))

    pair('sk_ribs', 'skeleton', 'ribs (1-12)', fill: nil, stroke: '#d8c79a', sw: 3.1, op: 0.95) { |t| rib_paths(t) }
    pair('sk_clavicle', 'skeleton', 'clavicle', fill: BONE, stroke: BONE_L, sw: 0.9, op: 0.97) { |t| tube(t, [[196, 166], [178, 162], [152, 168], [124, 164]], [3.2, 2.6, 2.8, 3.4]) }
    pair('sk_scapula', 'skeleton', 'scapula', fill: '#e6d9b8', stroke: BONE_L, sw: 0.9, op: 0.9) { |t| shp(t, [[148, 172], [128, 168], [122, 178], [130, 198], [136, 224], [146, 206]]) }
    pair('sk_humerus', 'skeleton', 'humerus', fill: BONE, stroke: BONE_L, sw: 0.9, op: 0.97) do |t|
      Geo.compose(circ(t, [113, 183], 9), tube(t, [[112, 188], [106, 240], [97, 300], [93, 316]], [5.5, 5, 5, 6.5]), circ(t, [92, 320], 10, 6.5))
    end
    pair('sk_radius', 'skeleton', 'radius', fill: BONE, stroke: BONE_L, sw: 0.9, op: 0.97) { |t| tube(t, [[86, 324], [80, 380], [70, 440]], [3.2, 2.6, 4.3]) }
    pair('sk_ulna', 'skeleton', 'ulna', fill: BONE, stroke: BONE_L, sw: 0.9, op: 0.97) { |t| tube(t, [[97, 322], [91, 380], [80, 442]], [4.2, 3, 2.4]) }
    pair('sk_hand', 'skeleton', 'hand (carpals, metacarpals, phalanges)', fill: BONE, stroke: BONE_L, sw: 0.7, op: 0.97) do |t|
      Geo.compose(circ(t, [73, 454], 10, 7),
                  tube(t, [[64, 456], [58, 472], [56, 488]], 2.2),
                  tube(t, [[68, 462], [63, 488], [62, 514]], 1.8),
                  tube(t, [[73, 464], [72, 492], [72, 518]], 1.8),
                  tube(t, [[78, 464], [80, 490], [82, 512]], 1.7),
                  tube(t, [[82, 462], [86, 482], [87, 498]], 1.6))
    end
    pair('sk_hip', 'skeleton', 'hip bone (ilium, ischium, pubis)', fill: BONE, stroke: BONE_L, sw: 0.9, op: 0.97, rule: 'evenodd') do |t|
      Geo.compose(
        shp(t, [[190, 300], [166, 297], [142, 304], [128, 322], [127, 340], [138, 352], [146, 366], [145, 380], [151, 396], [156, 412], [166, 421], [180, 415], [190, 405], [199, 399], [199, 386], [192, 372], [194, 350], [191, 322]]),
        circ(t, [172, 398], 6.5, 10, 20)
      )
    end
    pair('sk_femur', 'skeleton', 'femur', fill: BONE, stroke: BONE_L, sw: 0.9, op: 0.97) do |t|
      Geo.compose(circ(t, [158, 382], 10.5), tube(t, [[158, 382], [148, 396]], [5, 6.5]),
                  tube(t, [[147, 398], [153, 450], [161, 520], [166, 574]], [7, 5.8, 5.8, 7.5]), circ(t, [167, 583], 16, 8))
    end
    pair('sk_patella', 'skeleton', 'patella', fill: '#f4ecd6', stroke: BONE_L, sw: 0.9, op: 0.97) { |t| circ(t, [167, 585], 8, 9.5) }
    pair('sk_tibia', 'skeleton', 'tibia', fill: BONE, stroke: BONE_L, sw: 0.9, op: 0.97) do |t|
      Geo.compose(circ(t, [168, 600], 17, 5), tube(t, [[170, 604], [171, 650], [170, 720], [172, 752]], [8, 5, 4.5, 5.5]), circ(t, [175, 757], 5.5, 8))
    end
    pair('sk_fibula', 'skeleton', 'fibula', fill: BONE, stroke: BONE_L, sw: 0.9, op: 0.97) { |t| tube(t, [[154, 606], [156, 660], [159, 720], [160, 758]], [3.2, 2.4, 2.4, 4]) }
    pair('sk_foot', 'skeleton', 'foot (tarsals, metatarsals, phalanges)', fill: BONE, stroke: BONE_L, sw: 0.7, op: 0.97) do |t|
      Geo.compose(shp(t, [[160, 762], [172, 758], [180, 764], [183, 780], [170, 786], [160, 780]]),
                  tube(t, [[163, 780], [158, 798]], 1.9), tube(t, [[167, 782], [166, 802]], 1.9),
                  tube(t, [[171, 782], [174, 803]], 1.9), tube(t, [[175, 780], [181, 800]], 1.9),
                  tube(t, [[178, 774], [188, 802]], 2.6))
    end
  end

  # --------------------------------------------------------------- MUSCLES
  def muscle(id, label, d, fill = '#c4565a', op = 0.78)
    add(id, 'muscles', label, d, fill: fill, stroke: '#8e2f36', sw: 0.8, op: op)
  end

  def build_muscles
    pair('mu_scm', 'muscles', 'sternocleidomastoid', fill: '#cf6a60', stroke: '#8e2f36', sw: 0.8, op: 0.8) { |t| tube(t, [[184, 112], [189, 134], [196, 162]], [3.6, 4.6, 3]) }
    pair('mu_trap', 'muscles', 'trapezius (upper fibres)', fill: '#b84a4f', stroke: '#8e2f36', sw: 0.8, op: 0.75) { |t| shp(t, [[186, 132], [164, 150], [136, 162], [124, 166], [148, 172], [176, 156]]) }
    pair('mu_pectoralis', 'muscles', 'pectoralis major', fill: '#c4565a', stroke: '#8e2f36', sw: 0.8, op: 0.8) { |t| shp(t, [[195, 172], [168, 170], [142, 176], [126, 192], [134, 208], [160, 222], [190, 224], [192, 196]]) }
    pair('mu_deltoid', 'muscles', 'deltoid', fill: '#d06b5f', stroke: '#8e2f36', sw: 0.8, op: 0.85) { |t| shp(t, [[126, 164], [108, 168], [93, 186], [89, 216], [98, 234], [110, 204], [124, 180]]) }
    pair('mu_serratus', 'muscles', 'serratus anterior', fill: '#d27b6e', stroke: '#8e2f36', sw: 0.7, op: 0.8) { |t| shp(t, [[136, 198], [150, 204], [152, 222], [142, 236], [134, 226]]) }
    pair('mu_biceps', 'muscles', 'biceps brachii', fill: '#cf6a60', stroke: '#8e2f36', sw: 0.8, op: 0.85) { |t| tube(t, [[110, 204], [106, 240], [100, 288], [97, 306]], [7, 9.5, 8.5, 3.5]) }
    pair('mu_brachioradialis', 'muscles', 'brachioradialis', fill: '#c4565a', stroke: '#8e2f36', sw: 0.8, op: 0.85) { |t| tube(t, [[84, 322], [76, 370], [68, 430]], [6.5, 6, 1.6]) }
    pair('mu_flexors', 'muscles', 'forearm flexors', fill: '#b84a4f', stroke: '#8e2f36', sw: 0.8, op: 0.85) { |t| tube(t, [[98, 322], [92, 370], [82, 438]], [8, 7, 1.6]) }
    pair('mu_rectus_abd', 'muscles', 'rectus abdominis', fill: '#cf6a60', stroke: '#8e2f36', sw: 0.8, op: 0.85) { |t| shp(t, [[198, 226], [177, 226], [173, 262], [175, 300], [182, 330], [198, 340]]) }
    pair('mu_abd_lines', 'muscles', 'tendinous intersections', fill: nil, stroke: '#7a2a30', sw: 0.8, op: 0.7) do |t|
      [247, 272, 297].map { |y| line(t, [[198, y], [186, y + 1], [175, y]]) }.join
    end
    pair('mu_oblique', 'muscles', 'external oblique', fill: '#bd4f55', stroke: '#8e2f36', sw: 0.8, op: 0.8) { |t| shp(t, [[174, 232], [152, 228], [138, 240], [135, 272], [138, 302], [150, 318], [172, 326], [176, 300], [174, 262]]) }
    pair('mu_glute_med', 'muscles', 'gluteus medius / tensor fasciae latae', fill: '#c4565a', stroke: '#8e2f36', sw: 0.8, op: 0.82) { |t| shp(t, [[138, 336], [128, 372], [130, 404], [148, 410], [152, 372]]) }
    pair('mu_psoas', 'muscles', 'iliopsoas', fill: '#b84a4f', stroke: '#8e2f36', sw: 0.8, op: 0.8) { |t| tube(t, [[190, 296], [180, 340], [168, 380], [162, 404]], [4.5, 6.5, 6, 3.5]) }
    pair('mu_rectus_fem', 'muscles', 'rectus femoris', fill: '#cf6a60', stroke: '#8e2f36', sw: 0.8, op: 0.85) { |t| tube(t, [[148, 378], [154, 450], [162, 530], [166, 574]], [6, 10, 9, 4]) }
    pair('mu_vastus_lat', 'muscles', 'vastus lateralis', fill: '#bd4f55', stroke: '#8e2f36', sw: 0.8, op: 0.82) { |t| tube(t, [[138, 404], [140, 450], [147, 520], [156, 574]], [8, 13, 10, 4]) }
    pair('mu_vastus_med', 'muscles', 'vastus medialis', fill: '#bd4f55', stroke: '#8e2f36', sw: 0.8, op: 0.82) { |t| tube(t, [[176, 468], [180, 520], [177, 566]], [5, 10, 8]) }
    pair('mu_adductor', 'muscles', 'adductor longus', fill: '#c4565a', stroke: '#8e2f36', sw: 0.8, op: 0.82) { |t| tube(t, [[188, 414], [182, 460], [172, 508]], [7, 10, 4]) }
    pair('mu_sartorius', 'muscles', 'sartorius', fill: '#d27b6e', stroke: '#8e2f36', sw: 0.7, op: 0.9) { |t| tube(t, [[134, 338], [150, 400], [170, 480], [182, 556], [184, 592]], [3.2, 3.5, 3.5, 3, 2.5]) }
    pair('mu_gracilis', 'muscles', 'gracilis', fill: '#d27b6e', stroke: '#8e2f36', sw: 0.7, op: 0.9) { |t| tube(t, [[192, 422], [189, 500], [184, 582]], [3.6, 2.6, 2]) }
    pair('mu_tib_ant', 'muscles', 'tibialis anterior', fill: '#c4565a', stroke: '#8e2f36', sw: 0.8, op: 0.85) { |t| tube(t, [[161, 606], [166, 660], [170, 740]], [6, 6, 1.6]) }
    pair('mu_gastroc', 'muscles', 'gastrocnemius (lateral + medial heads)', fill: '#b84a4f', stroke: '#8e2f36', sw: 0.8, op: 0.8) do |t|
      Geo.compose(shp(t, [[156, 600], [146, 625], [146, 660], [156, 694], [162, 650], [162, 612]]),
                  shp(t, [[178, 600], [187, 625], [186, 662], [178, 698], [172, 654], [172, 612]]))
    end
    add('mu_diaphragm', 'muscles', 'Diaphragm', Geo.sym_closed([[200, 222], [172, 215], [148, 224], [137, 242], [152, 247], [176, 242], [200, 244]]),
        fill: '#e08f84', stroke: '#8e2f36', sw: 0.8, op: 0.7)
  end

  # ---------------------------------------------------------------- ORGANS
  def organ(id, label, d, fill, stroke, op = 0.88, sw: 1, **o) = add(id, 'organs', label, d, fill: fill, stroke: stroke, sw: sw, op: op, **o)

  def build_organs
    organ('or_thyroid', 'Thyroid', Geo.compose(Geo.closed([[198, 143], [190, 140], [185, 146], [189, 153], [197, 150]]), Geo.closed([[202, 143], [210, 140], [215, 146], [211, 153], [203, 150]])), '#b8785a', '#80503a')
    organ('or_trachea', 'Trachea & main bronchi', Geo.compose(Geo.tube([[200, 134], [200, 176]], 4.2), Geo.tube([[199, 176], [188, 188], [174, 200]], [3, 2.6, 1.8]), Geo.tube([[201, 176], [213, 188], [226, 202]], [3, 2.6, 1.8])), '#d4dcea', '#8795ad', 0.95)
    organ('or_lung_r', 'Right lung', Geo.closed([[194, 178], [180, 173], [158, 177], [142, 195], [136, 226], [140, 246], [158, 255], [184, 251], [194, 240], [192, 210]]), '#f5b9bd', '#c77a86', 0.82)
    organ('or_lung_l', 'Left lung', Geo.closed([[206, 178], [220, 173], [242, 177], [258, 195], [264, 226], [260, 246], [242, 255], [226, 251], [222, 236], [213, 214], [207, 200]]), '#f5b9bd', '#c77a86', 0.82)
    organ('or_esophagus', 'Oesophagus', Geo.tube([[200, 150], [201, 200], [206, 238], [211, 254]], 2.8), '#d9867a', '#a45a4e', 0.9)
    organ('or_liver', 'Liver', Geo.closed([[142, 252], [158, 244], [184, 244], [212, 252], [224, 262], [206, 267], [190, 283], [170, 293], [150, 289], [138, 272]]), '#a8513d', '#6e2f23', 0.92)
    organ('or_gallbladder', 'Gallbladder', Geo.closed([[165, 283], [173, 282], [175, 296], [168, 303]]), '#6ba84f', '#3f6b2d', 0.95)
    organ('or_pancreas', 'Pancreas', Geo.tube([[178, 298], [204, 299], [236, 291], [252, 282]], [6.5, 5, 4, 3]), '#e9c46a', '#a88532', 0.92)
    organ('or_stomach', 'Stomach', Geo.closed([[214, 255], [236, 250], [252, 266], [253, 290], [240, 306], [221, 307], [211, 296], [208, 289], [220, 292], [231, 284], [230, 270], [214, 266]]), '#e79a8f', '#b0564e', 0.92)
    organ('or_spleen', 'Spleen', Geo.closed([[256, 252], [266, 256], [269, 276], [261, 291], [255, 276]]), '#8a3f5a', '#552136', 0.92)
    kidney = ->(t) { Geo.closed([[176, 258], [186, 262], [190, 276], [185, 292], [176, 297], [181, 278]].map { |p| t.call(p) }) }
    organ('or_kidney_r', 'Right kidney', kidney.call(->(p) { [p[0], p[1] + 3] }), '#9c4a4f', '#5f2a2f', 0.92)
    organ('or_kidney_l', 'Left kidney', kidney.call(->(p) { Geo.mx(p) }), '#9c4a4f', '#5f2a2f', 0.92)
    pair('or_ureter', 'organs', 'ureter', fill: nil, stroke: '#e0b84a', sw: 1.6, op: 0.9) { |t| line(t, [[184, 296], [186, 322], [189, 352], [193, 374], [196, 384]]) }
    # intestines
    rows = 6.times.map do |r|
      y = 322 + r * 11.5
      xs = (0..6).map { |k| [176 + k * 8.0 + (r.odd? ? 0 : 0), y + (k.even? ? -3.5 : 3.5)] }
      xs = xs.reverse if r.odd?
      xs
    end
    coil = rows.flatten(1)
    organ('or_small_int', 'Small intestine', Geo.line(coil), nil, '#e9a58f', 0.95, sw: 7)
    organ('or_small_int_sh', 'Small intestine (highlight)', Geo.line(coil), nil, '#f6cdb9', 0.9, sw: 2.6)
    colon = Geo.line([[168, 378], [164, 350], [160, 322], [158, 302], [172, 311], [200, 318], [228, 311], [244, 300],
                      [250, 330], [248, 360], [244, 383], [234, 396], [221, 390], [213, 400], [206, 398], [204, 412]])
    organ('or_colon', 'Large intestine (colon & rectum)', colon, nil, '#c98a6a', 0.95, sw: 11)
    organ('or_colon_haustra', 'Colon haustra (dash overlay)', colon, nil, '#9a6248', 0.8, sw: 11, dash: '1.6 7.5')
    organ('or_heart_r', 'Heart - right atrium & ventricle', Geo.closed([[196, 218], [204, 208], [214, 210], [213, 240], [219, 256], [204, 252], [196, 238]]), '#8d7bc0', '#52467f', 0.92)
    organ('or_heart_l', 'Heart - left atrium & ventricle', Geo.closed([[214, 212], [228, 210], [240, 226], [241, 244], [231, 262], [219, 256], [213, 240]]), '#c4424f', '#7d2230', 0.92)
    organ('or_bladder', 'Urinary bladder', Geo.closed([[200, 376], [210, 380], [214, 392], [208, 403], [200, 406], [192, 403], [186, 392], [190, 380]]), '#f3d36a', '#a8862b', 0.92)
  end

  # ----------------------------------------------------------- ARTERIES
  def artery(id, label, d, w, color = '#d1222f', op = 0.95, **o) = add(id, 'arteries', label, d, stroke: color, sw: w, op: op, **o)

  def build_arteries
    artery('ar_aorta', 'Aorta (ascending, arch, descending)', Geo.line([[209, 216], [207, 196], [211, 181], [222, 180], [228, 190], [224, 206], [214, 224], [209, 262], [207, 300], [205, 322]]), 5.6)
    artery('ar_brachiocephalic', 'Brachiocephalic trunk & right subclavian', Geo.line([[209, 186], [200, 178], [190, 172], [172, 168], [148, 170], [128, 176], [116, 186]]), 3.4)
    artery('ar_subclavian_l', 'Left subclavian artery', Geo.line([[224, 182], [236, 173], [256, 170], [272, 176], [284, 186]]), 3.4)
    artery('ar_carotid_r', 'Right common carotid', Geo.line([[190, 174], [190, 150], [189, 128]]), 2.8)
    artery('ar_carotid_l', 'Left common carotid', Geo.line([[214, 182], [212, 150], [211, 128]]), 2.8)
    artery('ar_icarotid_r', 'Right internal carotid', Geo.line([[189, 128], [188, 110], [190, 94]]), 2)
    artery('ar_ecarotid_r', 'Right external carotid', Geo.line([[189, 128], [180, 116], [172, 102], [170, 88]]), 1.6)
    artery('ar_icarotid_l', 'Left internal carotid', Geo.line([[211, 128], [212, 110], [210, 94]]), 2)
    artery('ar_ecarotid_l', 'Left external carotid', Geo.line([[211, 128], [220, 116], [228, 102], [230, 88]]), 1.6)
    pair('ar_brachial', 'arteries', 'brachial artery', stroke: '#d1222f', sw: 3, op: 0.95) { |t| line(t, [[116, 186], [110, 220], [103, 270], [98, 310], [96, 322]]) }
    pair('ar_radial', 'arteries', 'radial artery', stroke: '#d1222f', sw: 2, op: 0.95) { |t| line(t, [[96, 322], [88, 350], [80, 400], [72, 444], [67, 458]]) }
    pair('ar_ulnar', 'arteries', 'ulnar artery', stroke: '#d1222f', sw: 2, op: 0.95) { |t| line(t, [[96, 322], [98, 350], [94, 396], [84, 440], [80, 456]]) }
    pair('ar_palmar', 'arteries', 'palmar arch & digital arteries', stroke: '#d1222f', sw: 1.2, op: 0.9) do |t|
      Geo.compose(line(t, [[67, 458], [70, 466], [78, 467], [80, 456]]), line(t, [[68, 466], [63, 490], [62, 512]]), line(t, [[73, 468], [72, 494], [72, 516]]),
                  line(t, [[78, 468], [80, 490], [82, 510]]), line(t, [[66, 462], [58, 476], [56, 486]]))
    end
    add('ar_coronary', 'arteries', 'Coronary arteries', Geo.compose(Geo.line([[211, 210], [222, 209], [234, 219], [238, 238]]), Geo.line([[211, 210], [203, 216], [200, 230], [204, 246]])),
        stroke: '#d1222f', sw: 1.5, op: 0.95)
    add('ar_pulmonary', 'arteries', 'Pulmonary trunk & arteries', Geo.compose(Geo.line([[218, 214], [214, 200], [208, 193]]), Geo.line([[212, 200], [196, 195], [180, 195], [166, 201]]), Geo.line([[212, 200], [226, 197], [240, 199]])),
        stroke: '#8a4a9b', sw: 3, op: 0.85)
    add('ar_celiac', 'arteries', 'Celiac trunk & branches', Geo.compose(Geo.line([[207, 252], [196, 246], [182, 247]]), Geo.line([[207, 252], [222, 247], [238, 252]])), stroke: '#d1222f', sw: 1.8, op: 0.9)
    add('ar_sma', 'arteries', 'Superior mesenteric artery', Geo.line([[207, 268], [216, 288], [220, 318]]), stroke: '#d1222f', sw: 1.8, op: 0.9)
    add('ar_renal_r', 'arteries', 'Right renal artery', Geo.line([[207, 276], [196, 278], [187, 283]]), stroke: '#d1222f', sw: 2, op: 0.95)
    add('ar_renal_l', 'arteries', 'Left renal artery', Geo.line([[207, 276], [217, 276], [226, 280]]), stroke: '#d1222f', sw: 2, op: 0.95)
    add('ar_iliac_r', 'arteries', 'Right common/external iliac artery', Geo.line([[205, 322], [195, 338], [184, 356], [174, 376]]), stroke: '#d1222f', sw: 3.6, op: 0.95)
    add('ar_iliac_l', 'arteries', 'Left common/external iliac artery', Geo.line([[205, 322], [214, 338], [222, 356], [226, 376]]), stroke: '#d1222f', sw: 3.6, op: 0.95)
    pair('ar_internal_iliac', 'arteries', 'internal iliac artery', stroke: '#d1222f', sw: 2, op: 0.9) { |t| line(t, [[186, 350], [190, 368], [195, 384]]) }
    pair('ar_femoral', 'arteries', 'femoral artery', stroke: '#d1222f', sw: 3.2, op: 0.95) { |t| line(t, [[174, 376], [173, 410], [174, 470], [174, 530], [172, 570], [170, 590]]) }
    pair('ar_profunda', 'arteries', 'profunda femoris artery', stroke: '#d1222f', sw: 2, op: 0.9) { |t| line(t, [[174, 392], [164, 420], [158, 470], [158, 520]]) }
    pair('ar_ant_tibial', 'arteries', 'anterior tibial artery', stroke: '#d1222f', sw: 1.9, op: 0.95) { |t| line(t, [[170, 592], [163, 615], [163, 660], [165, 720], [170, 770], [174, 790]]) }
    pair('ar_post_tibial', 'arteries', 'posterior tibial artery', stroke: '#d1222f', sw: 1.9, op: 0.95) { |t| line(t, [[170, 592], [172, 630], [174, 700], [176, 752], [177, 772]]) }
  end

  # --------------------------------------------------------------- VEINS
  DEEP = '#1d4ea3'
  SUP = '#6fa8dc'

  def vein(id, label, d, w, color = DEEP, op = 0.92, **o) = add(id, 'veins', label, d, stroke: color, sw: w, op: op, **o)

  def build_veins
    vein('ve_ivc', 'Inferior vena cava', Geo.line([[199, 324], [198, 300], [197, 270], [197, 246], [199, 228]]), 8.5)
    vein('ve_iliac_r', 'Right common/external iliac vein', Geo.line([[199, 324], [193, 342], [187, 360], [181, 378]]), 5.6)
    vein('ve_iliac_l', 'Left common/external iliac vein', Geo.line([[219, 378], [216, 354], [208, 338], [199, 324]]), 5.6)
    pair('ve_internal_iliac', 'veins', 'internal iliac vein', stroke: DEEP, sw: 3, op: 0.9) { |t| line(t, [[190, 352], [194, 368], [198, 382]]) }
    pair('ve_femoral', 'veins', 'femoral vein', stroke: DEEP, sw: 4.8, op: 0.92) { |t| line(t, [[181, 378], [182, 410], [182, 470], [180, 530], [177, 570], [173, 590]]) }
    pair('ve_profunda', 'veins', 'deep femoral vein', stroke: DEEP, sw: 3, op: 0.9) { |t| line(t, [[182, 404], [168, 430], [162, 470], [162, 510]]) }
    pair('ve_popliteal', 'veins', 'popliteal vein', stroke: DEEP, sw: 3.8, op: 0.92) { |t| line(t, [[173, 590], [172, 610], [172, 650]]) }
    pair('ve_post_tibial', 'veins', 'posterior tibial vein', stroke: DEEP, sw: 2.6, op: 0.9) { |t| line(t, [[172, 606], [175, 650], [177, 710], [178, 750], [178, 770]]) }
    pair('ve_ant_tibial', 'veins', 'anterior tibial vein', stroke: DEEP, sw: 2.6, op: 0.9) { |t| line(t, [[172, 604], [165, 630], [165, 680], [168, 740], [172, 780]]) }
    pair('ve_ijv', 'veins', 'internal jugular vein', stroke: DEEP, sw: 4.0, op: 0.92) { |t| line(t, [[186, 98], [187, 116], [188, 138], [190, 158], [194, 170]]) }
    pair('ve_ejv', 'veins', 'external jugular vein', stroke: '#3f7fc8', sw: 2.4, op: 0.8) { |t| line(t, [[172, 100], [176, 118], [181, 138], [178, 154], [172, 164]]) }
    vein('ve_brachio_r', 'Right subclavian / brachiocephalic vein', Geo.line([[118, 188], [132, 176], [152, 170], [172, 168], [190, 168], [196, 176], [198, 188]]), 4.2)
    vein('ve_brachio_l', 'Left subclavian / brachiocephalic vein', Geo.line([[282, 188], [268, 176], [248, 170], [226, 170], [212, 174], [203, 180], [198, 188]]), 4.2)
    vein('ve_svc', 'Superior vena cava', Geo.line([[198, 184], [199, 200], [200, 216], [200, 228]]), 7.2)
    pair('ve_brachial', 'veins', 'brachial / axillary vein', stroke: DEEP, sw: 3.2, op: 0.9) { |t| line(t, [[118, 190], [114, 224], [108, 270], [103, 310], [101, 322]]) }
    pair('ve_radial', 'veins', 'radial vein', stroke: DEEP, sw: 1.9, op: 0.88) { |t| line(t, [[101, 322], [93, 350], [85, 400], [76, 444]]) }
    pair('ve_ulnar', 'veins', 'ulnar vein', stroke: DEEP, sw: 1.9, op: 0.88) { |t| line(t, [[101, 322], [104, 352], [99, 396], [88, 440]]) }
    pair('ve_cephalic', 'veins', 'cephalic vein (superficial)', stroke: SUP, sw: 1.4, op: 0.6) { |t| line(t, [[66, 456], [62, 430], [66, 400], [74, 356], [82, 328], [88, 300], [96, 250], [106, 205], [116, 178], [124, 170]]) }
    pair('ve_basilic', 'veins', 'basilic vein (superficial)', stroke: SUP, sw: 1.4, op: 0.6) { |t| line(t, [[84, 446], [90, 410], [96, 370], [102, 336], [108, 300], [114, 262], [118, 236]]) }
    pair('ve_gsv', 'veins', 'great saphenous vein (superficial)', stroke: SUP, sw: 1.7, op: 0.65) do |t|
      line(t, [[178, 782], [178, 758], [181, 720], [184, 676], [185, 636], [185, 600], [186, 586], [189, 548], [190, 500], [188, 460], [186, 430], [183, 410]])
    end
    pair('ve_dorsal_arch', 'veins', 'dorsal venous arch (superficial)', stroke: SUP, sw: 1.2, op: 0.6) { |t| line(t, [[160, 792], [168, 787], [178, 783]]) }
  end

  # ---------------------------------------------------------------- NERVES
  NERVE = '#e0b020'

  def nerve(id, label, d, w, color = NERVE, op = 0.95, **o) = add(id, 'nerves', label, d, stroke: color, sw: w, op: op, **o)

  def build_nerves
    brain = Geo.sym_closed([[200, 35], [184, 39], [173, 52], [170, 70], [173, 84], [183, 91], [194, 94], [200, 95]])
    add('ne_brain', 'nerves', 'Brain (cerebrum)', brain, fill: '#e9b8c4', stroke: '#b07a8a', sw: 1, op: 0.95)
    gyri = Geo.compose(Geo.line([[200, 37], [200, 93]]), Geo.line([[175, 62], [182, 56], [190, 60], [196, 54]]), Geo.line([[174, 74], [183, 68], [190, 74], [197, 68]]),
                       Geo.line([[180, 86], [188, 80], [196, 84]]), Geo.line([[178, 48], [186, 46], [192, 48]]),
                       Geo.line([[225, 62], [218, 56], [210, 60], [204, 54]]), Geo.line([[226, 74], [217, 68], [210, 74], [203, 68]]),
                       Geo.line([[220, 86], [212, 80], [204, 84]]), Geo.line([[222, 48], [214, 46], [208, 48]]))
    add('ne_gyri', 'nerves', 'Cerebral gyri & longitudinal fissure', gyri, stroke: '#b07a8a', sw: 1, op: 0.85)
    add('ne_cerebellum', 'nerves', 'Cerebellum', Geo.sym_closed([[200, 97], [190, 95], [184, 100], [188, 106], [200, 108]]), fill: '#d99aab', stroke: '#a06678', sw: 1, op: 0.95)
    add('ne_brainstem', 'nerves', 'Brainstem', Geo.tube([[200, 94], [200, 112], [200, 130]], [4.5, 3.4, 3]), fill: '#f1d37a', stroke: '#b8921f', sw: 0.8, op: 0.97)
    cord = Geo.tube([[200, 130], [200, 150], [200, 190], [200, 250], [200, 296]], [3, 4, 3, 3.4, 1.2])
    add('ne_cord', 'nerves', 'Spinal cord', cord, fill: '#f1d37a', stroke: '#b8921f', sw: 0.8, op: 0.98)
    cauda = Geo.compose(*([[-8, 0], [-4, 0], [0, 0], [4, 0], [8, 0]].map { |dx, _| Geo.line([[200, 296], [200 + dx * 0.4, 320], [200 + dx, 352], [200 + dx * 1.2, 376]]) }))
    add('ne_cauda', 'nerves', 'Cauda equina', cauda, stroke: NERVE, sw: 0.9, op: 0.9)
    pair('ne_vagus', 'nerves', 'vagus nerve', stroke: NERVE, sw: 1.5, op: 0.95) { |t| line(t, [[184, 96], [185, 130], [189, 168], [192, 200], [198, 240]]) }
    pair('ne_plexus', 'nerves', 'brachial plexus', stroke: NERVE, sw: 1.2, op: 0.95) do |t|
      Geo.compose(line(t, [[198, 140], [180, 152], [160, 164], [140, 174], [120, 186]]), line(t, [[198, 148], [182, 158], [162, 170], [142, 180], [122, 190]]),
                  line(t, [[198, 156], [184, 164], [166, 174], [146, 186], [124, 194]]))
    end
    pair('ne_median', 'nerves', 'median nerve', stroke: NERVE, sw: 1.9, op: 0.97) { |t| line(t, [[120, 190], [112, 240], [104, 296], [98, 322], [86, 380], [76, 440], [68, 468], [60, 488]]) }
    pair('ne_ulnar', 'nerves', 'ulnar nerve', stroke: NERVE, sw: 1.7, op: 0.97) { |t| line(t, [[122, 192], [119, 250], [112, 300], [104, 318], [96, 380], [86, 440], [82, 468], [86, 496]]) }
    pair('ne_radial', 'nerves', 'radial nerve', stroke: NERVE, sw: 1.7, op: 0.97) { |t| line(t, [[118, 192], [104, 240], [90, 300], [84, 330], [76, 388], [66, 440], [60, 462]]) }
    pair('ne_intercostal', 'nerves', 'intercostal nerves', stroke: '#e8c860', sw: 0.8, op: 0.85) do |t|
      (0..9).map { |i| w = [44, 52, 58, 63, 66, 68, 68, 66, 63, 58][i]; ys = 158 + i * 9.5 + 4; ye = 172 + i * 11.7 + 4
                       line(t, [[197, ys], [200 - w * 0.62, ys - 2], [200 - w, ys + 20], [200 - w * 0.78, ye + 7], [198, ye + 4]]) }.join
    end
    pair('ne_lumbosacral', 'nerves', 'lumbosacral plexus', stroke: NERVE, sw: 1.3, op: 0.95) do |t|
      Geo.compose(line(t, [[199, 270], [188, 300], [176, 332], [170, 364]]), line(t, [[199, 296], [190, 326], [180, 352], [172, 378]]), line(t, [[199, 330], [192, 350], [184, 372], [176, 392]]))
    end
    pair('ne_femoral', 'nerves', 'femoral nerve & saphenous branch', stroke: NERVE, sw: 1.8, op: 0.97) do |t|
      line(t, [[170, 364], [166, 400], [168, 440], [170, 500], [172, 560], [176, 600], [178, 660], [177, 740], [176, 782]])
    end
    pair('ne_sciatic', 'nerves', 'sciatic nerve', stroke: NERVE, sw: 3, op: 0.97) { |t| line(t, [[178, 392], [166, 412], [160, 440], [160, 490], [162, 540], [164, 582]]) }
    pair('ne_tibial', 'nerves', 'tibial nerve', stroke: NERVE, sw: 2, op: 0.97) { |t| line(t, [[164, 582], [166, 640], [170, 710], [172, 760]]) }
    pair('ne_peroneal', 'nerves', 'common & deep fibular nerve', stroke: NERVE, sw: 1.7, op: 0.97) { |t| line(t, [[164, 582], [152, 600], [148, 622], [153, 680], [158, 740], [160, 790]]) }
  end

  def build!
    MORPHS.clear
    META.clear if const_defined?(:META)
    build_skin
    build_skeleton
    build_muscles
    build_organs
    build_nerves
    build_veins
    build_arteries
    build_extras if respond_to?(:build_extras)
    MORPHS
  end
end

# ==========================================================================
# V2 EXTRAS -- pulmonary circulation, branching vessel trees (seeded),
# liver internals, extra connecting vessels/ducts.
# ==========================================================================
require 'zlib'

module Atlas
  BRANCH_SEED = 20261027          # one seed for every generated tree -> identical output on every build
  META = {}                       # id -> extra scene attributes supplied by the builders
  KIND_COLOR = {
    'artery' => '#d1222f', 'vein' => '#1d4ea3', 'pulm_a' => '#8a4a9b', 'pulm_v' => '#d96aa7',
    'portal' => '#16a085', 'hepatic_a' => '#e2552d', 'bile' => '#7cb342', 'nerve' => '#e0b020'
  }.freeze

  module_function

  def meta(id, **h) = (META[id] ||= {}).merge!(h)
  def morph(id) = MORPHS.find { |m| m[:id] == id }
  def exists?(id) = !morph(id).nil?
  def poly_of(id) = Geo.hull(Geo.path_points(morph(id)[:shape][:d]))
  def tree_rng(prefix) = Random.new(Zlib.crc32(prefix) ^ BRANCH_SEED)

  # ------------------------------------------------------------------ branching
  # Grows a binary tree. Daughter calibres follow Murray's law (d^3 = d1^3 + d2^3),
  # lengths shrink per generation, and a segment stops where it would leave `domain`.
  def grow(rng, root:, heading:, length:, d0:, levels:, domain: nil, spread: 38.0, shrink: 0.74, min_d: 0.3)
    segs = []
    rec = lambda do |p, ang, len, d, level, path, parent|
      pts = [p]
      a = ang
      cut = false
      3.times do
        a += (rng.rand - 0.5) * 18
        q = [pts.last[0] + Math.cos(a * Math::PI / 180) * len / 3, pts.last[1] + Math.sin(a * Math::PI / 180) * len / 3]
        if domain && !Geo.inside?(domain, q)
          cut = true
          break
        end
        pts << q
      end
      next if pts.size < 2
      d1 = d * (0.84 + 0.08 * rng.rand)
      segs << { path: path, pts: pts, d0: d, d1: d1, level: level, parent: parent, len: Geo.polylen(pts) }
      next if cut || level + 1 >= levels || d1 < min_d
      w = 0.5 - rng.rand * 0.14
      big = d1 * (1 - w)**(1.0 / 3)
      small = d1 * w**(1.0 / 3)
      s = rng.rand < 0.5 ? 1 : -1
      end_pt = pts.last
      rec.(end_pt, a + s * spread * 0.45 * (1 + rng.rand * 0.4), len * shrink * (0.9 + 0.25 * rng.rand), big, level + 1, path + 'a', path)
      rec.(end_pt, a - s * spread * (0.9 + rng.rand * 0.4), len * shrink * (0.8 + 0.3 * rng.rand), small, level + 1, path + 'b', path)
    end
    rec.(root, heading, length, d0, 0, '0', nil)
    segs
  end

  # Turns grown segments into morphs (layer `system`) with scene metadata.
  def emit_tree(segs, prefix:, system:, label:, kind:, parent:, flow: 1, internal: false, depth: nil, cl_levels: 2, color: nil, op: 0.95, stop_ok: true)
    color ||= KIND_COLOR[kind]
    segs.each do |s|
      id = "#{prefix}_#{s[:path]}"
      n = s[:pts].size
      widths = (0...n).map { |i| [(s[:d0] + (s[:d1] - s[:d0]) * i / (n - 1.0)) / 2, 0.2].max }
      add(id, system, "#{label} - generation #{s[:level] + 1}", Geo.tube(s[:pts], widths, 4), fill: color, stroke: nil, sw: 0, op: op)
      par = s[:parent] ? "#{prefix}_#{s[:parent]}" : parent
      meta(id, parent: par, tree: prefix, level: s[:level], diam: [s[:d0].round(2), s[:d1].round(2)], len: s[:len].round(1),
               kind: kind, internal: internal, depth: depth, flow: flow,
               cl: (s[:level] < cl_levels || s[:len] > 22 ? Geo.line(s[:pts]) : nil), branch_root: s[:parent].nil?)
    end
    segs.size
  end

  def tree(prefix, system, label, kind, parent, root:, heading:, length:, d0:, levels:, domain:, flow: 1, internal: false, depth: nil, cl_levels: 2, **o)
    segs = grow(tree_rng(prefix), root: root, heading: heading, length: length, d0: d0, levels: levels, domain: domain, **o)
    emit_tree(segs, prefix: prefix, system: system, label: label, kind: kind, parent: parent, flow: flow, internal: internal, depth: depth, cl_levels: cl_levels)
    segs
  end

  # mirrored helper for bilateral trees (patient's left = viewer right)
  def tree_pair(prefix, system, label, kind, parents, root:, heading:, domains:, **o)
    [['_r', ->(p) { p }, ->(a) { a }], ['_l', ->(p) { Geo.mx(p) }, ->(a) { 180 - a }]].each_with_index do |(suf, tp, ta), i|
      dom = domains.is_a?(Array) && domains.first.first.is_a?(Array) && domains.size == 2 ? domains[i] : domains
      tree("#{prefix}#{suf}", system, "#{label} (#{suf == '_r' ? 'right' : 'left'})", kind, parents.is_a?(Array) ? parents[i] : parents,
           root: tp.(root), heading: ta.(heading), domain: dom, **o)
    end
  end

  def mirror_poly(poly) = poly.map { |p| Geo.mx(p) }

  # ------------------------------------------------------------------ pulmonary + extra vessels
  def build_extras
    lung_r = poly_of('or_lung_r')
    lung_l = poly_of('or_lung_l')
    # existing pulmonary trunk moves to its own layer
    m = morph('ar_pulmonary')
    m[:system] = 'pulmonary'
    m[:label] = 'Pulmonary trunk & main pulmonary arteries'
    m[:stroke] = KIND_COLOR['pulm_a']
    meta('ar_pulmonary', kind: 'pulm_a')

    # pulmonary veins (trunks into the left atrium) + trees
    add('pv_trunk_r', 'pulmonary', 'Right pulmonary veins (trunk to left atrium)', Geo.line([[216, 226], [204, 220], [190, 214]]), stroke: KIND_COLOR['pulm_v'], sw: 2.6, op: 0.9)
    add('pv_trunk_l', 'pulmonary', 'Left pulmonary veins (trunk to left atrium)', Geo.line([[224, 224], [224, 216], [222, 213]]), stroke: KIND_COLOR['pulm_v'], sw: 2.4, op: 0.9)
    meta('pv_trunk_r', kind: 'pulm_v', parent: nil, flow: -1)
    meta('pv_trunk_l', kind: 'pulm_v', parent: nil, flow: -1)

    tree('pa_r1', 'pulmonary', 'Right pulmonary artery - upper branches', 'pulm_a', 'ar_pulmonary', root: [170, 201], heading: 205, length: 17, d0: 2.0, levels: 5, domain: lung_r)
    tree('pa_r2', 'pulmonary', 'Right pulmonary artery - lower branches', 'pulm_a', 'ar_pulmonary', root: [184, 196], heading: 102, length: 22, d0: 2.1, levels: 5, domain: lung_r)
    tree('pa_l1', 'pulmonary', 'Left pulmonary artery - upper branches', 'pulm_a', 'ar_pulmonary', root: [238, 199], heading: -25, length: 17, d0: 2.0, levels: 5, domain: lung_l)
    tree('pa_l2', 'pulmonary', 'Left pulmonary artery - lower branches', 'pulm_a', 'ar_pulmonary', root: [226, 198], heading: 78, length: 22, d0: 2.1, levels: 5, domain: lung_l)
    tree('pvn_r1', 'pulmonary', 'Right pulmonary vein - upper tributaries', 'pulm_v', 'pv_trunk_r', root: [190, 214], heading: 190, length: 17, d0: 2.1, levels: 5, domain: lung_r, flow: -1)
    tree('pvn_r2', 'pulmonary', 'Right pulmonary vein - lower tributaries', 'pulm_v', 'pv_trunk_r', root: [190, 214], heading: 128, length: 22, d0: 2.1, levels: 5, domain: lung_r, flow: -1)
    tree('pvn_l1', 'pulmonary', 'Left pulmonary vein - upper tributaries', 'pulm_v', 'pv_trunk_l', root: [222, 213], heading: -5, length: 17, d0: 2.0, levels: 5, domain: lung_l, flow: -1)
    tree('pvn_l2', 'pulmonary', 'Left pulmonary vein - lower tributaries', 'pulm_v', 'pv_trunk_l', root: [224, 222], heading: 50, length: 21, d0: 2.0, levels: 5, domain: lung_l, flow: -1)
    %w[pa_r1 pa_r2 pa_l1 pa_l2 pvn_r1 pvn_r2 pvn_l1 pvn_l2].each { |p| meta("#{p}_0", lung: p.end_with?('r1', 'r2') ? 'or_lung_r' : 'or_lung_l') }

    # kidneys: renal artery / vein trees
    kid_r = poly_of('or_kidney_r')
    kid_l = poly_of('or_kidney_l')
    add('ve_renal_r', 'veins', 'Right renal vein', Geo.line([[186, 287], [192, 283], [197, 279]]), stroke: DEEP, sw: 3.2, op: 0.92)
    add('ve_renal_l', 'veins', 'Left renal vein', Geo.line([[214, 289], [206, 283], [199, 280]]), stroke: DEEP, sw: 3.2, op: 0.92)
    meta('ve_renal_r', kind: 'vein')
    meta('ve_renal_l', kind: 'vein')
    tree('ar_kid_r', 'arteries', 'Right renal artery - segmental branches', 'artery', 'ar_renal_r', root: [187, 283], heading: 190, length: 9, d0: 1.6, levels: 4, domain: kid_r)
    tree('ar_kid_l', 'arteries', 'Left renal artery - segmental branches', 'artery', 'ar_renal_l', root: [213, 283], heading: -10, length: 9, d0: 1.6, levels: 4, domain: kid_l)
    tree('ve_kid_r', 'veins', 'Right renal vein - tributaries', 'vein', 've_renal_r', root: [186, 287], heading: 150, length: 9, d0: 1.9, levels: 4, domain: kid_r, flow: -1)
    tree('ve_kid_l', 'veins', 'Left renal vein - tributaries', 'vein', 've_renal_l', root: [214, 289], heading: 30, length: 9, d0: 1.9, levels: 4, domain: kid_l, flow: -1)

    # portal system outside the liver
    add('ve_portal', 'veins', 'Portal vein (extrahepatic)', Geo.line([[209, 303], [201, 288], [193, 275]]), stroke: KIND_COLOR['portal'], sw: 5, op: 0.95)
    add('ve_smv', 'veins', 'Superior mesenteric vein', Geo.line([[214, 352], [212, 328], [209, 303]]), stroke: KIND_COLOR['portal'], sw: 3.6, op: 0.92)
    add('ve_splenic', 'veins', 'Splenic vein', Geo.line([[254, 284], [238, 292], [220, 298], [209, 303]]), stroke: KIND_COLOR['portal'], sw: 3, op: 0.92)
    add('ar_hepatic', 'arteries', 'Common hepatic artery', Geo.line([[204, 252], [200, 262], [196, 270], [194, 274]]), stroke: KIND_COLOR['hepatic_a'], sw: 1.8, op: 0.95)
    %w[ve_portal ve_smv ve_splenic].each { |i| meta(i, kind: 'portal', flow: 1) }
    meta('ar_hepatic', kind: 'hepatic_a', parent: 'ar_celiac')
    gut = poly_of('or_small_int')
    tree('ve_mes', 'veins', 'Mesenteric vein tributaries', 'portal', 've_smv', root: [214, 352], heading: 92, length: 17, d0: 2.6, levels: 5, domain: gut, flow: -1)
    tree('ar_mes', 'arteries', 'Superior mesenteric artery - jejunal & ileal branches', 'artery', 'ar_sma', root: [220, 318], heading: 100, length: 18, d0: 1.7, levels: 5, domain: gut)
    meta('ve_splenic', parent: 've_portal')
    meta('ve_smv', parent: 've_portal')

    # coronary trees
    hl = poly_of('or_heart_l')
    hr = poly_of('or_heart_r')
    tree('ar_cor_l', 'arteries', 'Left coronary - descending branches', 'artery', 'ar_coronary', root: [238, 236], heading: 98, length: 9, d0: 1.0, levels: 4, domain: hl, cl_levels: 1)
    tree('ar_cor_r', 'arteries', 'Right coronary - marginal branches', 'artery', 'ar_coronary', root: [204, 245], heading: 80, length: 8, d0: 0.9, levels: 4, domain: hr, cl_levels: 1)

    # limbs and head
    arm = [[92, 204], [126, 204], [118, 314], [90, 314]]
    thigh = [[138, 404], [190, 404], [186, 566], [142, 566]]
    calf = [[152, 610], [186, 610], [182, 726], [156, 726]]
    face = [[160, 52], [186, 52], [186, 98], [158, 98]]
    tree_pair('ar_arm', 'arteries', 'Brachial artery - muscular branches', 'artery', %w[ar_brachial_r ar_brachial_l], root: [106, 246], heading: 108, length: 16, d0: 1.5, levels: 4, domains: [arm, mirror_poly(arm)])
    tree_pair('ar_thigh', 'arteries', 'Femoral artery - muscular branches', 'artery', %w[ar_femoral_r ar_femoral_l], root: [174, 440], heading: 150, length: 24, d0: 1.9, levels: 4, domains: [thigh, mirror_poly(thigh)])
    tree_pair('ar_calf', 'arteries', 'Posterior tibial artery - muscular branches', 'artery', %w[ar_post_tibial_r ar_post_tibial_l], root: [173, 640], heading: 55, length: 20, d0: 1.4, levels: 4, domains: [calf, mirror_poly(calf)])
    tree_pair('ve_thigh', 'veins', 'Femoral vein - tributaries', 'vein', %w[ve_femoral_r ve_femoral_l], root: [182, 456], heading: 32, length: 22, d0: 2.4, levels: 4, domains: [thigh, mirror_poly(thigh)], flow: -1)
    tree_pair('ar_face', 'arteries', 'External carotid - facial branches', 'artery', %w[ar_ecarotid_r ar_ecarotid_l], root: [170, 88], heading: -100, length: 14, d0: 1.1, levels: 4, domains: [face, mirror_poly(face)])

    # phrenic nerves (drive the diaphragm in the breathing animation)
    pair('ne_phrenic', 'nerves', 'phrenic nerve', stroke: NERVE, sw: 1.4, op: 0.95) { |t| line(t, [[198, 142], [189, 158], [186, 184], [184, 208], [180, 228]]) }
    %w[ne_phrenic_r ne_phrenic_l].each { |i| meta(i, kind: 'nerve', parent: 'ne_cord') }

    build_liver_internals
    build_bile_ducts_extra
  end

  # ------------------------------------------------------------------ liver internals
  # Frontal Couinaud-style division drawn from straight cut lines inside the liver outline.
  LIVER_PALETTE = {
    'I' => '#d98c8c', 'II' => '#e0a35a', 'III' => '#d9c25a', 'IVa' => '#9bc66a', 'IVb' => '#6fbf8e',
    'V' => '#5fb7c9', 'VI' => '#7a9ae0', 'VII' => '#a98ae0', 'VIII' => '#d88ac6'
  }.freeze

  def liver_cells
    xa = ->(y) { 197 - (y - 236) * 0.4394 }     # Cantlie line (right/left lobe, through the gallbladder fossa)
    xb = ->(y) { 176 - (y - 244) * 0.78 }       # right hepatic vein fissure (anterior / posterior sector)
    xf = ->(y) { 203 - (y - 238) * 0.21 }       # falciform plane (medial / lateral left)
    q = ->(*pts) { pts }
    {
      'VII' => q.([110, 225], [xb.(225), 225], [xb.(266), 266], [110, 266]),
      'VI' => q.([110, 266], [xb.(266), 266], [xb.(315), 315], [110, 315]),
      'VIII' => q.([xb.(225), 225], [xa.(225), 225], [xa.(266), 266], [xb.(266), 266]),
      'V' => q.([xb.(266), 266], [xa.(266), 266], [xa.(315), 315], [xb.(315), 315]),
      'IVa' => q.([xa.(225), 225], [xf.(225), 225], [xf.(266), 266], [xa.(266), 266]),
      'IVb' => q.([xa.(266), 266], [xf.(266), 266], [xf.(315), 315], [xa.(315), 315]),
      'II' => q.([xf.(225), 225], [270, 225], [270, 261], [xf.(261), 261]),
      'III' => q.([xf.(261), 261], [270, 261], [270, 315], [xf.(315), 315])
    }.merge('lobe_right' => q.([100, 225], [xa.(225), 225], [xa.(315), 315], [100, 315]),
            'lobe_left' => q.([xa.(225), 225], [270, 225], [270, 315], [xa.(315), 315]))
  end

  def build_liver_internals
    outline = Geo.path_polygon(morph('or_liver')[:shape][:d], 10)
    cells = liver_cells
    caudate = [[190, 251], [199.5, 250], [199, 263], [189, 264]]
    d_int = [0.14, 0.30]

    clipped = {}
    cells.each { |k, poly| clipped[k] = Geo.clip_convex(outline, poly) }
    clipped['I'] = Geo.clip_convex(outline, caudate)
    # carve the caudate lobe out of IVa so the pieces do not overlap
    seg_polys = {}
    %w[II III IVa IVb V VI VII VIII].each do |k|
      seg_polys[k] = k == 'IVa' ? Geo.clip_outside(clipped[k], caudate) : [clipped[k]]
    end
    seg_polys['I'] = [clipped['I']]

    add('lv_lobe_r', 'organs', 'Right lobe of the liver', Geo.poly_path(clipped['lobe_right']), fill: nil, stroke: '#4b1e15', sw: 1.6, op: 0.95)
    add('lv_lobe_l', 'organs', 'Left lobe of the liver', Geo.poly_path(clipped['lobe_left']), fill: nil, stroke: '#4b1e15', sw: 1.6, op: 0.95)
    add('lv_lobe_c', 'organs', 'Caudate lobe (segment I)', Geo.poly_path(clipped['I']), fill: nil, stroke: '#4b1e15', sw: 1.6, op: 0.95)
    meta('lv_lobe_r', parent: 'or_liver', internal: true, kind: 'lobe', depth: [0.13, 0.31], hierarchy: 'lobe')
    meta('lv_lobe_l', parent: 'or_liver', internal: true, kind: 'lobe', depth: [0.13, 0.31], hierarchy: 'lobe')
    meta('lv_lobe_c', parent: 'or_liver', internal: true, kind: 'lobe', depth: [0.13, 0.31], hierarchy: 'lobe')

    lobe_of = { 'I' => 'lv_lobe_c', 'II' => 'lv_lobe_l', 'III' => 'lv_lobe_l', 'IVa' => 'lv_lobe_l', 'IVb' => 'lv_lobe_l', 'V' => 'lv_lobe_r', 'VI' => 'lv_lobe_r', 'VII' => 'lv_lobe_r', 'VIII' => 'lv_lobe_r' }
    names = { 'IVb' => 'Segment IVb (quadrate)', 'I' => 'Segment I (caudate)' }
    LIVER_PALETTE.each_key do |k|
      polys = seg_polys[k].reject { |p| p.size < 3 }
      add("lv_seg_#{k}", 'organs', names[k] || "Segment #{k}", polys.map { |p| Geo.poly_path(p) }.join, fill: LIVER_PALETTE[k], stroke: '#5a2a22', sw: 0.8, op: 0.78)
      meta("lv_seg_#{k}", parent: lobe_of[k], internal: true, kind: 'segment', depth: [0.17, 0.32], hierarchy: 'segment', seg: k, poly: polys)
    end

    # --- portal triad: trunks (explicit) + twigs (seeded generator, clipped to each segment)
    pv_c = KIND_COLOR['portal']
    ha_c = KIND_COLOR['hepatic_a']
    bd_c = KIND_COLOR['bile']
    porta = [193, 275]
    trunks = {
      'r' => { pts: [porta, [183, 272], [173, 268], [164, 266]], lobe: 'lv_lobe_r' },
      'l' => { pts: [porta, [195, 267], [201, 261], [207, 257]], lobe: 'lv_lobe_l' }
    }
    trunks.each do |s, t|
      add("lv_pv_#{s}", 'veins', "#{s == 'r' ? 'Right' : 'Left'} portal vein branch", Geo.tube(t[:pts], [2.4, 2.1, 1.8, 1.5], 6), fill: pv_c, stroke: nil, sw: 0, op: 0.95)
      meta("lv_pv_#{s}", parent: t[:lobe], internal: true, kind: 'portal', depth: [0.15, 0.25], level: 0, diam: [4.8, 3.0], flow: 1, len: Geo.polylen(t[:pts]).round(1), cl: Geo.line(t[:pts]), trunk: true, vessel_parent: 've_portal')
      off = Geo.offset_line(t[:pts], 3.2)
      add("lv_ha_#{s}", 'arteries', "#{s == 'r' ? 'Right' : 'Left'} hepatic artery branch", Geo.tube(off, [0.8, 0.7, 0.6, 0.5], 6), fill: ha_c, stroke: nil, sw: 0, op: 0.95)
      meta("lv_ha_#{s}", parent: t[:lobe], internal: true, kind: 'hepatic_a', depth: [0.14, 0.24], level: 0, diam: [1.6, 1.0], flow: 1, len: Geo.polylen(off).round(1), cl: Geo.line(off), trunk: true, vessel_parent: 'ar_hepatic')
      off2 = Geo.offset_line(t[:pts], -3.2)
      add("lv_bd_#{s}", 'organs', "#{s == 'r' ? 'Right' : 'Left'} hepatic bile duct", Geo.tube(off2, [1.0, 0.9, 0.8, 0.65], 6), fill: bd_c, stroke: nil, sw: 0, op: 0.95)
      meta("lv_bd_#{s}", parent: t[:lobe], internal: true, kind: 'bile', depth: [0.1, 0.2], level: 0, diam: [2.0, 1.3], flow: -1, len: Geo.polylen(off2).round(1), cl: Geo.line(off2), trunk: true, vessel_parent: 'or_bile_duct')
    end

    roots = {
      'VIII' => { root: [170, 264], h: -98 }, 'V' => { root: [172, 271], h: 100 }, 'VII' => { root: [150, 262], h: -150 },
      'VI' => { root: [150, 270], h: 150 }, 'IVa' => { root: [187.5, 263], h: -92 }, 'IVb' => { root: [190, 270], h: 95 },
      'II' => { root: [206, 255], h: -35 }, 'III' => { root: [209, 262], h: 45 }, 'I' => { root: [192, 259], h: -80 }
    }
    roots.each do |k, r|
      dom = seg_polys[k].max_by { |p| Geo.shoelace(p).abs }
      next unless dom && dom.size >= 3
      lobe_trunk = k == 'I' ? 'lv_pv_l' : (%w[V VI VII VIII].include?(k) ? 'lv_pv_r' : 'lv_pv_l')
      prefix = "lv_pv_s#{k}"
      segs = grow(tree_rng(prefix), root: r[:root], heading: r[:h], length: 15, d0: 2.0, levels: 4, domain: dom, shrink: 0.78, min_d: 0.28)
      next if segs.empty?
      emit_tree(segs, prefix: prefix, system: 'veins', label: "Portal vein twigs, segment #{k}", kind: 'portal', parent: "lv_seg_#{k}", flow: 1, internal: true, depth: [0.15, 0.25], cl_levels: 1, color: pv_c)
      # hepatic artery and bile duct twigs run alongside each portal twig (the portal triad)
      emit_companions(segs, prefix, "lv_seg_#{k}", ha_c, bd_c)
      meta("#{prefix}_0", vessel_parent: lobe_trunk, seg: k)
    end

    # --- hepatic veins: three trunks into the IVC, with side branches
    hv = {
      'r' => { pts: [[197, 247], [188, 258], [176, 270], [164, 281], [152, 290]], label: 'Right hepatic vein' },
      'm' => { pts: [[197, 247], [192, 258], [186, 269], [180, 281], [176, 292]], label: 'Middle hepatic vein' },
      'l' => { pts: [[198, 246], [204, 250], [211, 255], [218, 260]], label: 'Left hepatic vein' }
    }
    hv.each do |k, h|
      pts = h[:pts]
      n = pts.size
      widths = (0...n).map { |i| 1.9 - 1.0 * i / (n - 1.0) }
      add("lv_hv_#{k}", 'veins', h[:label], Geo.tube(pts, widths, 6), fill: KIND_COLOR['vein'], stroke: nil, sw: 0, op: 0.95)
      meta("lv_hv_#{k}", parent: { 'r' => 'lv_lobe_r', 'm' => 'lv_lobe_r', 'l' => 'lv_lobe_l' }[k], internal: true, kind: 'vein', depth: [0.2, 0.32], level: 0, diam: [3.8, 1.8], flow: -1,
                          len: Geo.polylen(pts).round(1), cl: Geo.line(pts), trunk: true, vessel_parent: 've_ivc')
      # side tributaries, alternating, grown into the liver outline
      [0.35, 0.7].each_with_index do |frac, j|
        i = (frac * (n - 1)).floor
        base = pts[i]
        ang = Math.atan2(pts[i + 1][1] - pts[i][1], pts[i + 1][0] - pts[i][0]) * 180 / Math::PI
        side = j.even? ? 55 : -55
        prefix = "lv_hv_#{k}t#{j}"
        segs = grow(tree_rng(prefix), root: base, heading: ang + side, length: 11, d0: 1.15, levels: 3, domain: outline, shrink: 0.78, min_d: 0.28)
        next if segs.empty?
        emit_tree(segs, prefix: prefix, system: 'veins', label: "#{h[:label]} tributaries", kind: 'vein', parent: "lv_hv_#{k}", flow: -1, internal: true, depth: [0.2, 0.32], cl_levels: 1)
      end
    end
  end

  def emit_companions(segs, prefix, seg_id, ha_c, bd_c)
    ha = segs.map { |s| s.merge(pts: Geo.offset_line(s[:pts], 2.0), d0: [s[:d0] * 0.4, 0.4].max, d1: [s[:d1] * 0.4, 0.4].max) }
    bd = segs.map { |s| s.merge(pts: Geo.offset_line(s[:pts], -2.0), d0: [s[:d0] * 0.45, 0.45].max, d1: [s[:d1] * 0.45, 0.45].max) }
    pp = prefix.sub('lv_pv_', '')
    emit_tree(ha, prefix: "lv_ha_#{pp}", system: 'arteries', label: "Hepatic artery twigs, #{seg_id.sub('lv_seg_', 'segment ')}", kind: 'hepatic_a', parent: seg_id, flow: 1, internal: true, depth: [0.14, 0.24], cl_levels: 1, color: ha_c)
    emit_tree(bd, prefix: "lv_bd_#{pp}", system: 'organs', label: "Bile duct twigs, #{seg_id.sub('lv_seg_', 'segment ')}", kind: 'bile', parent: seg_id, flow: -1, internal: true, depth: [0.1, 0.2], cl_levels: 1, color: bd_c)
  end

  # extrahepatic bile ducts: common bile duct and cystic duct (always visible, not hidden internals)
  def build_bile_ducts_extra
    add('or_bile_duct', 'organs', 'Common bile duct', Geo.tube([[193, 276], [195, 286], [199, 294], [204, 299]], [1.5, 1.5, 1.6, 1.6], 6), fill: KIND_COLOR['bile'], stroke: '#4d7a1f', sw: 0.5, op: 0.97)
    add('or_cystic_duct', 'organs', 'Cystic duct', Geo.tube([[172, 288], [180, 284], [189, 283], [195, 284]], [1.0, 1.0, 1.1, 1.3], 6), fill: KIND_COLOR['bile'], stroke: '#4d7a1f', sw: 0.5, op: 0.97)
    meta('or_bile_duct', kind: 'bile', parent: nil, flow: 1, depth: [0.4, 0.5], len: 34.0, diam: [3.0, 3.2], cl: Geo.line([[193, 276], [195, 286], [199, 294], [204, 299]]), duct: true)
    meta('or_cystic_duct', kind: 'bile', parent: 'or_bile_duct', flow: -1, depth: [0.36, 0.46], len: 26.0, diam: [2.0, 2.6], cl: Geo.line([[172, 288], [180, 284], [189, 283], [195, 284]]), duct: true)
  end
end

# ==========================================================================
# SCENE GRAPH -- every morph gets a coordinate frame, an anatomical parent,
# a geometric boundary, a depth range and connections to its neighbours.
# ==========================================================================
module Scene
  # Pseudo-nodes that group morphs by body region (not drawn, shown in the Anatomy tree).
  REGIONS = [
    { id: 'rg_body',   label: 'Body',        parent: nil },
    { id: 'rg_head',   label: 'Head',        parent: 'rg_body' },
    { id: 'rg_neck',   label: 'Neck',        parent: 'rg_body' },
    { id: 'rg_thorax', label: 'Thorax',      parent: 'rg_body' },
    { id: 'rg_abdomen', label: 'Abdomen',    parent: 'rg_body' },
    { id: 'rg_pelvis', label: 'Pelvis',      parent: 'rg_body' },
    { id: 'rg_arm',    label: 'Upper limbs', parent: 'rg_body' },
    { id: 'rg_leg',    label: 'Lower limbs', parent: 'rg_body' }
  ].freeze

  def self.region_of(cx, cy)
    return 'rg_head' if cy < 108
    return 'rg_neck' if cy < 170 && (cx - 200).abs < 38
    return 'rg_arm' if (cx - 200).abs > 62 && cy < 520
    return 'rg_leg' if cy > 412
    return 'rg_thorax' if cy < 258
    return 'rg_abdomen' if cy < 328
    return 'rg_pelvis' if cy < 416
    'rg_thorax'
  end

  # child base id => parent base id (paired ids follow the same _r/_l side)
  PARENT_BASES = {
    'skin_face' => 'skin_body', 'skin_marks' => 'skin_body', 'skin_neckline' => 'skin_body',
    'sk_sutures' => 'sk_cranium', 'sk_orbit' => 'sk_cranium', 'sk_nasal' => 'sk_cranium', 'sk_mandible' => 'sk_cranium',
    'sk_ribs' => 'sk_thoracic', 'sk_sternum' => 'sk_thoracic', 'sk_clavicle' => 'sk_sternum', 'sk_scapula' => 'sk_clavicle',
    'sk_humerus' => 'sk_scapula', 'sk_radius' => 'sk_humerus', 'sk_ulna' => 'sk_humerus', 'sk_hand' => 'sk_radius',
    'sk_hip' => 'sk_sacrum', 'sk_femur' => 'sk_hip', 'sk_patella' => 'sk_femur', 'sk_tibia' => 'sk_femur', 'sk_fibula' => 'sk_tibia', 'sk_foot' => 'sk_tibia',
    'mu_scm' => 'sk_sternum', 'mu_trap' => 'sk_scapula', 'mu_pectoralis' => 'sk_sternum', 'mu_deltoid' => 'sk_humerus', 'mu_serratus' => 'sk_ribs',
    'mu_biceps' => 'sk_humerus', 'mu_brachioradialis' => 'sk_radius', 'mu_flexors' => 'sk_ulna', 'mu_rectus_abd' => 'sk_hip', 'mu_abd_lines' => 'mu_rectus_abd',
    'mu_oblique' => 'sk_ribs', 'mu_glute_med' => 'sk_hip', 'mu_psoas' => 'sk_lumbar', 'mu_rectus_fem' => 'sk_hip', 'mu_vastus_lat' => 'sk_femur', 'mu_vastus_med' => 'sk_femur',
    'mu_adductor' => 'sk_hip', 'mu_sartorius' => 'sk_hip', 'mu_gracilis' => 'sk_hip', 'mu_tib_ant' => 'sk_tibia', 'mu_gastroc' => 'sk_femur',
    'or_small_int_sh' => 'or_small_int', 'or_colon_haustra' => 'or_colon', 'or_ureter' => 'or_kidney',
    'ne_gyri' => 'ne_brain', 'ne_cerebellum' => 'ne_brain', 'ne_brainstem' => 'ne_brain', 'ne_cord' => 'ne_brainstem', 'ne_cauda' => 'ne_cord',
    'ne_vagus' => 'ne_brainstem', 'ne_plexus' => 'ne_cord', 'ne_median' => 'ne_plexus', 'ne_ulnar' => 'ne_plexus', 'ne_radial' => 'ne_plexus',
    'ne_intercostal' => 'ne_cord', 'ne_lumbosacral' => 'ne_cord', 'ne_femoral' => 'ne_lumbosacral', 'ne_sciatic' => 'ne_lumbosacral', 'ne_tibial' => 'ne_sciatic', 'ne_peroneal' => 'ne_sciatic',
    'ar_brachiocephalic' => 'ar_aorta', 'ar_subclavian_l' => 'ar_aorta', 'ar_carotid_r' => 'ar_brachiocephalic', 'ar_carotid_l' => 'ar_aorta',
    'ar_icarotid' => 'ar_carotid', 'ar_ecarotid' => 'ar_carotid', 'ar_brachial' => 'ar_subclavian', 'ar_radial' => 'ar_brachial', 'ar_ulnar' => 'ar_brachial', 'ar_palmar' => 'ar_radial',
    'ar_coronary' => 'ar_aorta', 'ar_celiac' => 'ar_aorta', 'ar_sma' => 'ar_aorta', 'ar_renal' => 'ar_aorta', 'ar_iliac' => 'ar_aorta',
    'ar_internal_iliac' => 'ar_iliac', 'ar_femoral' => 'ar_iliac', 'ar_profunda' => 'ar_femoral', 'ar_ant_tibial' => 'ar_femoral', 'ar_post_tibial' => 'ar_femoral',
    've_iliac' => 've_ivc', 've_internal_iliac' => 've_iliac', 've_femoral' => 've_iliac', 've_profunda' => 've_femoral', 've_popliteal' => 've_femoral',
    've_post_tibial' => 've_popliteal', 've_ant_tibial' => 've_popliteal', 've_ijv' => 've_brachio', 've_ejv' => 've_ijv', 've_brachio' => 've_svc',
    've_brachial' => 've_brachio', 've_radial' => 've_brachial', 've_ulnar' => 've_brachial', 've_cephalic' => 've_brachio', 've_basilic' => 've_brachial',
    've_gsv' => 've_femoral', 've_dorsal_arch' => 've_gsv', 've_renal' => 've_ivc',
    # the great vessels hang off the heart
    've_svc' => 'or_heart_r', 've_ivc' => 'or_heart_r', 'ar_aorta' => 'or_heart_l', 'ar_pulmonary' => 'or_heart_r',
    'pv_trunk_r' => 'or_heart_l', 'pv_trunk_l' => 'or_heart_l'
  }.freeze
  # single-sided overrides where the side suffix of the parent differs from the child's
  FIXED_PARENT = { 'ar_brachial_r' => 'ar_brachiocephalic', 'ar_brachial_l' => 'ar_subclavian_l', 'ar_carotid_r' => 'ar_brachiocephalic',
                   'ar_ecarotid_r' => 'ar_carotid_r', 'ar_icarotid_r' => 'ar_carotid_r', 'ar_ecarotid_l' => 'ar_carotid_l', 'ar_icarotid_l' => 'ar_carotid_l',
                   'ar_renal_r' => 'ar_aorta', 'ar_renal_l' => 'ar_aorta', 'or_ureter_r' => 'or_kidney_r', 'or_ureter_l' => 'or_kidney_l' }.freeze

  # estimated front-to-back extent (0 = front of body, 1 = back) as one or more [near, far] intervals
  DEPTH = {
    'skin_body' => [0.0, 0.05], 'skin_face' => [0.0, 0.05], 'skin_marks' => [0.0, 0.05], 'skin_neckline' => [0.0, 0.05],
    'sk_cranium' => [0.1, 0.9], 'sk_sutures' => [0.1, 0.9], 'sk_orbit' => [0.1, 0.25], 'sk_nasal' => [0.08, 0.2], 'sk_mandible' => [0.1, 0.45],
    'sk_cervical' => [0.65, 0.9], 'sk_thoracic' => [0.72, 0.95], 'sk_lumbar' => [0.7, 0.95], 'sk_sacrum' => [0.75, 0.95], 'sk_sternum' => [0.06, 0.14],
    'sk_ribs' => [[0.08, 0.2], [0.8, 0.93]], 'sk_clavicle' => [0.1, 0.2], 'sk_scapula' => [0.72, 0.88], 'sk_hip' => [0.4, 0.85],
    'sk_humerus' => [0.35, 0.65], 'sk_radius' => [0.35, 0.65], 'sk_ulna' => [0.35, 0.65], 'sk_hand' => [0.35, 0.65],
    'sk_femur' => [0.35, 0.65], 'sk_patella' => [0.2, 0.32], 'sk_tibia' => [0.35, 0.65], 'sk_fibula' => [0.4, 0.7], 'sk_foot' => [0.3, 0.7],
    'mu_scm' => [0.15, 0.35], 'mu_trap' => [0.8, 0.95], 'mu_pectoralis' => [0.05, 0.2], 'mu_deltoid' => [0.2, 0.55], 'mu_serratus' => [0.2, 0.5],
    'mu_biceps' => [0.1, 0.35], 'mu_brachioradialis' => [0.25, 0.45], 'mu_flexors' => [0.2, 0.45], 'mu_rectus_abd' => [0.05, 0.2], 'mu_abd_lines' => [0.05, 0.2],
    'mu_oblique' => [0.1, 0.35], 'mu_glute_med' => [0.75, 0.95], 'mu_psoas' => [0.65, 0.85], 'mu_rectus_fem' => [0.1, 0.3], 'mu_vastus_lat' => [0.2, 0.5],
    'mu_vastus_med' => [0.2, 0.5], 'mu_adductor' => [0.4, 0.62], 'mu_sartorius' => [0.1, 0.25], 'mu_gracilis' => [0.45, 0.6], 'mu_tib_ant' => [0.1, 0.35],
    'mu_gastroc' => [0.7, 0.92], 'mu_diaphragm' => [0.4, 0.62],
    'or_thyroid' => [0.12, 0.28], 'or_trachea' => [0.5, 0.7], 'or_lung_r' => [0.2, 0.8], 'or_lung_l' => [0.2, 0.8], 'or_esophagus' => [0.58, 0.7],
    'or_liver' => [0.12, 0.55], 'or_gallbladder' => [0.16, 0.34], 'or_pancreas' => [0.5, 0.66], 'or_stomach' => [0.2, 0.6], 'or_spleen' => [0.6, 0.85],
    'or_kidney_r' => [0.68, 0.88], 'or_kidney_l' => [0.68, 0.88], 'or_ureter' => [0.78, 0.88], 'or_small_int' => [0.28, 0.62], 'or_small_int_sh' => [0.28, 0.62],
    'or_colon' => [0.25, 0.65], 'or_colon_haustra' => [0.25, 0.65], 'or_heart_r' => [0.12, 0.5], 'or_heart_l' => [0.12, 0.5], 'or_bladder' => [0.3, 0.55],
    'ar_aorta' => [0.62, 0.8], 've_ivc' => [0.66, 0.82], 've_svc' => [0.5, 0.68], 'ar_pulmonary' => [0.4, 0.62],
    've_gsv' => [0.08, 0.2], 've_cephalic' => [0.06, 0.16], 've_basilic' => [0.06, 0.16], 've_dorsal_arch' => [0.06, 0.16], 've_ejv' => [0.1, 0.25],
    'ne_brain' => [0.2, 0.8], 'ne_gyri' => [0.2, 0.3], 'ne_cerebellum' => [0.6, 0.9], 'ne_brainstem' => [0.6, 0.85], 'ne_cord' => [0.82, 0.93], 'ne_cauda' => [0.82, 0.93],
    'ne_sciatic' => [0.65, 0.85], 'ne_intercostal' => [[0.1, 0.2], [0.8, 0.92]]
  }.freeze
  DEPTH_SYSTEM = { 'skin' => [0.0, 0.05], 'skeleton' => [0.3, 0.7], 'muscles' => [0.2, 0.5], 'organs' => [0.3, 0.6], 'arteries' => [0.45, 0.62],
                   'veins' => [0.4, 0.6], 'pulmonary' => [0.35, 0.65], 'nerves' => [0.45, 0.62] }.freeze

  # unit connections: [from, to, kind]   (kinds: supplies, drains, innervates, conducts, continues, attached)
  CONNECTIONS = [
    ['ar_aorta', 'or_heart_l', 'supplies'], ['ar_pulmonary', 'or_heart_r', 'drains'], ['ar_pulmonary', 'or_lung_r', 'supplies'], ['ar_pulmonary', 'or_lung_l', 'supplies'],
    ['pv_trunk_r', 'or_lung_r', 'drains'], ['pv_trunk_l', 'or_lung_l', 'drains'], ['pv_trunk_r', 'or_heart_l', 'drains'], ['pv_trunk_l', 'or_heart_l', 'drains'],
    ['ve_svc', 'or_heart_r', 'drains'], ['ve_ivc', 'or_heart_r', 'drains'],
    ['ar_coronary', 'or_heart_l', 'supplies'], ['ar_coronary', 'or_heart_r', 'supplies'],
    ['ar_hepatic', 'or_liver', 'supplies'], ['ar_celiac', 'or_stomach', 'supplies'], ['ar_celiac', 'or_spleen', 'supplies'], ['ar_sma', 'or_small_int', 'supplies'],
    ['ar_renal_r', 'or_kidney_r', 'supplies'], ['ar_renal_l', 'or_kidney_l', 'supplies'],
    ['or_kidney_r', 've_renal_r', 'drains'], ['or_kidney_l', 've_renal_l', 'drains'], ['ve_renal_r', 've_ivc', 'drains'], ['ve_renal_l', 've_ivc', 'drains'],
    ['ve_portal', 'or_liver', 'supplies'], ['ve_smv', 've_portal', 'continues'], ['ve_splenic', 've_portal', 'continues'],
    ['or_spleen', 've_splenic', 'drains'], ['or_pancreas', 've_splenic', 'drains'], ['or_small_int', 've_smv', 'drains'],
    ['or_liver', 've_ivc', 'drains'], ['or_liver', 'or_bile_duct', 'drains'], ['or_gallbladder', 'or_cystic_duct', 'drains'], ['or_cystic_duct', 'or_bile_duct', 'continues'],
    ['or_bile_duct', 'or_pancreas', 'drains'],
    ['or_ureter_r', 'or_bladder', 'drains'], ['or_ureter_l', 'or_bladder', 'drains'],
    ['or_esophagus', 'or_stomach', 'continues'], ['or_stomach', 'or_small_int', 'continues'], ['or_small_int', 'or_colon', 'continues'],
    ['or_trachea', 'or_lung_r', 'conducts'], ['or_trachea', 'or_lung_l', 'conducts'],
    ['ne_vagus_r', 'or_heart_r', 'innervates'], ['ne_vagus_l', 'or_heart_l', 'innervates'], ['ne_vagus_r', 'or_lung_r', 'innervates'], ['ne_vagus_l', 'or_lung_l', 'innervates'],
    ['ne_vagus_l', 'or_stomach', 'innervates'], ['ne_vagus_r', 'or_liver', 'innervates'],
    ['ne_phrenic_r', 'mu_diaphragm', 'innervates'], ['ne_phrenic_l', 'mu_diaphragm', 'innervates'],
    ['ne_lumbosacral_r', 'or_bladder', 'innervates'], ['ne_lumbosacral_l', 'or_bladder', 'innervates'],
    ['ne_median_r', 'mu_flexors_r', 'innervates'], ['ne_median_l', 'mu_flexors_l', 'innervates'], ['ne_radial_r', 'mu_brachioradialis_r', 'innervates'], ['ne_radial_l', 'mu_brachioradialis_l', 'innervates'],
    ['ne_femoral_r', 'mu_rectus_fem_r', 'innervates'], ['ne_femoral_l', 'mu_rectus_fem_l', 'innervates'], ['ne_peroneal_r', 'mu_tib_ant_r', 'innervates'], ['ne_peroneal_l', 'mu_tib_ant_l', 'innervates'],
    ['ne_tibial_r', 'mu_gastroc_r', 'innervates'], ['ne_tibial_l', 'mu_gastroc_l', 'innervates'],
    ['ne_intercostal_r', 'mu_serratus_r', 'innervates'], ['ne_intercostal_l', 'mu_serratus_l', 'innervates'],
    # trees that feed particular organs
    ['ar_kid_r_0', 'or_kidney_r', 'supplies'], ['ar_kid_l_0', 'or_kidney_l', 'supplies'], ['ve_kid_r_0', 'or_kidney_r', 'drains'], ['ve_kid_l_0', 'or_kidney_l', 'drains'],
    ['ar_mes_0', 'or_small_int', 'supplies'], ['ve_mes_0', 'or_small_int', 'drains'],
    ['ar_cor_l_0', 'or_heart_l', 'supplies'], ['ar_cor_r_0', 'or_heart_r', 'supplies'],
    ['pa_r1_0', 'or_lung_r', 'supplies'], ['pa_r2_0', 'or_lung_r', 'supplies'], ['pa_l1_0', 'or_lung_l', 'supplies'], ['pa_l2_0', 'or_lung_l', 'supplies'],
    ['pvn_r1_0', 'or_lung_r', 'drains'], ['pvn_r2_0', 'or_lung_r', 'drains'], ['pvn_l1_0', 'or_lung_l', 'drains'], ['pvn_l2_0', 'or_lung_l', 'drains']
  ].freeze

  # organs that touch each other get an automatic "adjacent" link
  ADJ_SKIP = %w[or_small_int_sh or_colon_haustra].freeze

  PX_MM = 10.0 / Geo::PX_PER_CM   # 1 px of the drawing = about 2.19 mm of an adult body
  module_function

  def base_of(id) = id.sub(/_[rl]\z/, '')
  def side_of(id) = id[/_([rl])\z/, 1]

  def intervals(d) = d.first.is_a?(Array) ? d : [d]

  def build(morphs, meta)
    ids = morphs.map { |m| m[:id] }
    idset = ids.to_h { |i| [i, true] }
    node = {}

    morphs.each do |m|
      id = m[:id]
      d = m[:shape][:d] || ''
      pts = m[:shape][:d] ? Geo.path_points(d) : []
      pts = [[m[:shape][:cx] - m[:shape][:rx], m[:shape][:cy]], [m[:shape][:cx] + m[:shape][:rx], m[:shape][:cy]]] if pts.empty?
      xs = pts.map { |p| p[0] }
      ys = pts.map { |p| p[1] }
      bbox = [xs.min, ys.min, xs.max, ys.max].map { |v| v.round(1) }
      hull = Geo.hull(pts)
      hull = hull.each_slice((hull.size / 16.0).ceil).map(&:first) if hull.size > 18
      mt = meta[id] || {}
      kind = mt[:kind] || { 'skin' => 'skin', 'skeleton' => 'bone', 'muscles' => 'muscle', 'organs' => 'organ', 'nerves' => 'nerve',
                            'arteries' => 'artery', 'veins' => 'vein', 'pulmonary' => 'pulm_a' }[m[:system]]
      node[id] = {
        kind: kind, system: m[:system], bbox: bbox, origin: [((bbox[0] + bbox[2]) / 2).round(1), ((bbox[1] + bbox[3]) / 2).round(1)],
        boundary: { type: mt[:hierarchy] == 'segment' ? 'cut-plane polygon' : 'convex hull', pts: hull.map { |p| [p[0].round(1), p[1].round(1)] } },
        size_mm: [((bbox[2] - bbox[0]) * PX_MM).round, ((bbox[3] - bbox[1]) * PX_MM).round],
        internal: mt[:internal] ? true : false
      }
      node[id][:boundary] = { type: 'cut-plane polygon', pts: mt[:poly].max_by { |q| Geo.shoelace(q).abs }.map { |p| [p[0].round(1), p[1].round(1)] } } if mt[:hierarchy] == 'segment' && mt[:poly]
      [:level, :diam, :len, :flow, :tree, :cl, :seg, :trunk, :vessel_parent, :lung, :hierarchy, :duct].each { |k| node[id][k] = mt[k] unless mt[k].nil? }
    end

    # ---- parents
    morphs.each do |m|
      id = m[:id]
      mt = meta[id] || {}
      par = mt[:parent]
      par ||= FIXED_PARENT[id]
      if par.nil? && PARENT_BASES.key?(id) && idset[PARENT_BASES[id]]
        par = PARENT_BASES[id]
      end
      if par.nil? && PARENT_BASES.key?(base_of(id))
        pb = PARENT_BASES[base_of(id)]
        s = side_of(id)
        cand = s && idset["#{pb}_#{s}"] ? "#{pb}_#{s}" : (idset[pb] ? pb : nil)
        par = cand
      end
      par = mt[:vessel_parent] if par.nil? && mt[:vessel_parent]
      if par.nil? && id != 'skin_body'
        c = node[id][:origin]
        par = region_of(c[0], c[1])
      end
      par = 'rg_body' if id == 'skin_body'
      node[id][:parent] = par
    end

    # ---- depth (inherit from the parent chain for generated branches)
    depth_of = lambda do |id|
      return nil unless idset[id]
      node[id][:depth] ||= begin
        mt = meta[id] || {}
        d = mt[:depth] || DEPTH[id] || DEPTH[base_of(id)]
        if d.nil? && node[id][:parent] && idset[node[id][:parent]] && mt[:tree]
          d = depth_of.(node[id][:parent])
        end
        d || DEPTH_SYSTEM[node[id][:system]]
      end
    end
    ids.each { |i| depth_of.(i) }
    ids.each do |i|
      iv = intervals(node[i][:depth])
      node[i][:depth] = iv.map { |a| a.map { |v| v.round(2) } }
      node[i][:z] = (iv.sum { |a| (a[0] + a[1]) / 2 } / iv.size).round(3)
    end

    # ---- distance from heart / CNS along the parent chain (pulse + nerve timing)
    memo = {}
    dist_parent = ->(n) { n[:kind] =~ /artery|vein|pulm|portal|hepatic_a|bile/ && n[:vessel_parent] ? n[:vessel_parent] : n[:parent] }
    chain = lambda do |id|
      memo[id] ||= begin
        n = node[id]
        up = dist_parent.(n)
        pl = idset[up] ? chain.(up) : 0.0
        own = n[:len] || (n[:kind] =~ /artery|vein|pulm|portal|hepatic_a|bile|nerve/ ? Geo.path_len(morphs.find { |m| m[:id] == id }[:shape][:d] || '') : 0.0)
        own = 0.0 if %w[ne_brain ne_gyri ne_cerebellum or_heart_r or_heart_l].include?(id)
        n[:len] ||= own.round(1) if own.positive?
        pl + (n[:dist_len] = own.to_f)
      end
    end
    ids.each { |i| chain.(i) }
    ids.each do |i|
      n = node[i]
      up = dist_parent.(n)
      pd = idset[up] ? memo[up] : 0.0
      n[:dist] = pd.round(1)
      n.delete(:dist_len)
    end

    morphs.each do |m|
      n = node[m[:id]]
      n[:diam] ||= [m[:stroke_width], m[:stroke_width]] if n[:kind] =~ /artery|vein|pulm|portal|hepatic_a|bile/ && m[:stroke_width].to_f.positive? && m[:fill].nil?
    end
    # nerve / vessel centre lines for animation overlays (brain stem and cord are filled tubes)
    node['ne_brainstem'][:cl] = Geo.line([[200, 94], [200, 130]])
    node['ne_cord'][:cl] = Geo.line([[200, 130], [200, 296]])
    node['ne_brainstem'][:len] = 36.0
    node['ne_cord'][:len] = 166.0
    ids.each do |i|
      n = node[i]
      next unless n[:kind] =~ /artery|vein|pulm|portal|hepatic_a|bile|nerve/
      n[:cl] ||= morphs.find { |m| m[:id] == i }[:shape][:d] if n[:kind] == 'nerve' || n[:len].to_f > 10
    end
    # drop centre lines on thin generated twigs (kept small on purpose)
    # flow direction along the drawn path: +1 = from path start to path end
    heart = [212, 236]
    cns = [200, 112]
    ids.each do |i|
      n = node[i]
      next if n[:flow]
      d = morphs.find { |m| m[:id] == i }[:shape][:d]
      next unless d && n[:kind]
      segs = Geo.path_segments(d).first
      next unless segs
      first = segs.first[:p]
      last = segs.reverse.find { |s| s[:p] }[:p]
      ref = n[:kind] == 'nerve' ? cns : heart
      df = Math.hypot(first[0] - ref[0], first[1] - ref[1])
      dl = Math.hypot(last[0] - ref[0], last[1] - ref[1])
      away = df <= dl ? 1 : -1
      n[:flow] = %w[vein pulm_v].include?(n[:kind]) ? -away : away if n[:kind] =~ /artery|vein|pulm|portal|hepatic_a|bile|nerve/
    end

    # ---- connections
    conns = Hash.new { |h, k| h[k] = [] }
    CONNECTIONS.each { |a, b, k| conns[a] << { to: b, kind: k, dir: 'out' }; conns[b] << { to: a, kind: k, dir: 'in' } }
    ids.each do |i|
      vp = node[i][:vessel_parent]
      next unless vp && vp != node[i][:parent]
      conns[i] << { to: vp, kind: 'continues', dir: 'out' }
      conns[vp] << { to: i, kind: 'continues', dir: 'in' }
    end
    # auto adjacency among organs (hull overlap)
    organs = ids.select { |i| node[i][:kind] == 'organ' && !node[i][:internal] && !ADJ_SKIP.include?(i) } + %w[mu_diaphragm]
    organs -= %w[or_small_int]
    hulls = organs.to_h { |i| [i, Geo.path_polygon(morphs.find { |m| m[:id] == i }[:shape][:d], 6)] }
    organs.combination(2).each do |a, b|
      next if %w[or_ureter_r or_ureter_l or_colon].include?(a) || %w[or_ureter_r or_ureter_l or_colon].include?(b)
      next if node[a][:parent] == b || node[b][:parent] == a
      next if conns[a].any? { |c| c[:to] == b }
      ov = Geo.clip_convex(hulls[a], Geo.hull(hulls[b]))
      next unless node[a][:depth].any? { |x| node[b][:depth].any? { |y| x[0] <= y[1] + 0.03 && y[0] <= x[1] + 0.03 } }
      next if ov.size < 3 || Geo.shoelace(ov).abs < 6
      conns[a] << { to: b, kind: 'adjacent', dir: 'both' }
      conns[b] << { to: a, kind: 'adjacent', dir: 'both' }
    end
    # a few bone-to-bone articulation links by parent relation are implicit in the hierarchy
    conns.each { |k, v| node[k][:connections] = v.uniq } if conns.any?
    ids.each { |i| node[i][:connections] ||= [] }

    # ---- coordinate frame relative to parent
    ids.each do |i|
      n = node[i]
      po = idset[n[:parent]] ? node[n[:parent]][:origin] : [200, 420]
      pz = idset[n[:parent]] ? node[n[:parent]][:z] : 0.5
      n[:frame] = { origin: [n[:origin][0], n[:origin][1], n[:z]], offset: [(n[:origin][0] - po[0]).round(1), (n[:origin][1] - po[1]).round(1), (n[:z] - pz).round(2)] }
    end
    node
  end
end

# ==========================================================================
# PHYSIOLOGY -- ONE table of textbook parameter ranges, how they drive the
# animation (coupling) and precomputed waveform tables.
# SCHEMATIC ONLY: this is a teaching animation, not a validated physiological model.
# ==========================================================================
module Physiology
  SOURCE_NOTE = 'Typical resting-adult values as quoted in introductory physiology textbooks (for example Guyton & Hall, ' \
                'Textbook of Medical Physiology). They are rounded teaching ranges, not patient data and not a validated model.'.freeze
  DISCLAIMER = 'Schematic animation for learning. It is not a validated physiological model and must not be used for diagnosis or treatment decisions.'.freeze

  # value = default used by the animation, range = [low, high] allowed by the sliders / validation
  PARAMS = {
    heart_rate:        { value: 72,   range: [60, 100],   unit: 'beats/min',  label: 'Resting heart rate',      note: 'adult at rest, normal sinus rhythm' },
    systole_fraction:  { value: 0.37, range: [0.30, 0.45], unit: 'of cycle',  label: 'Systole share of the beat', note: 'ventricles contract for roughly a third of the beat at rest' },
    respiratory_rate:  { value: 15,   range: [12, 20],    unit: 'breaths/min', label: 'Resting breathing rate', note: 'quiet breathing, adult' },
    inspiration_share: { value: 0.40, range: [0.33, 0.50], unit: 'of cycle',  label: 'Inspiration share of a breath', note: 'breathing in is shorter than breathing out (about 1 : 1.5)' },
    pulse_wave_speed:  { value: 7.0,  range: [5.0, 10.0], unit: 'm/s',        label: 'Arterial pulse-wave speed', note: 'speed of the pressure wave in healthy arteries (not blood speed)' },
    nerve_speed:       { value: 60.0, range: [40.0, 70.0], unit: 'm/s',       label: 'Fast myelinated nerve conduction', note: 'limb motor nerves; drawn about 100 times slower so it can be seen' },
    portal_flow:       { value: 1100, range: [900, 1300], unit: 'mL/min',     label: 'Portal vein flow',        note: 'about three quarters of the liver blood supply' },
    stroke_volume:     { value: 70,   range: [60, 100],   unit: 'mL',         label: 'Stroke volume',            note: 'blood ejected per beat (shown for reference)' },
    tidal_volume:      { value: 500,  range: [400, 600],  unit: 'mL',         label: 'Tidal volume',             note: 'air moved per quiet breath (shown for reference)' },
    diaphragm_travel:  { value: 1.5,  range: [1.0, 2.0],  unit: 'cm',         label: 'Diaphragm travel (quiet breathing)', note: 'dome moves down about 1-2 cm' },
    nerve_display_speed: { value: 330, range: [150, 500], unit: 'px/s',       label: 'Nerve signal drawing speed', note: 'display speed only (schematic pixels per second)' }
  }.freeze

  PX_PER_M = Geo::PX_PER_CM * 100

  # which morphs move, and how (resolved to explicit id lists by `coupling`)
  # heart: shrink about a pivot during systole; breath: lungs expand, diaphragm and abdominal organs shift down
  def self.coupling(scene)
    kids = Hash.new { |h, k| h[k] = [] }
    scene.each { |id, n| kids[n[:parent]] << id }
    desc = lambda do |id, acc = []|
      acc << id
      kids[id].each { |c| desc.(c, acc) }
      acc
    end
    ex = ->(ids) { ids.select { |i| scene.key?(i) }.flat_map { |i| desc.(i) }.uniq }
    heart_ids = (%w[or_heart_r or_heart_l] + ex.(['ar_coronary'])).uniq
    trees = ->(*prefixes) { scene.keys.select { |i| prefixes.any? { |p| i.start_with?(p) } } }
    lung_r = (['or_lung_r'] + trees.('pa_r', 'pvn_r')).uniq
    lung_l = (['or_lung_l'] + trees.('pa_l', 'pvn_l')).uniq
    shifts = {
      'mu_diaphragm' => 1.0, 'or_liver' => 0.8, 'or_gallbladder' => 0.8, 'or_stomach' => 0.72, 'or_spleen' => 0.66, 'or_pancreas' => 0.5,
      'or_kidney_r' => 0.3, 'or_kidney_l' => 0.3, 'or_small_int' => 0.4, 'or_colon' => 0.35, 'or_bile_duct' => 0.55, 'or_cystic_duct' => 0.7,
      've_portal' => 0.4, 've_smv' => 0.3, 've_splenic' => 0.4, 'ar_hepatic' => 0.5
    }
    breath_shift = []
    shifts.each do |root, f|
      ex.([root]).each { |i| breath_shift << { id: i, f: f } }
    end
    # branches that hang off a shifting organ move with it (but lung trees already scale)
    {
      heart: { ids: heart_ids, pivot: [217, 236], sx: -0.07, sy: -0.08 },
      breath_lung: [{ ids: lung_r, pivot: [194, 180], sx: 0.06, sy: 0.07 }, { ids: lung_l, pivot: [206, 180], sx: 0.06, sy: 0.07 }],
      breath_shift: breath_shift.uniq { |h| h[:id] },
      breath_ribs: { ids: %w[sk_ribs_r sk_ribs_l], pivot: [200, 235], sx: 0.014, sy: 0.01 }
    }
  end

  def self.smooth(x) = x <= 0 ? 0.0 : (x >= 1 ? 1.0 : x * x * (3 - 2 * x))
  def self.gauss(x, mu, sd) = Math.exp(-((x - mu)**2) / (2 * sd * sd))

  # phase t in [0,1) -> normalised arterial pressure pulse (fast upstroke, dicrotic notch, slow run-off)
  def self.pulse(t, sf)
    up = 0.12 * sf / 0.37
    v = if t < up then 0.45 + 0.55 * smooth(t / up)
        else 0.45 + 0.55 * Math.exp(-(t - up) / 0.28) * (1.0 - 0.18 * smooth((t - up) / 0.4)) end
    v -= 0.07 * gauss(t, sf, 0.014)
    v += 0.045 * gauss(t, sf + 0.045, 0.03)
    v
  end

  # ventricular squeeze 0..1: smooth bump over systole, 0 in diastole
  def self.squeeze(t, sf) = t < sf ? Math.sin(Math::PI * t / sf)**1.6 : 0.0

  def self.lung_volume(t, fi) = t < fi ? 0.5 - 0.5 * Math.cos(Math::PI * t / fi) : 0.5 + 0.5 * Math.cos(Math::PI * (t - fi) / (1 - fi))

  # idealised action potential (mV) over 0..1 of its own duration
  def self.action_potential(t)
    return -70 + 3 * t if t < 0.2 # slow drift to threshold
    if t < 0.3 then -67 + (30 + 67) * ((t - 0.2) / 0.1)**1.4
    elsif t < 0.5 then 30 - (30 + 85) * ((t - 0.3) / 0.2)**0.8
    elsif t < 0.8 then -85 + 15 * smooth((t - 0.5) / 0.3)
    else -70 - 0 * t end
  end

  def self.waves
    n = 100
    sf = PARAMS[:systole_fraction][:value]
    fi = PARAMS[:inspiration_share][:value]
    pu = (0...n).map { |i| pulse(i / n.to_f, sf) }
    mn = pu.min
    mx = pu.max
    {
      samples: n,
      arterial_pulse: pu.map { |v| ((v - mn) / (mx - mn)).round(3) },
      ventricle_squeeze: (0...n).map { |i| squeeze(i / n.to_f, sf).round(3) },
      lung_volume: (0...n).map { |i| lung_volume(i / n.to_f, fi).round(3) },
      action_potential: (0...n).map { |i| action_potential(i / n.to_f).round(1) }
    }
  end

  def self.table = PARAMS.transform_values { |v| v.merge(range: v[:range]) }
end

# ==========================================================================
# VALIDATION -- structural and plausibility checks on the anatomy data.
# No datasets are downloaded.  (Future work: compare against Visible Human /
# BodyParts3D meshes, subject to their licences.)
# ==========================================================================
module Validation
  VESSEL = %w[artery vein pulm_a pulm_v portal hepatic_a bile].freeze
  ARTERIAL = %w[artery pulm_a hepatic_a portal].freeze
  # organ -> [[min,max] width cm, [min,max] height cm]  (frontal-view drawing, generous bounds)
  SIZE_CM = {
    'or_liver' => [[12, 28], [7, 20]], 'or_lung_r' => [[8, 16], [14, 32]], 'or_lung_l' => [[8, 16], [14, 32]],
    'or_heart_l' => [[4, 12], [8, 16]], 'or_kidney_r' => [[3, 8], [8, 14]], 'or_kidney_l' => [[3, 8], [8, 14]],
    'or_spleen' => [[2, 8], [7, 14]], 'or_stomach' => [[6, 16], [10, 30]], 'or_gallbladder' => [[1, 5], [3, 12]],
    'or_bladder' => [[4, 12], [4, 15]], 'or_thyroid' => [[3, 9], [2, 7]], 'or_pancreas' => [[12, 25], [3, 9]],
    'or_esophagus' => [[1, 6], [18, 30]], 'or_trachea' => [[6, 18], [8, 16]], 'ne_brain' => [[9, 18], [11, 18]],
    'sk_femur_r' => [[3, 12], [36, 52]], 'sk_humerus_r' => [[3, 12], [26, 40]], 'sk_tibia_r' => [[3, 12], [33, 46]]
  }.freeze
  DEPTH_ORDER = [ # [in front, behind]
    %w[or_liver or_kidney_r], %w[or_stomach or_pancreas], %w[or_stomach or_kidney_l], %w[or_heart_l or_esophagus], %w[or_lung_r or_trachea],
    %w[sk_sternum or_heart_l], %w[or_heart_r sk_thoracic], %w[or_stomach or_spleen], %w[or_liver ve_ivc], %w[or_small_int or_kidney_l]
  ].freeze
  SIDE_PAIRS = [%w[or_kidney_r or_kidney_l], %w[or_lung_r or_lung_l]].freeze

  Check = Struct.new(:name, :status, :detail)

  module_function

  def run(morphs, scene, physiology)
    ids = morphs.to_h { |m| [m[:id], m] }
    regions = Scene::REGIONS.to_h { |r| [r[:id], r] }
    known = ->(i) { ids.key?(i) || regions.key?(i) }
    out = []
    add = ->(name, errs, warns = [], ok_detail = '') {
      st = errs.any? ? 'FAIL' : (warns.any? ? 'WARN' : 'PASS')
      out << Check.new(name, st, (errs + warns).first(6).join('; ') + (errs.size + warns.size > 6 ? " (+#{errs.size + warns.size - 6} more)" : '') + (errs.empty? && warns.empty? ? ok_detail : ''))
    }

    # 1. every morph has the full scene record
    miss = ids.keys.reject { |i| scene[i] && scene[i][:parent] && scene[i][:frame] && scene[i][:boundary] && scene[i][:boundary][:pts].size >= 2 && scene[i][:bbox] }
    add.('every morph has frame, parent, boundary and connections', miss.map { |i| "#{i} incomplete" }, [], "#{ids.size} morphs checked")

    # 2. connections reference existing morphs, both directions agree
    bad = []
    scene.each { |i, n| n[:connections].each { |c| bad << "#{i} -> #{c[:to]} (#{c[:kind]})" unless known.(c[:to]) } }
    Scene::CONNECTIONS.each { |a, b, k| bad << "#{a} -#{k}-> #{b}" unless ids.key?(a) && ids.key?(b) }
    n_conn = scene.values.sum { |n| n[:connections].size } / 2
    add.('every connection references existing morphs', bad.uniq, [], "#{n_conn} connections")

    # 3. parents exist and are acyclic, every chain reaches the body root
    errs = []
    scene.each do |i, n|
      seen = { i => true }
      cur = n[:parent]
      until cur.nil?
        unless known.(cur)
          errs << "#{i}: parent #{cur} does not exist"
          break
        end
        if seen[cur]
          errs << "#{i}: parent cycle at #{cur}"
          break
        end
        seen[cur] = true
        cur = ids.key?(cur) ? scene[cur][:parent] : regions[cur][:parent]
      end
    end
    depth_max = scene.keys.map { |i| a = 0; c = i; while ids.key?(c); c = scene[c][:parent]; a += 1; end; a }.max
    add.('parent relationships are acyclic and reach the body root', errs, [], "deepest chain: #{depth_max} levels")

    # 4. vessel semantics + laterality
    errs = []
    scene.each do |i, n|
      n[:connections].each do |c|
        next unless c[:dir] == 'out'
        a = scene[i]
        b = scene[c[:to]]
        next unless b
        case c[:kind]
        when 'supplies' then errs << "#{i} supplies #{c[:to]} but is not an artery/portal vessel" unless ARTERIAL.include?(a[:kind])
        when 'innervates' then errs << "#{i} innervates but is not a nerve" unless a[:kind] == 'nerve'
        when 'drains'
          ok = %w[organ vein pulm_v pulm_a portal bile].include?(a[:kind]) || (a[:kind] == 'pulm_a')
          errs << "#{i} drains but is a #{a[:kind]}" unless ok
          errs << "#{i} (artery) cannot drain into #{c[:to]}" if %w[artery hepatic_a].include?(a[:kind])
        end
        sa = Scene.side_of(i)
        sb = Scene.side_of(c[:to])
        errs << "side mismatch #{i} -> #{c[:to]}" if sa && sb && sa != sb && c[:kind] != 'adjacent' && !c[:to].start_with?('or_heart') && !i.start_with?('or_heart')
      end
    end
    add.('connection kinds fit the structures (arteries supply, nerves innervate, sides match)', errs)

    # 5. circuit membership: pulmonary arteries leave the right heart, pulmonary veins enter the left heart, systemic arteries leave the left heart
    errs = []
    root_of = lambda do |i|
      c = i
      guard = 0
      while ids.key?(c) && guard < 60
        nxt = scene[c][:vessel_parent] && scene[c][:trunk] ? scene[c][:vessel_parent] : scene[c][:parent]
        break if nxt.nil? || !ids.key?(nxt) && !regions.key?(nxt)
        c = nxt
        guard += 1
      end
      c
    end
    # trace by following parent/vessel_parent until a heart chamber is met
    reach = lambda do |i|
      c = i
      60.times do
        return c if %w[or_heart_l or_heart_r].include?(c)
        n = scene[c]
        return nil unless n
        nxt = n[:parent]
        nxt = n[:vessel_parent] if n[:trunk] && n[:vessel_parent]
        nxt = n[:vessel_parent] if (nxt.nil? || regions.key?(nxt)) && n[:vessel_parent]
        return nil if nxt.nil? || regions.key?(nxt)
        c = nxt
      end
      nil
    end
    scene.each do |i, n|
      next if n[:internal] && !%w[vein artery].include?(n[:kind]) && !n[:tree]
      case n[:kind]
      when 'pulm_a' then (r = reach.(i)) == 'or_heart_r' || errs << "#{i}: pulmonary artery does not trace to the right heart (#{r.inspect})"
      when 'pulm_v' then (r = reach.(i)) == 'or_heart_l' || errs << "#{i}: pulmonary vein does not trace to the left heart (#{r.inspect})"
      when 'artery'
        next if i.start_with?('lv_')
        (r = reach.(i)) == 'or_heart_l' || errs << "#{i}: systemic artery does not trace to the left heart (#{r.inspect})"
      when 'vein'
        next if i.start_with?('lv_')
        (r = reach.(i)) == 'or_heart_r' || errs << "#{i}: systemic vein does not trace to the right heart (#{r.inspect})"
      end
    end
    add.('circulation: pulmonary arteries from right heart, pulmonary veins to left heart, systemic from left / to right', errs, [], 'all vessel chains traced')

    # 6. vessels meet the right organs (geometry)
    errs = []
    warns = []
    dists = []
    scene.each do |i, n|
      n[:connections].each do |c|
        next unless c[:dir] == 'out' && %w[supplies drains].include?(c[:kind])
        a, b = n[:kind] =~ /organ/ ? [c[:to], i] : [i, c[:to]]
        next unless scene[a] && scene[b] && VESSEL.include?(scene[a][:kind]) && scene[b][:kind] == 'organ'
        poly = Geo.path_polygon(ids[b][:shape][:d] || '', 6)
        poly = Geo.hull(Geo.path_points(ids[b][:shape][:d])) if poly.size < 3 || ids[b][:fill].nil?
        pts = Geo.path_points(ids[a][:shape][:d])
        dmin = pts.map { |p| Geo.inside?(poly, p) ? 0.0 : poly.each_with_index.map { |q, k| seg_dist(p, q, poly[(k + 1) % poly.size]) }.min }.min
        dists << dmin
        (dmin > 22 ? errs : (dmin > 12 ? warns : [])) << format('%s - %s: %.1f px apart', a, b, dmin)
      end
    end
    add.('vessels touch the organs they supply or drain', errs, warns, "#{dists.size} vessel-organ links, farthest #{dists.max.to_f.round(1)} px")

    # 7. calibre never grows going away from the parent vessel
    warns = []
    scene.each do |i, n|
      p = scene[n[:parent]]
      next unless p && n[:diam] && p[:diam] && VESSEL.include?(n[:kind]) && VESSEL.include?(p[:kind])
      warns << format('%s (%.1f) wider than parent %s (%.1f)', i, n[:diam][0], n[:parent], p[:diam][1]) if n[:diam][0] > p[:diam][1] * 1.08 + 0.05
    end
    gen = scene.count { |_, n| n[:tree] }
    add.('vessel calibre tapers from parent to child (branching trees follow Murray\'s law)', [], warns, "#{gen} generated branches checked")

    # 7b. flow arrows point the right way (arteries away from the heart, veins towards it)
    warns = []
    heart = [212, 236]
    ndir = 0
    scene.each do |i, n|
      next unless n[:cl] && n[:flow] && %w[artery pulm_a vein pulm_v].include?(n[:kind]) && !i.start_with?('lv_') && !n[:tree] && !i.start_with?('ar_palmar', 'ar_coronary') # loops/arches and generated trees grow away from their root by construction
      pts = Geo.path_points(n[:cl])
      next if pts.size < 2
      head, tail = n[:flow] == 1 ? [pts.last, pts.first] : [pts.first, pts.last]
      dh = Math.hypot(head[0] - heart[0], head[1] - heart[1])
      dt = Math.hypot(tail[0] - heart[0], tail[1] - heart[1])
      ndir += 1
      away = %w[artery pulm_a].include?(n[:kind])
      warns << format('%s flows %s the heart (%.0f -> %.0f px)', i, away ? 'toward' : 'away from', dt, dh) if (away && dh < dt - 8) || (!away && dh > dt + 8)
    end
    add.('flow directions: arteries run away from the heart, veins towards it', [], warns, "#{ndir} vessels checked")

    # 8. plausible organ sizes
    errs = []
    scene.each do |i, n|
      rng = SIZE_CM[i]
      next unless rng
      w = (n[:bbox][2] - n[:bbox][0]) / Geo::PX_PER_CM
      h = (n[:bbox][3] - n[:bbox][1]) / Geo::PX_PER_CM
      errs << format('%s is %.1f x %.1f cm (expected %s x %s)', i, w, h, rng[0].inspect, rng[1].inspect) unless w.between?(*rng[0]) && h.between?(*rng[1])
    end
    SIDE_PAIRS.each do |a, b|
      ha = scene[a][:bbox][3] - scene[a][:bbox][1]
      hb = scene[b][:bbox][3] - scene[b][:bbox][1]
      errs << "#{a} and #{b} differ more than 30% in height" if (ha - hb).abs / [ha, hb].max > 0.3
    end
    sb = scene['skin_body'][:bbox]
    body_cm = (sb[3] - sb[1]) / Geo::PX_PER_CM
    errs << format('body height %.0f cm outside 150-200', body_cm) unless body_cm.between?(150, 200)
    add.('organ and body sizes are within plausible adult bounds', errs, [], format('%d size rules, body %.0f cm tall', SIZE_CM.size + SIDE_PAIRS.size + 1, body_cm))

    # 9. front-to-back order of overlapping structures
    errs = []
    DEPTH_ORDER.each do |front, back|
      errs << "#{front} should be in front of #{back}" unless scene[front][:z] < scene[back][:z]
    end
    add.('depth order of overlapping organs (e.g. liver in front of right kidney)', errs, [], "#{DEPTH_ORDER.size} pairs")

    # 10. liver segments tile the liver and sit inside its outline
    errs = []
    liver = Geo.path_polygon(ids['or_liver'][:shape][:d], 10)
    la = Geo.shoelace(liver).abs
    segs = scene.select { |i, n| n[:hierarchy] == 'segment' }
    area = 0.0
    outside = 0
    segs.each_key do |i|
      pm = Atlas::META[i][:poly]
      pm.each do |poly|
        area += Geo.shoelace(poly).abs
        outside += poly.count { |p| !Geo.inside?(liver, p) && liver.each_with_index.map { |q, k| seg_dist(p, q, liver[(k + 1) % liver.size]) }.min > 0.4 }
      end
    end
    errs << "segments cover #{(area / la * 100).round}% of the liver (expected 90-101%)" unless (area / la).between?(0.9, 1.01)
    errs << "#{outside} segment vertices outside the liver outline" if outside.positive?
    errs << "expected 9 segments (I-VIII, IV split in two), found #{segs.size}" unless segs.size == 9
    add.('liver: 9 segment pieces tile the outline, lobes own their segments', errs, [], format('segments cover %d%% of the outline', (area / la * 100).round))

    # 11. physiology table sane
    errs = physiology.each_with_object([]) { |(k, v), a| a << "#{k} default #{v[:value]} outside #{v[:range].inspect}" unless v[:value].between?(*v[:range]) }
    errs << 'heart rate range should be about 60-100' unless physiology[:heart_rate][:range] == [60, 100]
    errs << 'breathing range should be about 12-20' unless physiology[:respiratory_rate][:range] == [12, 20]
    add.('physiology table: defaults inside textbook ranges', errs, [], "#{physiology.size} parameters")

    # 12. unique ids, drawable data
    dup = morphs.group_by { |m| m[:id] }.select { |_, v| v.size > 1 }.keys
    add.('morph ids are unique and every layer exists', dup.map { |d| "duplicate #{d}" } + morphs.reject { |m| Atlas::LAYERS.any? { |l| l[:id] == m[:system] } }.map { |m| "#{m[:id]}: unknown layer #{m[:system]}" })
    out
  end

  def seg_dist(p, a, b)
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    l2 = dx * dx + dy * dy
    t = l2.zero? ? 0 : [[((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2, 0].max, 1].min
    Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy))
  end

  def report(checks)
    w = checks.map { |c| c.name.size }.max
    lines = ['', '== Anatomical validation (schematic data, no datasets) =='.dup]
    checks.each { |c| lines << format('  [%-4s] %s%s', c.status, c.name, c.detail.empty? ? '' : "  -- #{c.detail}") }
    f = checks.count { |c| c.status == 'FAIL' }
    wn = checks.count { |c| c.status == 'WARN' }
    lines << format('  %d checks: %d passed, %d warnings, %d failed', checks.size, checks.size - f - wn, wn, f)
    lines << '  Future work: compare against Visible Human / BodyParts3D geometry, subject to their licences.'
    lines.join("\n")
  end
end

# ==========================================================================
# GENERATOR -- serialise the anatomy and weave it into the HTML template
# ==========================================================================
module Generator
  module_function

  def sections
    @sections ||= DATA.read.split(/^@@(\w+)\n/).drop(1).each_slice(2).to_h { |k, v| [k, v] }
  end

  LEGEND = [
    { kind: 'artery', label: 'Systemic arteries (oxygen-rich, from left heart)', color: Atlas::KIND_COLOR['artery'] },
    { kind: 'vein', label: 'Systemic veins (back to right heart)', color: Atlas::KIND_COLOR['vein'] },
    { kind: 'pulm_a', label: 'Pulmonary arteries (right heart to lungs)', color: Atlas::KIND_COLOR['pulm_a'] },
    { kind: 'pulm_v', label: 'Pulmonary veins (lungs to left heart)', color: Atlas::KIND_COLOR['pulm_v'] },
    { kind: 'portal', label: 'Portal system (gut to liver)', color: Atlas::KIND_COLOR['portal'] },
    { kind: 'hepatic_a', label: 'Hepatic artery', color: Atlas::KIND_COLOR['hepatic_a'] },
    { kind: 'bile', label: 'Bile ducts', color: Atlas::KIND_COLOR['bile'] },
    { kind: 'nerve', label: 'Nerves', color: Atlas::KIND_COLOR['nerve'] }
  ].freeze

  def build_world
    morphs = Atlas.build!
    scene = Scene.build(morphs, Atlas::META)
    checks = Validation.run(morphs, scene, Physiology::PARAMS)
    @checks = checks
    scene_json = scene.transform_values do |n|
      n.reject { |k, _| %i[connections].include?(k) && n[:connections].empty? }
    end
    phys = {
      params: Physiology::PARAMS, source: Physiology::SOURCE_NOTE, disclaimer: Physiology::DISCLAIMER,
      coupling: Physiology.coupling(scene), waves: Physiology.waves, px_per_m: Physiology::PX_PER_M
    }
    val = { checks: checks.map { |c| { name: c.name, status: c.status, detail: c.detail } },
            pass: checks.count { |c| c.status == 'PASS' }, warn: checks.count { |c| c.status == 'WARN' }, fail: checks.count { |c| c.status == 'FAIL' },
            future: 'Future work: compare with Visible Human / BodyParts3D geometry, subject to their licences.' }
    { layers: Atlas::LAYERS, morphs: morphs, scene: scene_json, regions: Scene::REGIONS, physiology: phys, legend: LEGEND, validation: val,
      branch_seed: Atlas::BRANCH_SEED, px_mm: Scene::PX_MM }
  end

  def world_json
    # '<' escaped so no "</script>" or "<!--" can ever appear inside the inline script
    JSON.generate(build_world).gsub('<', '\u003c').gsub("\u2028", '\u2028').gsub("\u2029", '\u2029')
  end

  def failed? = (@checks || []).any? { |c| c.status == 'FAIL' }

  def render
    js = sections.fetch('js').sub('/*__WORLD__*/') { world_json }
    sections.fetch('html')
            .sub('/*__CSS__*/') { sections.fetch('css') }
            .sub('/*__JS__*/') { js }
  end

  def run(out)
    html = render
    File.write(out, html)
    by = Atlas::MORPHS.group_by { |m| m[:system] }.transform_values(&:size)
    puts "wrote #{out} (#{(html.bytesize / 1024.0).round(1)} KiB)"
    puts Validation.report(@checks)
    puts "  #{Atlas::MORPHS.size} morphs in #{Atlas::LAYERS.size} layers: " + Atlas::LAYERS.map { |l| "#{l[:id]}=#{by[l[:id]] || 0}" }.join(', ')
  end
end

if $PROGRAM_NAME == __FILE__
  out = ARGV[0] || File.join(File.dirname(File.expand_path(__FILE__)), 'atlas.html')
  Generator.run(out)
  exit(1) if Generator.failed?
end

__END__
@@css
:root{
  --bg:#eef1f5; --panel:#ffffff; --ink:#243042; --muted:#6b778a; --line:#dde3ec;
  --accent:#e0457b; --accent2:#3b82f6; --mode-bg:#1b212c; --mono:ui-monospace,"SFMono-Regular",Menlo,Consolas,"DejaVu Sans Mono",monospace;
}
*{box-sizing:border-box}
html,body{margin:0;height:100%;font:13px/1.35 system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;color:var(--ink);background:var(--bg);overflow:hidden}
#app{display:grid;grid-template-columns:300px 1fr;grid-template-rows:1fr 26px;height:100vh}
#side{grid-row:1;grid-column:1;background:var(--panel);border-right:1px solid var(--line);display:flex;flex-direction:column;min-height:0;box-shadow:2px 0 14px rgba(36,48,66,.06);z-index:3}
#side header{padding:14px 16px 8px}
#side h1{margin:0;font-size:18px;letter-spacing:.2px}
#side h1 small{font-weight:500;color:var(--muted);font-size:11px;margin-left:6px}
#side .sub{color:var(--muted);font-size:11.5px;margin-top:3px}
.sec{padding:8px 16px;border-top:1px solid var(--line)}
.sec h2{margin:0 0 6px;font-size:10.5px;letter-spacing:.9px;text-transform:uppercase;color:var(--muted);font-weight:700}
#layers{padding:0}
.lrow{display:flex;align-items:center;gap:7px;padding:4px 16px;cursor:default}
.lrow:hover{background:#f4f6fa}
.lrow.sel{background:#fdeaf1}
.lrow.dim{opacity:.45}
.lrow .dot{width:11px;height:11px;border-radius:50%;flex:none;box-shadow:inset 0 0 0 1px rgba(0,0,0,.18)}
.lrow .name{flex:1;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.lrow .cnt{color:var(--muted);font-size:11px;font-family:var(--mono)}
.lrow button,.btn{font:inherit;border:1px solid var(--line);background:#fff;border-radius:6px;padding:3px 8px;cursor:pointer;color:var(--ink)}
.lrow button{padding:1px 6px;font-size:12px;line-height:1.3}
.lrow button:hover,.btn:hover{border-color:var(--accent);color:var(--accent)}
.lrow button.on{background:var(--accent);border-color:var(--accent);color:#fff}
.lrow input[type=checkbox]{margin:0;accent-color:var(--accent)}
#explodeRow{display:flex;align-items:center;gap:8px}
#explodeRow input{flex:1;accent-color:var(--accent)}
#explodeVal{font-family:var(--mono);width:30px;text-align:right}
.btns{display:flex;flex-wrap:wrap;gap:5px}
#treeWrap{flex:1;min-height:90px;overflow:auto;padding:0 0 6px}
#filter{width:100%;font:inherit;padding:4px 8px;border:1px solid var(--line);border-radius:6px;margin-bottom:4px}
.tl{font-weight:600;padding:3px 16px;font-size:11.5px;color:var(--muted);cursor:pointer;display:flex;gap:6px}
.tl:hover{color:var(--ink)}
.ti{padding:1px 16px 1px 30px;font-size:12px;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ti:hover{background:#f1f4f9}
.ti.sel{background:var(--accent);color:#fff}
.ti.off{text-decoration:line-through;opacity:.55}
#attrib{padding:8px 16px 10px;border-top:1px solid var(--line);font-size:10.5px;color:var(--muted);line-height:1.4}
#attrib b{color:#8a3a55}
#stagewrap{grid-row:1;grid-column:2;position:relative;overflow:hidden;
  background:radial-gradient(1200px 800px at 50% 35%,#ffffff 0%,#eef2f7 60%,#e3e9f1 100%)}
#stagewrap::before{content:"";position:absolute;inset:0;background-image:radial-gradient(rgba(36,48,66,.09) 1px,transparent 1.2px);background-size:22px 22px;pointer-events:none}
#stage,#halosvg{position:absolute;inset:0;width:100%;height:100%}
#stage{touch-action:none;cursor:default;user-select:none}
#stage.panning{cursor:grabbing}
#halosvg{pointer-events:none}
#halosvg .hh{pointer-events:all;cursor:pointer}
#halosvg .hh.drag{cursor:grab}
#halosvg .hh:hover circle{stroke:#fff;stroke-width:2.5}
#halosvg .hh.disabled{opacity:.3;pointer-events:none}
.morph .shape{stroke-linecap:round;stroke-linejoin:round}
.morph.dashed .shape{stroke-linecap:butt}
.morph{cursor:grab}
.morph:hover .shape{filter:drop-shadow(0 0 2.2px rgba(224,69,123,.9))}
.morph.off,.layer.off{visibility:hidden}
.layer-tag{font:700 11px system-ui,sans-serif;letter-spacing:1.4px;text-transform:uppercase;cursor:grab;pointer-events:all}
.layer-plate{pointer-events:none}
#banner{position:absolute;top:10px;right:14px;font-size:11.5px;color:#7a5566;background:rgba(255,255,255,.8);border:1px solid #f0d3df;border-radius:8px;padding:5px 10px;pointer-events:none}
#hint{position:absolute;left:14px;bottom:10px;font-size:11px;color:var(--muted);background:rgba(255,255,255,.75);padding:4px 9px;border-radius:8px;pointer-events:none;max-width:70%}
#tip{position:absolute;pointer-events:none;background:#1b212c;color:#fff;padding:3px 8px;border-radius:6px;font-size:11.5px;display:none;white-space:nowrap;z-index:6;box-shadow:0 4px 12px rgba(0,0,0,.25)}
/* modeline */
#modeline{grid-row:2;grid-column:1 / span 2;background:var(--mode-bg);color:#d7deea;font:12px/26px var(--mono);display:flex;align-items:center;gap:0;white-space:nowrap;overflow:hidden;z-index:5}
#mode{padding:0 12px;font-weight:700;color:#10151c;background:#7bd88f;min-width:104px;text-align:center}
#mode.insert{background:#6cb2ff}#mode.command{background:#f2b950}
#selinfo{padding:0 12px;color:#ffd0e0;border-right:1px solid #2d3646;max-width:42%;overflow:hidden;text-overflow:ellipsis}
#cmdwrap{display:none;flex:1;align-items:center}
#cmdwrap.on{display:flex}
#cmdpre{padding:0 4px 0 12px;color:#f2b950}
#cmd{flex:1;background:transparent;border:0;outline:0;color:#fff;font:inherit;height:26px}
#msg{flex:1;padding:0 12px;overflow:hidden;text-overflow:ellipsis}
#msg.err{color:#ff8f8f}
#pend{padding:0 10px;color:#f2b950}
#info{padding:0 12px;color:#8fa0b8;border-left:1px solid #2d3646}
/* inspector */
#inspector{position:absolute;top:50px;right:16px;width:318px;max-height:calc(100% - 70px);background:rgba(255,255,255,.97);border:1px solid #d6dde8;border-radius:12px;box-shadow:0 14px 40px rgba(24,36,56,.25);z-index:8;display:none;flex-direction:column;overflow:hidden}
#inspector.on{display:flex}
#insHead{background:linear-gradient(#f7e3ec,#f2d2df);padding:7px 10px;display:flex;align-items:center;gap:8px;cursor:move;user-select:none;border-bottom:1px solid #e8c4d3}
#insHead .orb{width:12px;height:12px;border-radius:50%;background:#e05050;border:1px solid #a53030;cursor:pointer}
#insHead .ttl{flex:1;font-weight:700;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#insBody{padding:8px 12px 12px;overflow:auto}
.irow{display:grid;grid-template-columns:78px 1fr;align-items:center;gap:6px;margin:4px 0}
.irow label{color:var(--muted);font-size:11.5px;font-family:var(--mono)}
.irow .ctl{display:flex;align-items:center;gap:5px;min-width:0}
.irow input[type=text],.irow input[type=number],.irow textarea{width:100%;font:12px var(--mono);padding:3px 6px;border:1px solid var(--line);border-radius:5px;background:#fff;color:var(--ink);min-width:0}
.irow input[type=number]{width:70px;flex:none}
.irow input[type=range]{flex:1;min-width:0;accent-color:var(--accent)}
.irow input[type=color]{width:30px;height:24px;padding:0;border:1px solid var(--line);border-radius:5px;background:#fff;flex:none}
.irow input:focus,.irow textarea:focus{outline:2px solid #f3b3cb;border-color:var(--accent)}
.irow.ro .v{font:12px var(--mono);color:var(--ink);overflow:hidden;text-overflow:ellipsis}
#insBody h3{margin:10px 0 4px;font-size:10.5px;letter-spacing:.9px;text-transform:uppercase;color:var(--muted)}
#insBody textarea{height:74px;resize:vertical}
.ibtns{display:flex;flex-wrap:wrap;gap:5px;margin-top:8px}
#evalOut{font:11.5px var(--mono);color:#35506f;margin-top:3px;min-height:15px;word-break:break-all}
#help{position:absolute;inset:40px 60px;background:rgba(255,255,255,.98);border:1px solid var(--line);border-radius:14px;box-shadow:0 20px 60px rgba(24,36,56,.3);z-index:10;display:none;padding:18px 24px;overflow:auto}
#help.on{display:block}
#help h2{margin:0 0 10px}
#help .cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:4px 28px}
#help h3{margin:10px 0 4px;font-size:11px;letter-spacing:.9px;text-transform:uppercase;color:var(--muted)}
#help code,.kbd{font:12px var(--mono);background:#f1f4f9;border:1px solid var(--line);border-radius:4px;padding:0 5px}
#help p{margin:3px 0}
#mode.search{background:#c59cf2}
/* ---------------- v2 ---------------- */
.morph.concealed,.fxv.concealed{display:none}
.morph.fdim,.fxv.fdim{opacity:.14}
.morph.sl-dim{opacity:.2}
.morph.sl-cut,.fxv.sl-cut{display:none}
.fx{pointer-events:none;display:none}
#stage.phys-on .fx{display:inline}
#stage.noshade .shade{display:none}
.fxv .arr{pointer-events:none}
.fxv.off{visibility:hidden}
#veilg,#slicefx,.fx *{pointer-events:none}
#viewSec .arow{display:flex;align-items:center;gap:8px;font-size:12px}
#viewSec .arow label{width:34px;color:var(--muted)}
#viewSec .arow input{flex:1}
#viewSec .arow span{width:34px;text-align:right;font:11px var(--mono);color:var(--muted)}
.chks{display:flex;flex-wrap:wrap;gap:2px 12px;font-size:11.5px;margin:5px 0 4px}
.chks label{display:flex;align-items:center;gap:4px;cursor:pointer}
.chks select{font-size:11px}
.btn.on{background:var(--accent);color:#fff;border-color:var(--accent)}
.tabs{float:right;display:inline-flex;gap:0}
.tabs button{font:600 10px system-ui,sans-serif;padding:1px 8px;border:1px solid var(--line);background:#fff;color:var(--muted);cursor:pointer;letter-spacing:.3px;text-transform:none}
.tabs button:first-child{border-radius:6px 0 0 6px}.tabs button:last-child{border-radius:0 6px 6px 0;border-left:0}
.tabs button.on{background:var(--accent);color:#fff;border-color:var(--accent)}
.ai{display:flex;align-items:center;gap:4px;padding:1px 10px 1px 8px;font-size:12px;cursor:pointer;white-space:nowrap;overflow:hidden}
.ai:hover{background:#f1f4f9}
.ai.sel{background:var(--accent);color:#fff}
.ai.off .lb{text-decoration:line-through;opacity:.55}
.ai .ar{width:10px;color:var(--muted);flex:none;font-size:10px}
.ai.sel .ar,.ai.sel .kc{color:#dce8ff}
.ai .lb{overflow:hidden;text-overflow:ellipsis}
.ai .kc{margin-left:auto;font:10px var(--mono);color:var(--muted);padding-left:8px;flex:none}
#crumbs{position:absolute;top:10px;left:14px;max-width:58%;font-size:12px;background:rgba(255,255,255,.88);border:1px solid var(--line);border-radius:8px;padding:5px 10px;z-index:4;display:flex;flex-wrap:wrap;align-items:center;gap:0}
#crumbs .c{cursor:pointer;color:#35507a;padding:0 2px;border-radius:4px}
#crumbs .c:hover{background:#e8eef9}
#crumbs .c.reg{cursor:default;color:var(--muted)}
#crumbs .c.cur{font-weight:700;color:#10151c;cursor:default}
#crumbs .sep{color:#9aa6b8;margin:0 3px}
#crumbs .hintc{color:var(--muted);font-size:11px;white-space:pre}
#legend{position:absolute;top:50px;left:14px;width:262px;background:rgba(255,255,255,.9);border:1px solid var(--line);border-radius:10px;padding:6px 8px;z-index:4;font-size:11.5px}
#legend .lh{display:flex;justify-content:space-between;margin-bottom:3px}
#legend .x{cursor:pointer;color:var(--muted);padding:0 4px}
#legend .lr{display:flex;align-items:center;gap:7px;padding:1px 3px;cursor:pointer;border-radius:5px;line-height:1.25}
#legend .lr:hover{background:#eef2f9}#legend .lr.on{background:#dde9ff}#legend .lr.plain{cursor:default}
#legend .lr i{width:18px;height:5px;border-radius:3px;flex:none}
#legend .lr i.arrow{background:none;height:auto;font-size:9px;color:#444;font-style:normal;text-align:center}
#dock{position:absolute;left:14px;bottom:42px;width:348px;display:none;flex-direction:column;gap:8px;z-index:6;max-height:calc(100% - 150px)}
#dock.on{display:flex}
.dockp{display:none;background:rgba(255,255,255,.96);border:1px solid #d6dde8;border-radius:12px;box-shadow:0 10px 30px rgba(24,36,56,.18);padding:8px 10px;font-size:12px;overflow:auto}
.dockp .dh{display:flex;align-items:center;gap:8px;margin-bottom:6px}
.dockp .tag{font-size:10px;background:#fdecc8;color:#7a5200;border-radius:6px;padding:0 6px}
.dockp .x{margin-left:auto;cursor:pointer;color:var(--muted);font-size:16px;line-height:1}
.dockp button{font:inherit;padding:2px 7px;border:1px solid var(--line);background:#fff;border-radius:6px;cursor:pointer}
.dockp button.pri{background:var(--accent);color:#fff;border-color:var(--accent);min-width:36px}
.dockp button.on{background:var(--accent);color:#fff}
.tlctl{display:flex;align-items:center;gap:5px}
#tlT{margin-left:auto;font:11px var(--mono);color:var(--muted)}
#tlScrub,#slPos{width:100%;margin:5px 0 2px}
#tlc{width:100%;height:auto;display:block}
#tlPh{font-size:11.5px;line-height:1.35;margin:3px 0}
#tlPh .ph{color:#9b2c3d;font-weight:600}
.tlsl label{display:flex;align-items:center;gap:6px;font-size:11.5px}
.tlsl label input{flex:1}.tlsl label span{width:54px;text-align:right;font:11px var(--mono)}
.dockp .note{font-size:10.5px;color:#6b5560;line-height:1.35;margin-top:4px}
#tlParams{font-size:10.5px;color:var(--muted);line-height:1.4;margin-top:3px}#tlParams .src{margin-top:3px;font-style:italic}
#slModes{display:flex;gap:4px}#slModes button{flex:1}
#slInfo{font-size:11.5px;font-weight:600;margin-top:2px}#slCount{font-size:10.5px;color:var(--muted)}
#slList{max-height:176px;overflow:auto;border:1px solid #e3e8f0;border-radius:6px;margin:4px 0}
#slList .slh{background:#f1f4f9;font:600 10px system-ui,sans-serif;letter-spacing:.6px;text-transform:uppercase;color:var(--muted);padding:1px 6px;position:sticky;top:0}
#slList .slr{display:flex;align-items:center;gap:6px;padding:1px 6px;cursor:pointer;font-size:11.5px}
#slList .slr:hover{background:#eef2f9}
#slList .slr i{width:9px;height:9px;border-radius:50%;flex:none;border:1px solid rgba(0,0,0,.2)}
#slList .slr .nm{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#slList .slr .dt{color:var(--muted);font-size:10.5px;max-width:48%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#slList .sln{padding:4px 8px;color:var(--muted);font-size:11px}
.irow.sg .ctl{flex-wrap:wrap;gap:3px}
.irow.sg .sgt{font-size:11px;color:#3b4658;line-height:1.35}
.chip{font:11px system-ui,sans-serif;padding:0 6px;border:1px solid #cdd6e4;background:#f5f8fc;border-radius:9px;cursor:pointer;color:#254a86}
.chip:hover:not([disabled]){background:#dbe8ff}.chip[disabled]{color:#8793a5;cursor:default}
#valid{position:absolute;inset:40px 120px;background:rgba(255,255,255,.98);border:1px solid var(--line);border-radius:14px;box-shadow:0 20px 60px rgba(24,36,56,.3);z-index:11;display:none;padding:16px 22px;overflow:auto}
#valid.on{display:block}
#valid h2{margin:0 0 6px}#valid .vs{margin:0 0 10px;color:var(--muted)}#valid .vf{margin:12px 0;color:#5a4a1a;background:#fff8e1;padding:6px 10px;border-radius:8px;font-size:12px}
#valid .vr{display:flex;gap:10px;padding:3px 0;border-bottom:1px solid #eef1f6;font-size:12px;align-items:baseline}
#valid .vr .b{font:700 10px var(--mono);padding:0 6px;border-radius:5px;color:#fff;background:#2e9e5b;flex:none}
#valid .vr.warn .b{background:#d98a00}#valid .vr.fail .b{background:#d12e3a}
#valid .vr .nm{flex:1}#valid .vr .dt{color:var(--muted);max-width:50%;font-size:11px}
@@html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Morphic Atlas - 2D human anatomy (schematic)</title>
<style>
/*__CSS__*/
</style>
</head>
<body>
<div id="app">
  <aside id="side">
    <header>
      <h1>Morphic Atlas<small>2D schematic</small></h1>
      <div class="sub">Every layer &amp; piece is a live object: grab it, inspect it, edit it.</div>
    </header>
    <div class="sec" style="padding-bottom:4px"><h2>Layers</h2></div>
    <div id="layers"></div>
    <div class="sec">
      <h2>Explode</h2>
      <div id="explodeRow"><input id="explode" type="range" min="0" max="100" value="0" aria-label="Explode"><span id="explodeVal">0</span></div>
    </div>
    <div class="sec" id="viewSec">
      <h2>Anatomy view</h2>
      <div class="arow"><label for="skin">Skin</label><input id="skin" type="range" min="0" max="100" value="0" aria-label="Skin opacity"><span id="skinVal">0%</span></div>
      <div class="chks">
        <label><input type="checkbox" id="cShade" checked> shading</label>
        <label><input type="checkbox" id="cFocus"> focus branch</label>
        <label><input type="checkbox" id="cLegend" checked> legend</label>
      </div>
      <div class="btns">
        <button class="btn" id="bTl" title="T">Timeline</button>
        <button class="btn" id="bSlice" title="Z">Slice</button>
        <button class="btn" id="bVal" title=":validate">Checks</button>
      </div>
    </div>
    <div class="sec">
      <div class="btns">
        <button class="btn" id="bAll" title=":show all">Show all</button>
        <button class="btn" id="bFit" title="f / :fit">Fit</button>
        <button class="btn" id="bSave" title=":save">Save</button>
        <button class="btn" id="bLoad" title=":load">Load</button>
        <button class="btn" id="bExport" title=":export">Export JSON</button>
        <button class="btn" id="bImport" title=":import">Import</button>
        <button class="btn" id="bReset" title=":reset">Reset</button>
        <button class="btn" id="bHelp" title="?">Help</button>
      </div>
      <input id="fileIn" type="file" accept="application/json,.json" style="display:none">
    </div>
    <div class="sec" style="padding-bottom:2px"><h2>World browser<span class="tabs"><button id="tabSys" class="on">Systems</button><button id="tabAna">Anatomy</button></span></h2><input id="filter" placeholder="filter morphs…" autocomplete="off"></div>
    <div id="treeWrap"></div>
    <div id="attrib">
      <b>Schematic educational model &mdash; not diagnostic, not for clinical use.</b><br>
      Anatomy follows the lineage of <i>BodyParts3D</i> (The Database Center for Life Science, CC&nbsp;BY-SA&nbsp;2.1&nbsp;JP); venous / arterial styling inspired by classic public-domain educational diagrams (LadyofHats). All shapes here are original, simplified vector drawings generated by <code>build_atlas.rb</code>.
    </div>
  </aside>
  <main id="stagewrap">
    <svg id="stage" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Human anatomy atlas">
      <defs>
        <filter id="shadow" x="-10%" y="-5%" width="120%" height="112%"><feDropShadow dx="0" dy="1.6" stdDeviation="1.7" flood-color="#2d2230" flood-opacity=".28"/></filter>
        <filter id="shadowSkin" x="-15%" y="-5%" width="130%" height="112%"><feDropShadow dx="0" dy="4" stdDeviation="5" flood-color="#3a2a2a" flood-opacity=".28"/></filter>
      </defs>
      <g id="vp"></g>
    </svg>
    <svg id="halosvg"></svg>
    <div id="banner">Schematic educational model &mdash; not diagnostic &middot; animation is not a validated physiological model</div>
    <div id="crumbs"></div>
    <div id="legend"></div>
    <div id="dock">
      <div id="tl" class="dockp">
        <div class="dh"><b>Physiology timeline</b><span class="tag">schematic</span><span class="x" id="tlClose" title="close (T)">&times;</span></div>
        <div class="tlctl">
          <button id="tlRe" title="Replay from the start (:replay)">&#9198;</button><button id="tlBk" title="Step back (,)">&#9664;|</button><button id="tlPlay" class="pri" title="Play (space)">&#9654;</button><button id="tlFw" title="Step forward (.)">|&#9654;</button>
          <select id="tlSpd" title="playback speed"><option value="0.25">0.25&times;</option><option value="0.5">0.5&times;</option><option value="1" selected>1&times;</option><option value="2">2&times;</option></select>
          <span id="tlT">t = 0.00 s</span>
        </div>
        <input id="tlScrub" type="range" min="0" max="1000" value="0" title="position inside the current heartbeat">
        <canvas id="tlc" width="336" height="106"></canvas>
        <div id="tlPh"></div>
        <div class="tlsl">
          <label>Heart rate <input id="tlHr" type="range" min="60" max="100" value="72"><span id="tlHrV">72 bpm</span></label>
          <label>Breathing <input id="tlRr" type="range" min="12" max="20" value="15"><span id="tlRrV">15 /min</span></label>
        </div>
        <div class="chks">
          <label><input type="checkbox" id="tc_heart" checked> heartbeat</label>
          <label><input type="checkbox" id="tc_breath" checked> breathing</label>
          <label><input type="checkbox" id="tc_nerve" checked> nerve</label>
          <label><input type="checkbox" id="tc_flow" checked> flow arrows</label>
          <label><input type="checkbox" id="tc_portal" checked> portal flow</label>
        </div>
        <div class="note" id="tlDisc"></div>
        <details><summary>values used (textbook ranges)</summary><div id="tlParams"></div></details>
      </div>
      <div id="slice" class="dockp">
        <div class="dh"><b>Cross-section</b><span class="tag">approximate</span><span class="x" id="slClose" title="close (Z cycles planes)">&times;</span></div>
        <div id="slModes"><button data-m="axial">Axial</button><button data-m="sagittal">Sagittal</button><button data-m="coronal">Coronal</button></div>
        <input id="slPos" type="range" min="0" max="840" value="250">
        <div id="slInfo"></div><div id="slCount"></div>
        <div class="chks"><label><input type="checkbox" id="slDim" checked> highlight what is cut</label><label><input type="checkbox" id="slClip"> clip</label>
          <select id="slKeep"><option>keep above</option><option>keep below</option></select></div>
        <div id="slList"></div>
        <div class="note">The plane cuts the flat 2D drawing, so this lists which drawn structures it crosses. It is an approximation, not a true 3D slice.</div>
      </div>
    </div>
    <div id="valid"></div>
    <div id="hint">drag = move &middot; Alt+drag = move layer &middot; drag background = pan &middot; wheel = zoom &middot; double-click = isolate system &middot; right-click / <span class="kbd">i</span> = inspector &middot; <span class="kbd">:</span> command &middot; <span class="kbd">?</span> help</div>
    <div id="tip"></div>
    <div id="inspector"><div id="insHead"><span class="orb" id="insClose" title="close"></span><span class="ttl" id="insTitle">Inspector</span></div><div id="insBody"></div></div>
    <div id="help"></div>
  </main>
  <footer id="modeline">
    <span id="mode">-- NORMAL --</span>
    <span id="selinfo">no selection</span>
    <span id="cmdwrap"><span id="cmdpre">:</span><input id="cmd" autocomplete="off" spellcheck="false"></span>
    <span id="msg">Morphic Atlas ready &mdash; press ? for help</span>
    <span id="pend"></span>
    <span id="info"></span>
  </footer>
</div>
<script>
/*__JS__*/
</script>
</body>
</html>
@@js
(() => {
'use strict';
/* ======================================================================
 * Morphic Atlas -- a tiny Self-style Morphic world.
 * Every layer and every anatomical piece is a live object ("morph") with
 * slots you can drag, halo, inspect, edit, duplicate, delete, save, export.
 * The anatomy data is generated by build_atlas.rb into WORLD0 below.
 * ==================================================================== */
const WORLD0 = /*__WORLD__*/;
const NS = 'http://www.w3.org/2000/svg';
const LS_KEY = 'morphic-atlas.world.v1';
const EXPLODE_STEP = 2.0;
const $ = (s, r = document) => r.querySelector(s);
const svg = (tag, attrs = {}, parent) => {
  const e = document.createElementNS(NS, tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  if (parent) parent.appendChild(e);
  return e;
};
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const r2 = (v) => Math.round(v * 100) / 100;
const deepCopy = (o) => JSON.parse(JSON.stringify(o));
const memStore = {};
const store = {
  get(k) { try { return localStorage.getItem(k); } catch (e) { return memStore[k] ?? null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) { memStore[k] = v; } },
  del(k) { try { localStorage.removeItem(k); } catch (e) { delete memStore[k]; } }
};

const stage = $('#stage'), vp = $('#vp'), halosvg = $('#halosvg'), wrap = $('#stagewrap');
const W = {
  layers: [], layerById: {}, explode: 0, iso: null, sel: null,
  view: { tx: 0, ty: 0, k: 1 }, autoFit: true, lastExplode: 60,
  undo: [], redo: [], committed: '', defaults: null
};

/* ------------------------------------------------------------ slots */
const MORPH_SLOTS = {
  label: 'text', fill: 'paint', stroke: 'paint', strokeWidth: 'num', opacity: 'num',
  x: 'num', y: 'num', rotation: 'num', scaleX: 'num', scaleY: 'num', dash: 'text', visible: 'bool'
};
const LAYER_SLOTS = { label: 'text', color: 'paint', visible: 'bool', opacity: 'num', x: 'num', y: 'num' };
function coerce(type, v, old) {
  if (type === 'num') { const n = typeof v === 'number' ? v : parseFloat(v); return Number.isFinite(n) ? n : old; }
  if (type === 'bool') return v === true || v === 'true' || v === 1 || v === '1' || v === 'on' || v === 'yes';
  return v == null ? '' : String(v);
}

class Morph {
  constructor(def, layer) {
    this.id = def.id; this.system = def.system; this.layer = layer;
    this.shape = deepCopy(def.shape); this.rule = def.rule || null;
    this._ = {
      label: def.label, fill: def.fill == null ? 'none' : def.fill, stroke: def.stroke == null ? 'none' : def.stroke,
      strokeWidth: def.strokeWidth ?? def.stroke_width ?? 1, opacity: def.opacity ?? 1,
      x: def.x || 0, y: def.y || 0, rotation: def.rotation || 0, scaleX: def.scaleX ?? 1, scaleY: def.scaleY ?? 1,
      dash: def.dash || '', visible: def.visible !== false
    };
    this.pivot = { x: 0, y: 0 };
    this.g = svg('g', { class: 'morph', 'data-id': this.id });
    this.g.__m = this;
    this.ag = svg('g', { class: 'anim' }, this.g);   // physiology animation transforms live here, apart from the user's own transform
    this.el = this.makeShape('shape');
    this.ag.appendChild(this.el);
    this.hit = null;
  }
  makeShape(cls) {
    const s = this.shape, e = svg(s.type === 'path' ? 'path' : s.type, { class: cls });
    this.writeShape(e);
    return e;
  }
  writeShape(e) { for (const k in this.shape) if (k !== 'type') e.setAttribute(k === 'w' ? 'width' : k === 'h' ? 'height' : k, this.shape[k]); }
  setShape(k, v) { this.shape[k] = v; this.writeShape(this.el); if (this.hit) this.writeShape(this.hit); this.computePivot(); this.apply(); W.changed(this, 'shape'); }
  computePivot() {
    try { const b = this.el.getBBox(); this.pivot = { x: b.x + b.width / 2, y: b.y + b.height / 2 }; } catch (e) { /* not rendered */ }
  }
  set(name, v) {
    const t = MORPH_SLOTS[name]; if (!t) return;
    const nv = coerce(t, v, this._[name]);
    if (name === 'opacity') this._[name] = clamp(nv, 0, 1);
    else if (name === 'strokeWidth') this._[name] = Math.max(0, nv);
    else this._[name] = nv;
    this.apply(); W.changed(this, name);
  }
  get color() { return this._.fill !== 'none' ? this._.fill : this._.stroke; }
  set color(v) { this.set(this._.fill !== 'none' ? 'fill' : 'stroke', v); }
  apply() {
    const s = this._, p = this.pivot, e = this.el;
    this.g.setAttribute('transform', `translate(${r2(s.x)} ${r2(s.y)}) translate(${r2(p.x)} ${r2(p.y)}) rotate(${r2(s.rotation)}) scale(${r2(s.scaleX)} ${r2(s.scaleY)}) translate(${r2(-p.x)} ${r2(-p.y)})`);
    e.setAttribute('fill', s.fill); e.setAttribute('stroke', s.stroke);
    e.setAttribute('stroke-width', s.strokeWidth); e.setAttribute('opacity', s.opacity);
    if (s.dash) e.setAttribute('stroke-dasharray', s.dash); else e.removeAttribute('stroke-dasharray');
    if (this.rule) e.setAttribute('fill-rule', this.rule);
    this.g.classList.toggle('dashed', !!s.dash);
    this.g.classList.toggle('off', !s.visible);
    const needHit = s.fill === 'none';
    if (needHit && !this.hit) { this.hit = this.makeShape('hit'); this.hit.setAttribute('fill', 'none'); this.hit.setAttribute('stroke', 'transparent'); this.hit.style.pointerEvents = 'stroke'; this.ag.appendChild(this.hit); }
    if (!needHit && this.hit) { this.hit.remove(); this.hit = null; }
    if (this.hit) this.hit.setAttribute('stroke-width', Math.max(5, s.strokeWidth + 3));
  }
  data() { return { id: this.id, system: this.system, shape: deepCopy(this.shape), rule: this.rule, ...deepCopy(this._) }; }
  get title() { return this._.label; }
}
for (const n in MORPH_SLOTS) Object.defineProperty(Morph.prototype, n, { get() { return this._[n]; }, set(v) { this.set(n, v); } });

class Layer {
  constructor(def) {
    this.id = def.id; this.order = def.order; this.z = def.z;
    this._ = { label: def.label, color: def.color, visible: def.visible !== false, opacity: def.opacity ?? 1, x: def.x || 0, y: def.y || 0 };
    this.morphs = [];
    this.g = svg('g', { class: 'layer', 'data-layer': this.id });
    this.g.__l = this;
    this.plate = svg('g', { class: 'layer-plate' }, this.g);
    this.rect = svg('rect', { x: -8, y: 6, width: 416, height: 836, rx: 18, fill: 'rgba(255,255,255,.28)', 'stroke-width': 1.4, 'stroke-dasharray': '6 5' }, this.plate);
    this.tag = svg('text', { class: 'layer-tag', x: 10, y: 24 }, this.g);
    this.items = svg('g', { class: 'items' }, this.g);
    this.fx = svg('g', { class: 'fx' }, this.g);      // flow arrows, pulse glow, nerve signals
    this.items.setAttribute('filter', this.id === 'skin' ? 'url(#shadowSkin)' : 'url(#shadow)');
  }
  set(name, v) {
    const t = LAYER_SLOTS[name]; if (!t) return;
    const nv = coerce(t, v, this._[name]);
    this._[name] = name === 'opacity' ? clamp(nv, 0, 1) : nv;
    this.apply(); W.changed(this, name);
  }
  get shown() { return this._.visible && (!W.iso || W.iso === this.id); }
  get explodeOffset() { return (this.order - (W.layers.length - 1) / 2) * W.explode * EXPLODE_STEP; }
  // exploded layers are also tilted/squashed like plates seen from an angle, so the stack stays readable
  get squash() { return 1 - 0.7 * clamp(W.explode / 100, 0, 1); }
  apply() {
    const sy = this.squash;
    this.g.setAttribute('transform', `translate(${r2(this._.x)} ${r2(this._.y + this.explodeOffset)}) translate(0 420) scale(1 ${r2(sy)}) translate(0 -420)`);
    this.tag.setAttribute('transform', `translate(10 24) scale(1 ${r2(1 / sy)}) translate(-10 -24)`);
    this.g.setAttribute('opacity', this._.opacity);
    this.g.classList.toggle('off', !this.shown);
    this.tag.textContent = this._.label; this.tag.setAttribute('fill', this._.color);
    this.rect.setAttribute('stroke', this._.color);
    const pl = clamp(W.explode / 12, 0, 1);
    this.plate.setAttribute('opacity', pl); this.tag.setAttribute('opacity', pl);
    this.tag.style.pointerEvents = pl > 0.3 ? 'all' : 'none';
  }
  data() { return { id: this.id, order: this.order, z: this.z, ...deepCopy(this._) }; }
  get title() { return this._.label + ' (layer)'; }
  get visibleMorphs() { return this.morphs.filter((m) => m._.visible); }
}
for (const n in LAYER_SLOTS) Object.defineProperty(Layer.prototype, n, { get() { return this._[n]; }, set(v) { this.set(n, v); } });

/* --------------------------------------------------------- the world */
function buildWorld(state) {
  const keepSel = W.sel && W.sel.id;
  vp.textContent = ''; W.layers = []; W.layerById = {};
  const defs = [...state.layers].sort((a, b) => a.z - b.z);
  for (const d of defs) { const l = new Layer(d); W.layers.push(l); W.layerById[l.id] = l; vp.appendChild(l.g); }
  for (const md of state.morphs) {
    const l = W.layerById[md.system]; if (!l) continue;
    const m = new Morph(md, l); l.morphs.push(m); l.items.appendChild(m.g);
  }
  for (const l of W.layers) l.g.classList.remove('off');
  for (const l of W.layers) for (const m of l.morphs) { m.computePivot(); m.apply(); }
  W.layers.sort((a, b) => a.order - b.order);   // panel / explode order
  W.layers.forEach((l) => l.apply());
  W.sel = null;
  if (keepSel) W.sel = W.layerById[keepSel] || findMorph(keepSel) || null;
  if (typeof v2Build === 'function') v2Build();
  renderLayers(); renderTree(); W.changed(null, 'rebuild');
}
const allMorphs = () => W.layers.flatMap((l) => l.morphs);
const findMorph = (id) => allMorphs().find((m) => m.id === id);

function worldState() { return { layers: W.layers.map((l) => l.data()), morphs: allMorphs().map((m) => m.data()) }; }
function fullSnapshot() {
  return { format: 'morphic-atlas-world', version: 1, savedAt: new Date().toISOString(), explode: W.explode, iso: W.iso,
    view: { ...W.view }, ...worldState() };
}
function restoreFull(snap, opts = {}) {
  if (!snap || snap.format !== 'morphic-atlas-world' || !Array.isArray(snap.morphs) || !Array.isArray(snap.layers)) throw new Error('not a Morphic Atlas world');
  buildWorld({ layers: snap.layers, morphs: snap.morphs });
  W.explode = clamp(+snap.explode || 0, 0, 100); W.iso = snap.iso && W.layerById[snap.iso] ? snap.iso : null;
  W.layers.forEach((l) => l.apply());
  $('#explode').value = W.explode; $('#explodeVal').textContent = Math.round(W.explode);
  if (snap.view && !opts.keepView) { Object.assign(W.view, snap.view); W.autoFit = false; applyView(); }
  if (opts.fit) fitView();
  renderLayers(); updateTreeState(); W.changed(null, 'restore');
}
const stateKey = () => JSON.stringify(worldState());
function commit() {
  const now = stateKey();
  if (now === W.committed) return;
  W.undo.push(W.committed); if (W.undo.length > 80) W.undo.shift();
  W.redo.length = 0; W.committed = now;
}
function undo() {
  if (!W.undo.length) return say('Already at oldest change', true);
  W.redo.push(stateKey()); const prev = W.undo.pop(); W.committed = prev;
  buildWorld(JSON.parse(prev)); W.layers.forEach((l) => l.apply()); say('undo');
}
function redo() {
  if (!W.redo.length) return say('Already at newest change', true);
  W.undo.push(stateKey()); const nxt = W.redo.pop(); W.committed = nxt;
  buildWorld(JSON.parse(nxt)); W.layers.forEach((l) => l.apply()); say('redo');
}

let haloQueued = false;
W.changed = function (obj, slot) {
  if (!haloQueued) { haloQueued = true; requestAnimationFrame(() => { haloQueued = false; updateHalo(); }); }
  updateInfo(); updateSelInfo();
  if (slot === 'visible' || slot === 'label' || slot === 'rebuild' || slot === 'restore') updateTreeState();
  if (obj && inspectorTarget === obj) refreshInspector();
  if (slot === 'visible' || slot === 'rebuild' || slot === 'restore' || slot === 'color') renderLayers();
};

/* -------------------------------------------------------------- view */
function applyView() { const v = W.view; vp.setAttribute('transform', `translate(${r2(v.tx)} ${r2(v.ty)}) scale(${v.k})`); updateHalo(); updateInfo(); }
function contentBounds() {
  let y0 = Infinity, y1 = -Infinity, x0 = Infinity, x1 = -Infinity;
  for (const l of W.layers) {
    if (!l.shown) continue;
    const off = l._.y + l.explodeOffset + 420 * (1 - l.squash);
    y0 = Math.min(y0, off + 6 * l.squash); y1 = Math.max(y1, off + 842 * l.squash); x0 = Math.min(x0, l._.x - 8); x1 = Math.max(x1, l._.x + 408);
  }
  if (!isFinite(y0)) { y0 = 0; y1 = 840; x0 = 0; x1 = 400; }
  return { x0, x1, y0, y1 };
}
function fitView() {
  const r = stage.getBoundingClientRect(), b = contentBounds();
  const pl = W.padL || 0, k = Math.min((r.width - 40 - pl) / (b.x1 - b.x0), (r.height - 56) / (b.y1 - b.y0));
  W.view.k = k; W.view.tx = pl + (r.width - pl - (b.x1 - b.x0) * k) / 2 - b.x0 * k; W.view.ty = (r.height - (b.y1 - b.y0) * k) / 2 - b.y0 * k + 6;
  W.autoFit = true; applyView();
}
function toWorld(cx, cy) { const r = stage.getBoundingClientRect(); return { x: (cx - r.left - W.view.tx) / W.view.k, y: (cy - r.top - W.view.ty) / W.view.k }; }
stage.addEventListener('wheel', (e) => {
  e.preventDefault();
  const r = stage.getBoundingClientRect(), px = e.clientX - r.left, py = e.clientY - r.top, v = W.view;
  const nk = clamp(v.k * Math.exp(-e.deltaY * 0.0016), 0.15, 8);
  v.tx = px - (px - v.tx) * (nk / v.k); v.ty = py - (py - v.ty) * (nk / v.k); v.k = nk; W.autoFit = false; applyView();
}, { passive: false });

/* ----------------------------------------------------------- explode */
let exTimer = 0;
function setExplode(v, animate) {
  v = clamp(Math.round(v), 0, 100);
  const from = W.explode, t0 = performance.now(), dur = 320;
  cancelAnimationFrame(exTimer);
  const step = (t) => {
    const u = animate ? clamp((t - t0) / dur, 0, 1) : 1, e = u < .5 ? 2 * u * u : 1 - Math.pow(-2 * u + 2, 2) / 2;
    W.explode = animate ? from + (v - from) * e : v;
    W.layers.forEach((l) => l.apply());
    $('#explode').value = W.explode; $('#explodeVal').textContent = Math.round(W.explode);
    if (W.autoFit) fitView(); else updateHalo();
    updateInfo();
    if (u < 1) exTimer = requestAnimationFrame(step); else W.explode = v;
  };
  if (animate) exTimer = requestAnimationFrame(step); else step(t0);
  if (v > 0) W.lastExplode = v;
}
$('#explode').addEventListener('input', (e) => setExplode(+e.target.value, false));
$('#explode').addEventListener('change', () => commit());

/* ---------------------------------------------------------- isolation */
function shownAll() { W.layers.forEach((l) => l.apply()); renderLayers(); updateTreeState(); if (W.autoFit) fitView(); updateInfo(); updateHalo(); }
function isolate(id) { W.iso = (id && W.iso !== id) ? id : null; shownAll(); say(W.iso ? 'isolated: ' + W.layerById[W.iso].label : 'showing all layers'); }
function setIso(id) { W.iso = id; shownAll(); }

/* --------------------------------------------------------- messages */
const msgEl = $('#msg');
function say(t, err) { msgEl.textContent = t; msgEl.className = err ? 'err' : ''; }

/* --------------------------------------------------------- selection */
function select(o, opts = {}) {
  W.sel = o || null;
  if (typeof v2Select === 'function') v2Select();
  updateTreeState(); updateHalo(); updateSelInfo(); updateInfo();
  if (inspectorOpen) { if (o) openInspector(o, opts.focus); else closeInspector(); }
  if (o && opts.scroll !== false) { const it = $('.ti.sel') || $('.lrow.sel'); if (it) it.scrollIntoView({ block: 'nearest' }); }
}
const isMorph = (o) => o instanceof Morph;
const layerOf = (o) => (o instanceof Layer ? o : o && o.layer);
function updateSelInfo() {
  const s = W.sel, e = $('#selinfo');
  e.textContent = !s ? 'no selection' : isMorph(s) ? `${s.layer._.label} > ${s._.label} [${s.id}]` : `layer ${s._.label} [${s.id}]`;
}
function updateInfo() {
  const n = allMorphs().length;
  $('#info').textContent = `explode ${Math.round(W.explode)} | iso ${W.iso || '-'} | zoom ${Math.round(W.view.k * 100)}% | ${n} morphs`;
}

/* ------------------------------------------------------ layer panel */
function renderLayers() {
  const box = $('#layers'); box.textContent = '';
  for (const l of W.layers) {
    const row = document.createElement('div'); row.className = 'lrow' + (W.sel === l ? ' sel' : '') + (W.iso && W.iso !== l.id ? ' dim' : ''); row.dataset.layer = l.id;
    const cb = document.createElement('input'); cb.type = 'checkbox'; cb.checked = l._.visible; cb.title = 'show / hide layer'; cb.dataset.act = 'vis';
    cb.addEventListener('change', () => { l.visible = cb.checked; shownAll(); commit(); });
    const dot = document.createElement('span'); dot.className = 'dot'; dot.style.background = l._.color;
    const nm = document.createElement('span'); nm.className = 'name'; nm.textContent = l._.label; nm.title = 'click: select layer · double-click: isolate';
    nm.addEventListener('click', () => select(l)); nm.addEventListener('dblclick', () => isolate(l.id));
    const cnt = document.createElement('span'); cnt.className = 'cnt'; cnt.textContent = l.morphs.length;
    const ib = document.createElement('button'); ib.textContent = '◎'; ib.title = 'isolate this system (click again to restore)'; ib.dataset.act = 'iso';
    if (W.iso === l.id) ib.classList.add('on');
    ib.addEventListener('click', () => isolate(l.id));
    row.append(cb, dot, nm, cnt, ib); box.appendChild(row);
  }
}
$('#bAll').onclick = () => cmd.showAll();
$('#bFit').onclick = () => fitView();
$('#bSave').onclick = () => cmd.save();
$('#bLoad').onclick = () => cmd.load();
$('#bExport').onclick = () => cmd.exportJson();
$('#bImport').onclick = () => $('#fileIn').click();
$('#bReset').onclick = () => cmd.reset();
$('#bHelp').onclick = () => toggleHelp();
$('#fileIn').addEventListener('change', async (e) => {
  const f = e.target.files[0]; if (!f) return;
  try { restoreFull(JSON.parse(await f.text()), { fit: true }); commit(); say(`imported ${f.name}`); } catch (err) { say('import failed: ' + err.message, true); }
  e.target.value = '';
});

/* --------------------------------------------------- world browser */
const treeOpen = new Set(['skeleton']);
function renderTree() {
  if (V2.treeMode === 'anatomy') return v2RenderAnatomy();
  const box = $('#treeWrap'); box.textContent = '';
  for (const l of W.layers) {
    const h = document.createElement('div'); h.className = 'tl'; h.dataset.layer = l.id;
    h.innerHTML = `<span>${treeOpen.has(l.id) ? '▾' : '▸'}</span><span></span>`; h.lastChild.textContent = `${l._.label} (${l.morphs.length})`;
    h.addEventListener('click', () => { treeOpen.has(l.id) ? treeOpen.delete(l.id) : treeOpen.add(l.id); renderTree(); });
    box.appendChild(h);
    if (treeOpen.has(l.id) || $('#filter').value) {
      const q = $('#filter').value.toLowerCase();
      for (const m of l.morphs) {
        if (q && !(m._.label.toLowerCase().includes(q) || m.id.includes(q))) continue;
        const it = document.createElement('div'); it.className = 'ti'; it.dataset.id = m.id; it.textContent = m._.label;
        it.addEventListener('click', () => select(m, { scroll: false })); box.appendChild(it);
      }
    }
  }
  updateTreeState();
}
function updateTreeState() {
  document.querySelectorAll('.ti').forEach((it) => { const m = findMorph(it.dataset.id); if (!m) return; it.classList.toggle('sel', W.sel === m); it.classList.toggle('off', !m._.visible); it.textContent = m._.label; });
  document.querySelectorAll('.lrow').forEach((r) => { const l = W.layerById[r.dataset.layer]; r.classList.toggle('sel', W.sel === l); r.classList.toggle('dim', !!W.iso && W.iso !== l.id); const cb = r.querySelector('input'); if (cb) cb.checked = l._.visible; const b = r.querySelector('[data-act=iso]'); if (b) b.classList.toggle('on', W.iso === l.id); });
}
$('#filter').addEventListener('input', renderTree);
$('#filter').addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.target.value = ''; e.target.blur(); renderTree(); } });

/* ===================================================== direct manipulation */
let drag = null;
const DRAG_PX = 3;
function morphAt(t) { const g = t.closest && t.closest('.morph'); return g ? g.__m : null; }
function beginMove(target, e, kind) {
  drag = { kind, target, sx: e.clientX, sy: e.clientY, x0: target._.x, y0: target._.y, moved: false, pre: stateKey(), alt: kind === 'layer' };
}
stage.addEventListener('pointerdown', (e) => {
  if (e.button === 2) return;
  stage.setPointerCapture && 0;
  const tag = e.target.closest && e.target.closest('.layer-tag');
  if (tag) { const l = tag.parentNode.__l; select(l); beginMove(l, e, 'layer'); e.preventDefault(); return; }
  const m = morphAt(e.target);
  if (m) {
    select(m, { scroll: true });
    beginMove(e.altKey ? m.layer : m, e, e.altKey ? 'layer' : 'morph');
    e.preventDefault();
  } else {
    drag = { kind: 'pan', sx: e.clientX, sy: e.clientY, tx0: W.view.tx, ty0: W.view.ty, moved: false };
    stage.classList.add('panning');
  }
});
stage.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  const m = morphAt(e.target); const tag = e.target.closest && e.target.closest('.layer-tag');
  if (m) select(m); else if (tag) select(tag.parentNode.__l);
  if (W.sel) { openInspector(W.sel); say('inspector: ' + W.sel.title); }
});
stage.addEventListener('dblclick', (e) => {
  const m = morphAt(e.target); if (m) { isolate(m.layer.id); return; }
  const tag = e.target.closest && e.target.closest('.layer-tag'); if (tag) isolate(tag.parentNode.__l.id);
});
window.addEventListener('pointermove', (e) => {
  if (!drag) { hover(e); return; }
  const d = drag, dx = e.clientX - d.sx, dy = e.clientY - d.sy;
  if (!d.moved && Math.hypot(dx, dy) < DRAG_PX) return;
  d.moved = true; $('#tip').style.display = 'none';
  const k = W.view.k;
  if (d.kind === 'pan') { W.view.tx = d.tx0 + dx; W.view.ty = d.ty0 + dy; W.autoFit = false; applyView(); return; }
  if (d.kind === 'morph' || d.kind === 'layer') { const sq = layerOf(d.target).squash; d.target.set('x', d.x0 + dx / k); d.target.set('y', d.y0 + dy / (k * sq)); return; }
  const h = d.halo;
  if (d.kind === 'rotate') {
    let a = Math.atan2(e.clientY - h.cy, e.clientX - h.cx) - h.a0, deg = h.r0 + a * 180 / Math.PI;
    if (e.shiftKey) deg = Math.round(deg / 15) * 15;
    d.target.set('rotation', Math.round(deg * 10) / 10);
  } else if (d.kind === 'resize') {
    const f = clamp(Math.hypot(e.clientX - h.cx, e.clientY - h.cy) / Math.max(1, h.d0), 0.05, 20);
    d.target.set('scaleX', r2(h.sx0 * f)); d.target.set('scaleY', r2(h.sy0 * f));
  }
});
window.addEventListener('pointerup', (e) => {
  const d = drag; drag = null; stage.classList.remove('panning');
  if (!d) return;
  if (d.kind === 'pan') { if (!d.moved) select(null); return; }
  if (d.moved) { W.committed = d.pre; commit(); }
  else if (d.click) d.click();
});
function hover(e) {
  const tip = $('#tip');
  if (!stage.contains(e.target)) { tip.style.display = 'none'; return; }
  const m = morphAt(e.target);
  if (!m) { tip.style.display = 'none'; return; }
  const r = wrap.getBoundingClientRect();
  tip.textContent = `${m._.label}  ·  ${m.layer._.label}`; tip.style.display = 'block';
  tip.style.left = Math.min(r.width - tip.offsetWidth - 8, e.clientX - r.left + 14) + 'px'; tip.style.top = (e.clientY - r.top + 16) + 'px';
}
stage.addEventListener('pointerleave', () => { $('#tip').style.display = 'none'; });

/* ------------------------------------------------------------- halo */
const ICONS = {
  delete: 'M-3.6 -3.6L3.6 3.6M3.6 -3.6L-3.6 3.6',
  rotate: 'M3.6 -1.4A4.2 4.2 0 1 0 3.8 1.6M3.9 -5.1L3.6 -1.4L0.2 -2.7',
  dup: 'M-4.4 -2.2H1.2V3.4H-4.4ZM-1.2 -4.6H4.4V1H-1.2Z',
  layer: 'M-4.5 -3.4H4.5M-4.5 0H4.5M-4.5 3.4H4.5',
  hide: 'M-5.4 0Q0 -5.6 5.4 0Q0 5.6 -5.4 0ZM0 -0.2V0.2',
  move: 'M0 -5V5M-5 0H5M0 -5L-1.8 -3.2M0 -5L1.8 -3.2M0 5L-1.8 3.2M0 5L1.8 3.2M-5 0L-3.2 -1.8M-5 0L-3.2 1.8M5 0L3.2 -1.8M5 0L3.2 1.8',
  inspect: 'M0 -3.8V-3.7M0 -1V4',
  resize: 'M-4 4L4 -4M-0.8 -4H4V0.8M0.8 4H-4V-0.8'
};
const HANDLES = [
  { id: 'delete', pos: [-1, -1], color: '#e5484d', tip: 'delete (dd)' },
  { id: 'rotate', pos: [0, -1], color: '#3b82f6', tip: 'rotate (drag, Shift = 15° steps)', drag: 1 },
  { id: 'dup', pos: [1, -1], color: '#34b36b', tip: 'duplicate (yy)' },
  { id: 'layer', pos: [-1, 0], color: '#f08a24', tip: 'drag: move whole layer · click: isolate layer', drag: 1 },
  { id: 'hide', pos: [1, 0], color: '#8793a6', tip: 'hide / show (x)' },
  { id: 'move', pos: [-1, 1], color: '#4b5568', tip: 'move (drag) · h j k l nudge', drag: 1 },
  { id: 'inspect', pos: [0, 1], color: '#8b5cf6', tip: 'inspector (i / right-click)' },
  { id: 'resize', pos: [1, 1], color: '#f2c230', tip: 'resize / scale (drag)', drag: 1 }
];
function screenQuad(sel) {
  const sr = stage.getBoundingClientRect();
  if (isMorph(sel)) {
    let b; try { b = sel.el.getBBox(); } catch (e) { return null; }
    const M = sel.g.getScreenCTM(); if (!M) return null;
    const P = (x, y) => { const p = new DOMPoint(x, y).matrixTransform(M); return [p.x - sr.left, p.y - sr.top]; };
    return [P(b.x, b.y), P(b.x + b.width, b.y), P(b.x + b.width, b.y + b.height), P(b.x, b.y + b.height)];
  }
  let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
  for (const m of sel.morphs) { if (!m._.visible) continue; const r = m.g.getBoundingClientRect(); if (!r.width && !r.height) continue; x0 = Math.min(x0, r.left); y0 = Math.min(y0, r.top); x1 = Math.max(x1, r.right); y1 = Math.max(y1, r.bottom); }
  if (x0 > x1) return null;
  x0 -= sr.left; x1 -= sr.left; y0 -= sr.top; y1 -= sr.top;
  return [[x0, y0], [x1, y0], [x1, y1], [x0, y1]];
}
let lastHalo = null;
function updateHalo() {
  halosvg.textContent = ''; lastHalo = null;
  const sel = W.sel; if (!sel) return;
  const q = screenQuad(sel); if (!q) return;
  const cx = (q[0][0] + q[2][0]) / 2, cy = (q[0][1] + q[2][1]) / 2;
  let ux = q[1][0] - q[0][0], uy = q[1][1] - q[0][1], vx = q[3][0] - q[0][0], vy = q[3][1] - q[0][1];
  let hu = Math.hypot(ux, uy) / 2, hv = Math.hypot(vx, vy) / 2;
  ux = hu ? ux / (2 * hu) : 1; uy = hu ? uy / (2 * hu) : 0; vx = hv ? vx / (2 * hv) : 0; vy = hv ? vy / (2 * hv) : 1;
  hu = Math.max(hu + 7, 24); hv = Math.max(hv + 7, 24);
  const P = (a, b) => [cx + ux * hu * a + vx * hv * b, cy + uy * hu * a + vy * hv * b];
  const corners = [P(-1, -1), P(1, -1), P(1, 1), P(-1, 1)];
  svg('polygon', { points: corners.map((p) => p.join(',')).join(' '), fill: 'rgba(224,69,123,.05)', stroke: '#e0457b', 'stroke-width': 1.6, 'stroke-dasharray': '5 4' }, halosvg);
  lastHalo = { cx, cy };
  const layerSel = !isMorph(sel);
  for (const h of HANDLES) {
    const [px, py] = P(h.pos[0], h.pos[1]);
    const g = svg('g', { class: 'hh' + (h.drag ? ' drag' : '') + (layerSel && ['delete', 'rotate', 'dup', 'resize'].includes(h.id) ? ' disabled' : ''), transform: `translate(${r2(px)} ${r2(py)})`, 'data-h': h.id }, halosvg);
    svg('title', {}, g).textContent = h.tip;
    svg('circle', { r: 10, fill: h.color, stroke: 'rgba(255,255,255,.9)', 'stroke-width': 1.6 }, g);
    svg('path', { d: ICONS[h.id], fill: 'none', stroke: '#fff', 'stroke-width': 1.7, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, g);
    g.addEventListener('pointerdown', (e) => haloDown(e, h));
  }
}
function haloDown(e, h) {
  e.preventDefault(); e.stopPropagation();
  const sel = W.sel; if (!sel) return;
  const sr = stage.getBoundingClientRect(), cx = lastHalo.cx + sr.left, cy = lastHalo.cy + sr.top;
  switch (h.id) {
    case 'delete': return deleteSel();
    case 'dup': return dupSel();
    case 'hide': return toggleHide();
    case 'inspect': return openInspector(sel);
    case 'move': return beginMove(sel, e, isMorph(sel) ? 'morph' : 'layer');
    case 'layer': beginMove(layerOf(sel), e, 'layer'); drag.click = () => isolate(layerOf(sel).id); return;
    case 'rotate':
      if (!isMorph(sel)) return;
      drag = { kind: 'rotate', target: sel, sx: e.clientX, sy: e.clientY, moved: false, pre: stateKey(), halo: { cx, cy, a0: Math.atan2(e.clientY - cy, e.clientX - cx), r0: sel._.rotation } }; return;
    case 'resize':
      if (!isMorph(sel)) return;
      drag = { kind: 'resize', target: sel, sx: e.clientX, sy: e.clientY, moved: false, pre: stateKey(), halo: { cx, cy, d0: Math.hypot(e.clientX - cx, e.clientY - cy), sx0: sel._.scaleX, sy0: sel._.scaleY } }; return;
  }
}

/* --------------------------------------------------- morph operations */
function toggleHide() { const s = W.sel; if (!s) return say('nothing selected', true); s.set('visible', !s._.visible); if (!isMorph(s)) shownAll(); commit(); say((s._.visible ? 'shown ' : 'hidden ') + s._.label); }
function deleteSel() {
  const s = W.sel; if (!isMorph(s)) return say(s ? 'layers cannot be deleted (hide them with x)' : 'nothing selected', true);
  const l = s.layer, i = l.morphs.indexOf(s); l.morphs.splice(i, 1); s.g.remove(); if (s.fxv) s.fxv.g.remove();
  W.sel = l.morphs[Math.min(i, l.morphs.length - 1)] || l;
  if (inspectorTarget === s) closeInspector();
  renderTree(); renderLayers(); updateHalo(); updateSelInfo(); updateInfo(); commit(); say(`deleted ${s._.label} (undo with u, restore all with :reset)`);
}
function dupSel() {
  const s = W.sel; if (!isMorph(s)) return say('select a morph to duplicate', true);
  const l = s.layer; let n = 1, id; do { id = `${s.id.replace(/_copy\d+$/, '')}_copy${n++}`; } while (findMorph(id));
  const d = s.data(); d.id = id; d.label = s._.label.replace(/ \(copy\)$/, '') + ' (copy)'; d.x += 12; d.y += 12;
  const m = new Morph(d, l); l.morphs.splice(l.morphs.indexOf(s) + 1, 0, m); s.g.after(m.g);
  m.computePivot(); m.apply(); renderTree(); renderLayers(); select(m); commit(); say('duplicated -> ' + id);
}
function nudge(dx, dy) {
  const s = W.sel; if (!s) return say('nothing selected (w = next morph, H/L = layers)', true);
  s.set('x', s._.x + dx); s.set('y', s._.y + dy);
}
function visibleMorphList() { return W.layers.filter((l) => l.shown).flatMap((l) => l.morphs.filter((m) => m._.visible && !m.concealed)); }
function cycleMorph(dir) {
  const list = visibleMorphList(); if (!list.length) return say('no visible morphs', true);
  let i;
  if (isMorph(W.sel)) { i = list.indexOf(W.sel); i = i < 0 ? (dir > 0 ? 0 : list.length - 1) : (i + dir + list.length) % list.length; }
  else if (W.sel instanceof Layer) { const mine = list.filter((m) => m.layer === W.sel); i = mine.length ? list.indexOf(dir > 0 ? mine[0] : mine[mine.length - 1]) : 0; }
  else i = dir > 0 ? 0 : list.length - 1;
  select(list[i]);
}
function cycleLayer(dir) {
  const list = W.layers.filter((l) => l.shown); if (!list.length) return say('no visible layers', true);
  const cur = layerOf(W.sel); let i = list.indexOf(cur);
  i = i < 0 ? (dir > 0 ? 0 : list.length - 1) : (i + dir + list.length) % list.length;
  select(list[i]);
}

/* ============================================================ inspector */
const ins = $('#inspector'), insBody = $('#insBody');
let inspectorOpen = false, inspectorTarget = null, insRefreshers = [];
const cvs = document.createElement('canvas').getContext('2d');
function toHex(c) {
  if (/^#[0-9a-f]{6}$/i.test(c)) return c;
  if (/^#[0-9a-f]{3}$/i.test(c)) return '#' + c.slice(1).split('').map((x) => x + x).join('');
  if (!c || c === 'none') return '#000000';
  cvs.fillStyle = '#000'; cvs.fillStyle = c; const v = cvs.fillStyle; return /^#/.test(v) ? v : '#000000';
}
const validPaint = (v) => v === 'none' || /^url\(/.test(v) || (window.CSS && CSS.supports('color', v));
function mkRow(label, ctl, cls = '') {
  const r = document.createElement('div'); r.className = 'irow ' + cls;
  const l = document.createElement('label'); l.textContent = label;
  const c = document.createElement('div'); c.className = 'ctl'; c.append(...[].concat(ctl)); r.append(l, c); insBody.appendChild(r); return r;
}
function bindField(target, slot, type) {
  const t = document.createElement('input');
  if (type === 'text') { t.type = 'text'; t.addEventListener('input', () => target.set(slot, t.value)); t.addEventListener('change', commit); insRefreshers.push(() => { if (document.activeElement !== t) t.value = target._[slot]; }); return [t]; }
  if (type === 'bool') { t.type = 'checkbox'; t.addEventListener('change', () => { target.set(slot, t.checked); if (!isMorph(target)) shownAll(); commit(); }); insRefreshers.push(() => { t.checked = !!target._[slot]; }); return [t]; }
  if (type === 'paint') {
    const c = document.createElement('input'); c.type = 'color';
    t.type = 'text';
    c.addEventListener('input', () => { target.set(slot, c.value); t.value = c.value; });
    c.addEventListener('change', commit);
    t.addEventListener('input', () => { if (validPaint(t.value.trim())) { target.set(slot, t.value.trim()); c.value = toHex(t.value.trim()); t.style.borderColor = ''; } else t.style.borderColor = '#e5484d'; });
    t.addEventListener('change', commit);
    insRefreshers.push(() => { if (document.activeElement !== t) t.value = target._[slot]; c.value = toHex(target._[slot]); });
    return [c, t];
  }
  return [t];
}
function numField(target, slot, o = {}) {
  const n = document.createElement('input'); n.type = 'number'; n.step = o.step ?? 1; if (o.min != null) n.min = o.min; if (o.max != null) n.max = o.max;
  const out = [];
  let rg = null;
  if (o.range) { rg = document.createElement('input'); rg.type = 'range'; rg.min = o.range[0]; rg.max = o.range[1]; rg.step = o.step ?? 1; rg.addEventListener('input', () => target.set(slot, rg.value)); rg.addEventListener('change', commit); out.push(rg); }
  n.addEventListener('input', () => { if (n.value !== '' && n.value !== '-') target.set(slot, n.value); }); n.addEventListener('change', commit);
  out.push(n);
  insRefreshers.push(() => { const v = r2(target._[slot]); if (document.activeElement !== n) n.value = v; if (rg) rg.value = v; });
  return out;
}
function openInspector(target, focus) {
  if (!target) { target = W.sel || visibleMorphList()[0]; if (!target) return; if (W.sel !== target) { W.sel = target; updateHalo(); updateTreeState(); updateSelInfo(); } }
  inspectorOpen = true; inspectorTarget = target; ins.classList.add('on'); insBody.textContent = ''; insRefreshers = [];
  const m = isMorph(target);
  $('#insTitle').textContent = 'Inspector · ' + (m ? target._.label : target._.label + ' (layer)');
  mkRow('id', Object.assign(document.createElement('span'), { className: 'v', textContent: target.id }), 'ro');
  mkRow(m ? 'system' : 'kind', Object.assign(document.createElement('span'), { className: 'v', textContent: m ? target.system : `layer · ${target.morphs.length} morphs` }), 'ro');
  mkRow('label', bindField(target, 'label', 'text'));
  if (m) {
    mkRow('fill', bindField(target, 'fill', 'paint'));
    mkRow('stroke', bindField(target, 'stroke', 'paint'));
    mkRow('width', numField(target, 'strokeWidth', { step: 0.1, min: 0, range: [0, 24] }));
    mkRow('opacity', numField(target, 'opacity', { step: 0.01, min: 0, max: 1, range: [0, 1] }));
    mkRow('x', numField(target, 'x', { step: 1, range: [-300, 300] }));
    mkRow('y', numField(target, 'y', { step: 1, range: [-300, 300] }));
    mkRow('rotation', numField(target, 'rotation', { step: 1, range: [-180, 180] }));
    mkRow('scaleX', numField(target, 'scaleX', { step: 0.05 }));
    mkRow('scaleY', numField(target, 'scaleY', { step: 0.05 }));
    mkRow('dash', bindField(target, 'dash', 'text'));
    mkRow('visible', bindField(target, 'visible', 'bool'));
    const h3 = document.createElement('h3'); h3.textContent = 'shape (' + target.shape.type + ')'; insBody.appendChild(h3);
    if (target.shape.type === 'path') {
      const ta = document.createElement('textarea'); ta.spellcheck = false; ta.value = target.shape.d;
      let tmr = 0; ta.addEventListener('input', () => { clearTimeout(tmr); tmr = setTimeout(() => target.setShape('d', ta.value), 120); }); ta.addEventListener('change', commit);
      const r = document.createElement('div'); r.className = 'irow'; r.style.gridTemplateColumns = '1fr'; r.appendChild(ta); insBody.appendChild(r);
    } else for (const k of Object.keys(target.shape).filter((k) => k !== 'type')) {
      const n = document.createElement('input'); n.type = 'number'; n.step = 1; n.value = target.shape[k];
      n.addEventListener('input', () => target.setShape(k, +n.value)); n.addEventListener('change', commit); mkRow(k, [n]);
    }
  } else {
    mkRow('color', bindField(target, 'color', 'paint'));
    mkRow('opacity', numField(target, 'opacity', { step: 0.01, min: 0, max: 1, range: [0, 1] }));
    mkRow('x', numField(target, 'x', { step: 1, range: [-300, 300] }));
    mkRow('y', numField(target, 'y', { step: 1, range: [-300, 300] }));
    mkRow('visible', bindField(target, 'visible', 'bool'));
  }
  if (m && typeof v2Inspector === 'function') v2Inspector(target);
  const h3 = document.createElement('h3'); h3.textContent = 'evaluate (this = ' + (m ? 'morph' : 'layer') + ', world)'; insBody.appendChild(h3);
  const ev = document.createElement('input'); ev.type = 'text'; ev.placeholder = 'this.strokeWidth = 4'; ev.spellcheck = false; ev.id = 'evalIn';
  const evo = document.createElement('div'); evo.id = 'evalOut';
  ev.addEventListener('keydown', (e) => { if (e.key === 'Enter') { evo.textContent = '⇒ ' + runEval(ev.value, target); commit(); } });
  const r = document.createElement('div'); r.className = 'irow'; r.style.gridTemplateColumns = '1fr'; r.appendChild(ev); insBody.append(r, evo);
  const b = document.createElement('div'); b.className = 'ibtns';
  const mk = (t, f) => { const x = document.createElement('button'); x.className = 'btn'; x.textContent = t; x.onclick = f; b.appendChild(x); };
  if (m) { mk('duplicate', dupSel); mk('delete', deleteSel); mk('hide/show', toggleHide); mk('isolate system', () => isolate(target.layer.id)); mk('select layer', () => select(target.layer)); mk('revert slots', () => revertMorph(target)); }
  else { mk('hide/show', toggleHide); mk('isolate', () => isolate(target.id)); mk('reset position', () => { target.set('x', 0); target.set('y', 0); commit(); }); }
  insBody.appendChild(b);
  refreshInspector();
  if (focus) { const f = insBody.querySelector('input[type=text]'); if (f) { f.focus(); f.select(); } }
}
function refreshInspector() { insRefreshers.forEach((f) => f()); if (inspectorTarget) $('#insTitle').textContent = 'Inspector · ' + inspectorTarget._.label + (isMorph(inspectorTarget) ? '' : ' (layer)'); }
function closeInspector() { inspectorOpen = false; inspectorTarget = null; ins.classList.remove('on'); if (document.activeElement && ins.contains(document.activeElement)) document.activeElement.blur(); setMode('normal'); }
$('#insClose').onclick = closeInspector;
function runEval(code, target) {
  try {
    let f; try { f = new Function('world', `"use strict"; return (${code});`); } catch (e) { f = new Function('world', `"use strict"; ${code}`); }
    const v = f.call(target, W);
    if (isMorph(target)) target.apply();
    return v === undefined ? 'undefined' : typeof v === 'object' ? (v && v.title) || JSON.stringify(v) : String(v);
  } catch (e) { return 'error: ' + e.message; }
}
function revertMorph(m) {
  const d = (WORLD0.morphs.find((x) => x.id === m.id.replace(/_copy\d+$/, '')) || null); if (!d) return say('no original', true);
  Object.assign(m._, { label: d.label, fill: d.fill ?? 'none', stroke: d.stroke ?? 'none', strokeWidth: d.stroke_width, opacity: d.opacity, x: 0, y: 0, rotation: 0, scaleX: 1, scaleY: 1, dash: d.dash || '', visible: true });
  m.apply(); W.changed(m, 'x'); commit(); say('slots reverted');
}
// drag the inspector window by its title bar
(() => {
  let d = null; const head = $('#insHead');
  head.addEventListener('pointerdown', (e) => { if (e.target.id === 'insClose') return; const r = ins.getBoundingClientRect(), w = wrap.getBoundingClientRect(); d = { dx: e.clientX - r.left, dy: e.clientY - r.top, w }; head.setPointerCapture(e.pointerId); });
  head.addEventListener('pointermove', (e) => { if (!d) return; ins.style.left = clamp(e.clientX - d.dx - d.w.left, 0, d.w.width - 120) + 'px'; ins.style.top = clamp(e.clientY - d.dy - d.w.top, 0, d.w.height - 40) + 'px'; ins.style.right = 'auto'; });
  head.addEventListener('pointerup', () => { d = null; });
})();

/* ================================================================== help */
const HELP = `
<h2>Morphic Atlas &mdash; help <small style="font-weight:400;color:#6b778a">(Esc or ? to close)</small></h2>
<p>Schematic educational model &mdash; <b>not diagnostic</b>. Each piece is a <i>morph</i>: a live object with slots (fill, stroke, width, opacity, x, y, rotation, scale, label, visible).</p>
<div class="cols">
<div><h3>Mouse (direct manipulation)</h3>
<p><code>drag</code> a morph to move it &middot; <code>Alt+drag</code> moves its whole layer</p>
<p><code>click</code> selects &rarr; pink <b>halo</b>: &#215; delete, &#8635; rotate, &#10697; duplicate, &#9776; layer (drag) / isolate (click), eye hide, &#10021; move, <b>i</b> inspect, &#10529; resize</p>
<p><code>double-click</code> a morph (or a layer name) &rarr; isolate its system; again to restore</p>
<p><code>right-click</code> a morph &rarr; Inspector &middot; drag background pans &middot; wheel zooms</p>
<p>When exploded, grab a layer by its <b>tag</b> (top-left of each plate)</p></div>
<div><h3>Vim keys &mdash; NORMAL mode</h3>
<p><code>h j k l</code> nudge selection (count: <code>5l</code>) &middot; <code>w</code>/<code>b</code> next/prev morph &middot; <code>gg</code>/<code>G</code> first/last</p>
<p><code>H</code>/<code>L</code> previous/next layer (selects the layer) &middot; <code>x</code> hide/show &middot; <code>s</code> isolate selection's system</p>
<p><code>e</code> toggle explode &middot; <code>J</code>/<code>K</code> explode &minus;/+5 &middot; <code>i</code> inspector (INSERT in first field)</p>
<p><code>dd</code> delete &middot; <code>yy</code> duplicate &middot; <code>u</code> undo &middot; <code>Ctrl-r</code> redo &middot; <code>r</code>/<code>R</code> rotate &plusmn;5&deg;</p>
<p><code>=</code>/<code>-</code> scale &plusmn;5% &middot; <code>[</code>/<code>]</code> opacity &plusmn;.05 &middot; <code>0</code> reset slots of selection &middot; <code>f</code> fit view</p>
<p><code>/text</code> find morph by label &middot; <code>n</code> next match &middot; <code>:</code> command line &middot; <code>Esc</code> back to NORMAL</p></div>
<div><h3>Command line</h3>
<p><code>:set color #aa0000</code> &middot; <code>:set width 3</code> &middot; <code>:set opacity .5</code> &middot; <code>:set label Foo</code> &middot; <code>:set x 10</code> &middot; <code>:set rotation 15</code> &middot; <code>:set scale 1.2</code> &middot; <code>:set fill|stroke|dash …</code></p>
<p><code>:iso arteries</code> &middot; <code>:iso off</code> &middot; <code>:show all|&lt;system&gt;</code> &middot; <code>:hide &lt;system&gt;</code> &middot; <code>:explode 40</code></p>
<p><code>:select &lt;text&gt;</code> &middot; <code>:layer &lt;system&gt;</code> &middot; <code>:move dx dy</code> &middot; <code>:rotate deg</code> &middot; <code>:scale f</code> &middot; <code>:dup</code> &middot; <code>:del</code> &middot; <code>:inspect</code></p>
<p><code>:save</code> &middot; <code>:load</code> &middot; <code>:export</code> (JSON file) &middot; <code>:import</code> &middot; <code>:reset</code> (<code>:reset!</code> also clears the saved world) &middot; <code>:fit</code> &middot; <code>:undo</code> &middot; <code>:redo</code> &middot; <code>:eval js</code></p>
<p>Systems: skin, skeleton, muscles, arteries, veins, pulmonary, organs, nerves</p></div>
<div><h3>Anatomy: hierarchy &amp; internals</h3>
<p><code>&gt;</code> drill down into the selected structure (liver &rarr; lobe &rarr; segment &rarr; vessels &rarr; smaller branches) &middot; <code>&lt;</code> back up to its anatomical parent &middot; <code>Tab</code> next sibling &middot; counts work (<code>3&gt;</code>)</p>
<p>Select an organ to reveal what is inside it (the liver shows its lobes, segments, hepatic artery, portal vein, hepatic veins and bile ducts).</p>
<p><code>:zoom</code> zooms to the selection (<code>:zoom out</code> to fit) &middot; <code>:children</code> &middot; <code>:parent</code> &middot; <code>:path</code> &middot; <code>:focus on|off</code> (dim everything outside the selection's branch) &middot; <code>:skin 0.4</code> or <code>(</code> / <code>)</code> skin opacity</p></div>
<div><h3>Physiology timeline (schematic)</h3>
<p><code>Space</code> play / pause &middot; <code>.</code> step forward &middot; <code>,</code> step back &middot; <code>:replay</code> &middot; <code>T</code> show / hide the timeline panel</p>
<p><code>:hr 60..100</code> heart rate &middot; <code>:rr 12..20</code> breathing rate &middot; <code>:speed 0.25..4</code> &middot; <code>:play</code> <code>:pause</code> <code>:step</code></p>
<p>The animation is a classroom sketch built from rounded textbook values. It is not a validated physiological model.</p></div>
<div><h3>Cross-sections (approximate)</h3>
<p><code>Z</code> slice panel &middot; <code>:slice axial 420</code> &middot; <code>:slice sagittal 200</code> &middot; <code>:slice coronal 0.5</code> &middot; <code>:slice off</code> &middot; <code>:validate</code> shows the anatomy checks</p></div>
<div><h3>Reading the veins</h3>
<p>Deep veins (IVC, common iliac, femoral, jugulars, SVC&hellip;) are drawn <b>thick &amp; opaque</b>; superficial veins (great saphenous, cephalic, basilic) are <b>thin &amp; translucent</b>. Arteries are red; pulmonary arteries purple.</p>
<h3>World</h3><p><code>:save</code> stores the whole world (all slots, layer offsets, explode, isolation, view) in this browser's localStorage; <code>:export</code> downloads it as JSON.</p></div>
</div>`;
$('#help').innerHTML = HELP;
function toggleHelp(force) { const h = $('#help'); h.classList.toggle('on', force ?? !h.classList.contains('on')); }

/* ==================================================== persistence & cmds */
const SYSTEMS_ALIAS = { vein: 'veins', artery: 'arteries', muscle: 'muscles', bone: 'skeleton', bones: 'skeleton', organ: 'organs', nerve: 'nerves', nervous: 'nerves', outline: 'skin', body: 'skin', deep: 'veins' };
function resolveLayer(name) {
  name = (name || '').toLowerCase().trim(); name = SYSTEMS_ALIAS[name] || name;
  return W.layers.find((l) => l.id === name) || W.layers.find((l) => l._.label.toLowerCase().startsWith(name)) || null;
}
function findByText(q) {
  q = q.toLowerCase(); const list = allMorphs();
  return list.filter((m) => m._.label.toLowerCase().includes(q) || m.id.toLowerCase().includes(q));
}
const cmd = {
  save() { store.set(LS_KEY, JSON.stringify(fullSnapshot())); say(`saved world to localStorage (${allMorphs().length} morphs)`); },
  load() { const s = store.get(LS_KEY); if (!s) return say('nothing saved yet — :save first', true); try { restoreFull(JSON.parse(s)); commit(); say('loaded saved world'); } catch (e) { say('load failed: ' + e.message, true); } },
  exportJson() {
    const blob = new Blob([JSON.stringify(fullSnapshot(), null, 2)], { type: 'application/json' });
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'morphic-atlas-world.json'; document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 4000); say('exported morphic-atlas-world.json');
  },
  reset(hard) {
    W.iso = null; buildWorld(deepCopy(W.defaults)); setExplode(0, false); W.sel = null; select(null); fitView(); commit();
    if (hard) { store.del(LS_KEY); say('world reset (saved copy cleared too)'); } else say('world reset to defaults (saved copy kept; :reset! clears it)');
  },
  showAll() { W.iso = null; W.layers.forEach((l) => { l._.visible = true; }); allMorphs().forEach((m) => { m._.visible = true; m.apply(); }); shownAll(); updateTreeState(); commit(); say('showing all layers and morphs'); }
};
function targetsFor(args) { return W.sel; }
function setSlot(slot, val) {
  const s = W.sel; if (!s) return say('nothing selected (click a morph, or use w / :select)', true);
  if (val === undefined || val === '') return say(`${slot} = ${s._[slot] ?? s[slot]}`);
  const map = { color: 'color', colour: 'color', fill: 'fill', stroke: 'stroke', width: 'strokeWidth', strokewidth: 'strokeWidth', sw: 'strokeWidth', opacity: 'opacity', alpha: 'opacity', op: 'opacity',
    x: 'x', y: 'y', rotation: 'rotation', rot: 'rotation', angle: 'rotation', label: 'label', name: 'label', dash: 'dash', visible: 'visible', scalex: 'scaleX', scaley: 'scaleY' };
  const k = map[slot.toLowerCase()];
  if (slot.toLowerCase() === 'scale') { if (!isMorph(s)) return say('scale applies to morphs', true); const f = parseFloat(val); if (!Number.isFinite(f)) return say('scale needs a number', true); s.set('scaleX', f); s.set('scaleY', f); commit(); return say(`scale = ${f}`); }
  if (!k) return say(`unknown slot "${slot}" (color fill stroke width opacity x y rotation scale label dash visible)`, true);
  if (!isMorph(s) && !(k in LAYER_SLOTS)) return say(`layers have no "${k}" slot`, true);
  if ((k === 'color' || k === 'fill' || k === 'stroke') && !validPaint(val)) return say(`bad color "${val}"`, true);
  if (MORPH_SLOTS[k] === 'num' && !Number.isFinite(parseFloat(val))) return say(`${k} needs a number`, true);
  if (k === 'dash' && val === 'none') val = '';
  if (k === 'color' && !isMorph(s)) s.set('color', val); else if (k === 'color') s.color = val; else s.set(k, val);
  commit(); say(`${s._.label}: ${slot} = ${val}`);
}
function runEx(line) {
  line = line.trim().replace(/^:+/, ''); if (!line) return;
  const sp = line.match(/^(\S+)\s*(.*)$/); let c = sp[1], rest = sp[2].trim(), bang = false;
  if (c.endsWith('!') && c.length > 1) { bang = true; c = c.slice(0, -1); }
  const args = rest.split(/\s+/).filter(Boolean);
  if (/^\d+$/.test(c)) return runEx('select ' + c);
  switch (c.toLowerCase()) {
    case 'set': case 'se': {
      if (!args.length) return say('usage: :set <slot> <value>   e.g. :set color #aa0000', true);
      const slot = args[0]; let val = rest.slice(slot.length).trim().replace(/^=\s*/, '');
      if (slot.includes('=')) { const [a, ...b] = slot.split('='); return setSlot(a, b.join('=') + (val ? ' ' + val : '')); }
      return setSlot(slot, val);
    }
    case 'color': case 'colour': return setSlot('color', rest);
    case 'width': case 'sw': return setSlot('width', rest);
    case 'opacity': return setSlot('opacity', rest);
    case 'label': case 'name': return setSlot('label', rest);
    case 'iso': case 'isolate': {
      if (!rest || /^(off|none|all|-)$/i.test(rest)) { setIso(null); return say('isolation off'); }
      const l = resolveLayer(rest); if (!l) return say(`no such system "${rest}"`, true);
      if (!l._.visible) l.set('visible', true);
      setIso(l.id); if (W.sel && layerOf(W.sel) !== l) select(l); return say(`isolated ${l._.label}`);
    }
    case 'show': {
      if (!rest || rest === 'all') return cmd.showAll();
      const l = resolveLayer(rest); if (!l) return say(`no such system "${rest}"`, true);
      l.set('visible', true); if (W.iso && W.iso !== l.id) W.iso = null; shownAll(); commit(); return say(`showing ${l._.label}`);
    }
    case 'hide': {
      if (!rest) return toggleHide();
      const l = resolveLayer(rest); if (!l) return say(`no such system "${rest}"`, true);
      l.set('visible', false); shownAll(); commit(); return say(`hid ${l._.label}`);
    }
    case 'explode': case 'ex': {
      const v = rest === '' ? (W.explode > 0 ? 0 : W.lastExplode) : rest === 'off' ? 0 : parseFloat(rest);
      if (!Number.isFinite(v)) return say('usage: :explode <0-100>', true);
      setExplode(v, true); return say(`explode ${clamp(Math.round(v), 0, 100)}`);
    }
    case 'save': case 'w': case 'write': return cmd.save();
    case 'load': case 'e': case 'edit': return cmd.load();
    case 'reset': return cmd.reset(bang);
    case 'export': return cmd.exportJson();
    case 'import': return $('#fileIn').click();
    case 'fit': fitView(); return say('fit to window');
    case 'undo': return undo();
    case 'redo': return redo();
    case 'dup': case 'duplicate': return dupSel();
    case 'del': case 'delete': return deleteSel();
    case 'inspect': case 'ins': return openInspector(W.sel);
    case 'help': case 'h': return toggleHelp(true);
    case 'select': case 'sel': case 'find': {
      if (!rest) return say('usage: :select <text>', true);
      const res = findByText(rest); if (!res.length) return say(`no morph matches "${rest}"`, true);
      select(res[0]); lastFind = { q: rest, i: 0 }; return say(`${res.length} match${res.length > 1 ? 'es' : ''}: ${res[0]._.label}` + (res.length > 1 ? ' (n = next)' : ''));
    }
    case 'layer': { const l = resolveLayer(rest); if (!l) return say(`no such system "${rest}"`, true); select(l); return say('layer ' + l._.label); }
    case 'move': case 'mv': { const [dx, dy = 0] = args.map(parseFloat); if (!Number.isFinite(dx)) return say('usage: :move dx dy', true); nudge(dx, +dy); commit(); return; }
    case 'rotate': case 'rot': { if (!isMorph(W.sel)) return say('select a morph first', true); const d = parseFloat(rest); if (!Number.isFinite(d)) return say('usage: :rotate deg', true); W.sel.set('rotation', W.sel._.rotation + d); commit(); return; }
    case 'scale': return setSlot('scale', rest);
    case 'eval': case 'js': { const out = runEval(rest, W.sel || W); commit(); return say('⇒ ' + out); }
    case 'q': case 'quit': return closeInspector(), toggleHelp(false), say('(there is no quitting a Morphic world)');
    default: if (typeof v2Ex === 'function' && v2Ex(c.toLowerCase(), rest, args, bang)) return; say(`E492: not an editor command: ${c}`, true);
  }
}

/* ============================================================= vim layer */
const modeEl = $('#mode'), cmdwrap = $('#cmdwrap'), cmdIn = $('#cmd'), cmdPre = $('#cmdpre'), pendEl = $('#pend');
let mode = 'normal', count = '', pending = '', lastFind = { q: '', i: 0 };
const hist = []; let histI = 0;
function setMode(m) {
  mode = m; modeEl.textContent = m === 'normal' ? 'NORMAL' : m === 'insert' ? 'INSERT' : m === 'command' ? 'COMMAND' : 'SEARCH';
  modeEl.className = m; cmdwrap.style.display = (m === 'command' || m === 'search') ? 'flex' : 'none'; msgEl.style.display = (m === 'command' || m === 'search') ? 'none' : '';
  count = ''; pending = ''; pendEl.textContent = '';
  if (m === 'command' || m === 'search') { cmdPre.textContent = m === 'command' ? ':' : '/'; cmdIn.value = ''; cmdIn.focus(); histI = hist.length; }
  else if (m === 'normal' && document.activeElement && document.activeElement !== document.body && !$('#filter').contains(document.activeElement)) document.activeElement.blur();
}
cmdIn.addEventListener('keydown', (e) => {
  e.stopPropagation();
  if (e.key === 'Escape') { e.preventDefault(); setMode('normal'); }
  else if (e.key === 'Enter') {
    e.preventDefault(); const v = cmdIn.value, was = mode; setMode('normal');
    if (was === 'search') { if (v) runEx('select ' + v); } else if (v.trim()) { hist.push(v); runEx(v); }
  } else if (e.key === 'ArrowUp') { e.preventDefault(); if (histI > 0) cmdIn.value = hist[--histI]; }
  else if (e.key === 'ArrowDown') { e.preventDefault(); histI = Math.min(hist.length, histI + 1); cmdIn.value = hist[histI] || ''; }
  else if (e.key === 'Backspace' && cmdIn.value === '') { e.preventDefault(); setMode('normal'); }
});
function focusIn(t) { return t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable) ; }
window.addEventListener('keydown', (e) => {
  $('#tip').style.display = 'none';
  const t = e.target;
  if (focusIn(t) && t !== document.body) {
    if (e.key === 'Escape') { e.preventDefault(); t.blur(); setMode('normal'); }
    else if (t.id !== 'cmd' && t.id !== 'filter' && !ins.contains(t)) return;
    else if (ins.contains(t) && mode !== 'insert') setMode('insert');
    return;
  }
  if (e.ctrlKey || e.metaKey) {
    if (e.key === 'r') { e.preventDefault(); redo(); } else if (e.key === 'z') { e.preventDefault(); undo(); }
    return;
  }
  if (e.altKey) return;
  const k = e.key;
  if (k === 'Escape') { setMode('normal'); toggleHelp(false); if (typeof v2Esc === 'function') v2Esc(); if (inspectorOpen) closeInspector(); return; }
  if (k === 'Shift' || k === 'Control' || k === 'Alt' || k === 'Meta') return;
  if (mode !== 'normal') return;
  e.preventDefault();
  if (/^[0-9]$/.test(k) && (count !== '' || k !== '0')) { count += k; pendEl.textContent = count + pending; return; }
  const n = Math.max(1, parseInt(count || '1', 10)); const hadCount = count !== ''; count = ''; pendEl.textContent = '';
  if (pending) {
    const p = pending; pending = '';
    if (p === 'd' && k === 'd') return deleteSel();
    if (p === 'y' && k === 'y') return dupSel();
    if (p === 'g' && k === 'g') { const l = visibleMorphList(); if (l.length) select(l[hadCount ? Math.min(n, l.length) - 1 : 0]); return; }
    return say(`unknown sequence ${p}${k}`, true);
  }
  const step = 4;
  switch (k) {
    case 'h': nudge(-step * n, 0); commit(); break;
    case 'l': nudge(step * n, 0); commit(); break;
    case 'j': nudge(0, step * n); commit(); break;
    case 'k': nudge(0, -step * n); commit(); break;
    case 'w': for (let i = 0; i < n; i++) cycleMorph(1); break;
    case 'b': for (let i = 0; i < n; i++) cycleMorph(-1); break;
    case 'H': for (let i = 0; i < n; i++) cycleLayer(-1); break;
    case 'L': for (let i = 0; i < n; i++) cycleLayer(1); break;
    case 'G': { const l = visibleMorphList(); if (l.length) select(l[hadCount ? Math.min(n, l.length) - 1 : l.length - 1]); break; }
    case 'x': toggleHide(); break;
    case 's': { const l = layerOf(W.sel); if (!l) say('nothing selected', true); else isolate(l.id); break; }
    case 'e': { const on = W.explode > 0; setExplode(on ? 0 : W.lastExplode || 60, true); say(on ? 'explode off' : 'explode on'); break; }
    case 'J': setExplode(W.explode - 5 * n, true); break;
    case 'K': setExplode(W.explode + 5 * n, true); break;
    case 'i': openInspector(W.sel, true); setMode('insert'); break;
    case 'I': openInspector(W.sel); break;
    case 'd': case 'y': case 'g': pending = k; pendEl.textContent = k; break;
    case 'u': undo(); break;
    case 'r': if (isMorph(W.sel)) { W.sel.set('rotation', W.sel._.rotation + 5 * n); commit(); } break;
    case 'R': if (isMorph(W.sel)) { W.sel.set('rotation', W.sel._.rotation - 5 * n); commit(); } break;
    case '=': case '+': if (isMorph(W.sel)) { W.sel.set('scaleX', r2(W.sel._.scaleX * 1.05 ** n)); W.sel.set('scaleY', r2(W.sel._.scaleY * 1.05 ** n)); commit(); } break;
    case '-': if (isMorph(W.sel)) { W.sel.set('scaleX', r2(W.sel._.scaleX / 1.05 ** n)); W.sel.set('scaleY', r2(W.sel._.scaleY / 1.05 ** n)); commit(); } break;
    case '[': if (W.sel) { W.sel.set('opacity', r2(W.sel._.opacity - 0.05 * n)); commit(); } break;
    case ']': if (W.sel) { W.sel.set('opacity', r2(W.sel._.opacity + 0.05 * n)); commit(); } break;
    case '0': if (isMorph(W.sel)) { const m = W.sel; Object.assign(m._, { x: 0, y: 0, rotation: 0, scaleX: 1, scaleY: 1 }); m.apply(); W.changed(m, 'x'); commit(); say('transform reset'); } else if (W.sel) { W.sel.set('x', 0); W.sel.set('y', 0); commit(); } break;
    case 'f': fitView(); break;
    case 'n': { if (!lastFind.q) return say('no previous search', true); const res = findByText(lastFind.q); if (!res.length) return; lastFind.i = (lastFind.i + 1) % res.length; select(res[lastFind.i]); say(`${lastFind.i + 1}/${res.length}: ${res[lastFind.i]._.label}`); break; }
    case ':': setMode('command'); break;
    case '/': setMode('search'); break;
    case '?': toggleHelp(); break;
    case 'Enter': openInspector(W.sel); break;
    default: if (typeof v2Key === 'function') v2Key(k, n, e); break;
  }
}, true);
document.addEventListener('keyup', () => {});

/* ====================================================================
 * v2 -- the anatomy layer on top of the Morphic world:
 *   scene graph (parents, frames, boundaries, connections), hierarchy
 *   drill-down, internals that appear when you select their organ,
 *   depth ordering + soft shading + skin veil, vessel legend,
 *   a schematic physiology timeline, and approximate cross-sections.
 * All of it reads WORLD0.scene / physiology / validation, which Ruby wrote.
 * ================================================================== */
const SC = WORLD0.scene || {}, PHYS0 = WORLD0.physiology || { params: {}, waves: {}, coupling: {} };
const VAL = WORLD0.validation || { checks: [], pass: 0, warn: 0, fail: 0 }, LEG = WORLD0.legend || [];
const MM_PER_PX = WORLD0.px_mm || 2.19, CM_PER_PX = MM_PER_PX / 10, PX_PER_CM = 1 / CM_PER_PX;
const REGS = {}; for (const r of WORLD0.regions || []) REGS[r.id] = r;
const KIDS = {};
for (const id of Object.keys(SC)) { const p = SC[id].parent; if (p) (KIDS[p] = KIDS[p] || []).push(id); }
for (const p in KIDS) if (KIDS[p].every((c) => SC[c].diam)) KIDS[p].sort((a, b) => SC[b].diam[0] - SC[a].diam[0]);
const KIND_COLOR = {}; for (const l of LEG) KIND_COLOR[l.kind] = l.color;
const SYS_ORDER = ['organs', 'arteries', 'veins', 'pulmonary', 'nerves', 'skeleton', 'muscles', 'skin'];
const V2 = { treeMode: 'systems', shade: true, focus: false, reveal: false, skin: 0, legend: true, kindFocus: null,
  aOpen: new Set(['rg_thorax', 'rg_abdomen']), lastKid: {}, ready: false };
let MBY = {};
const sid = (m) => { const i = typeof m === 'string' ? m : m.id; return SC[i] ? i : i.replace(/_copy\d+$/, ''); };
const labelOf = (id) => (REGS[id] ? REGS[id].label : MBY[id] ? MBY[id]._.label : (id || '').replace(/^[a-z]+_/, ''));
const mk = (tag, cls, txt) => { const e = document.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; };
const frac = (v) => v - Math.floor(v);
const parentOf = (id) => (SC[id] ? SC[id].parent : null);
function ownerOf(id) { let n = SC[id], g = 0; while (n && n.internal && n.parent && SC[n.parent] && g++ < 20) { id = n.parent; n = SC[id]; } return id; }
function ancestry(id) { const a = []; let g = 0; while (id && g++ < 40) { a.push(id); id = parentOf(id) || (REGS[id] && REGS[id].parent); } return a.reverse(); }
function descendants(id, out = new Set()) { for (const c of KIDS[id] || []) { out.add(c); descendants(c, out); } return out; }
const curId = () => (W.sel && isMorph(W.sel) ? sid(W.sel) : null);
function selectId(id, opts) { const m = MBY[id]; if (m) { select(m, opts || {}); return true; } if (REGS[id]) say(`${REGS[id].label} is a body region (not a drawn piece) - press > to go inside it`); return false; }

/* ------------------------------------------------ build / rebuild hook */
function v2Build() {
  MBY = {}; for (const m of allMorphs()) MBY[m.id] = m;
  const defs = $('#stage defs');
  if (!$('#shadeG')) {
    const g = svg('radialGradient', { id: 'shadeG', cx: '.36', cy: '.3', r: '.85' }, defs);
    svg('stop', { offset: '0', 'stop-color': '#fff', 'stop-opacity': '.34' }, g); svg('stop', { offset: '.42', 'stop-color': '#fff', 'stop-opacity': '0' }, g);
    svg('stop', { offset: '1', 'stop-color': '#1c0e24', 'stop-opacity': '.30' }, g);
    const cp = svg('clipPath', { id: 'slclip', clipPathUnits: 'userSpaceOnUse' }, defs); V2.clipRect = svg('rect', { x: -9999, y: -9999, width: 99999, height: 99999 }, cp);
    V2.probe = svg('path', { d: 'M0 0' }, defs);
  }
  // depth order: back-to-front by mean depth, so the liver sits in front of the right kidney
  const org = W.layerById.organs;
  if (org) { org.morphs.sort((a, b) => (SC[sid(b)] ? SC[sid(b)].z : 0.5) - (SC[sid(a)] ? SC[sid(a)].z : 0.5)); for (const m of org.morphs) org.items.appendChild(m.g); }
  if (W.layerById.skin) W.layerById.skin.items.id = 'skin-items';
  for (const m of allMorphs()) { m.concealed = false; m.shade = null; m.fxv = null; }
  // soft shading on the big solid organs
  if (org) for (const m of org.morphs) {
    const n = SC[sid(m)]; if (!n || n.internal || m._.fill === 'none' || !n.size_mm || Math.min(n.size_mm[0], n.size_mm[1]) < 38) continue;
    m.shade = svg('path', { class: 'shade', fill: 'url(#shadeG)', 'pointer-events': 'none', d: m.shape.d }); m.ag.insertBefore(m.shade, m.el.nextSibling);
  }
  buildFx(); buildOcclusion();
  // overlays that sit above every layer: skin veil, slice marks
  V2.veil = svg('g', { id: 'veilg', 'pointer-events': 'none' }, vp); V2.veilUse = svg('use', { href: '#skin-items' }, V2.veil);
  V2.slfx = svg('g', { id: 'slicefx', 'pointer-events': 'none' }, vp);
  V2.ready = true;
  for (const m of allMorphs()) m.apply();
  updateVeil(); applyConceal(); updateDim(); drawCrumbs(); sliceUpdate(true); if (PH.open) renderPhys();
}
// back vessels of the right kidney are hidden where the liver covers them
const OCC = [{ front: 'or_liver', back: ['ar_renal_r', 've_renal_r', 'ar_kid_r', 've_kid_r'] }];
function buildOcclusion() {
  for (const o of OCC) {
    const f = MBY[o.front]; if (!f) continue;
    let id = 'occ_' + o.front; const old = $('#' + id); if (old) old.remove();
    const cp = svg('clipPath', { id, clipPathUnits: 'userSpaceOnUse' }, $('#stage defs'));
    svg('path', { d: `M-9999 -9999H99999V99999H-9999Z${f.shape.d}`, 'clip-rule': 'evenodd' }, cp);
    for (const m of allMorphs()) if (o.back.some((p) => m.id.startsWith(p))) m.ag.setAttribute('clip-path', `url(#${id})`);
  }
}

/* patches: the shade follows its organ; fx follow their vessel; veil follows the skin layer */
const _mApply = Morph.prototype.apply;
Morph.prototype.apply = function () {
  _mApply.call(this);
  if (this.shade) { if (this.shade.getAttribute('d') !== this.shape.d) this.shade.setAttribute('d', this.shape.d); this.shade.setAttribute('opacity', this._.opacity); }
  if (this.fxv) { this.fxv.g.setAttribute('transform', this.g.getAttribute('transform')); this.fxv.g.classList.toggle('off', !this._.visible); }
};
const _lApply = Layer.prototype.apply;
Layer.prototype.apply = function () { _lApply.call(this); if (this.id === 'skin' && V2.ready) updateVeil(); };
function updateVeil() {
  const sk = W.layerById.skin; if (!sk || !V2.veil) return;
  const on = V2.skin > 0.01 && sk.shown && W.explode < 8;
  V2.veil.setAttribute('display', on ? 'inline' : 'none'); V2.veil.setAttribute('opacity', V2.skin * sk._.opacity);
  V2.veil.setAttribute('transform', sk.g.getAttribute('transform') || '');
  V2.slfx.setAttribute('display', W.explode < 8 ? 'inline' : 'none');
}
function setSkin(v) { V2.skin = clamp(+v, 0, 1); $('#skin').value = Math.round(V2.skin * 100); $('#skinVal').textContent = Math.round(V2.skin * 100) + '%'; updateVeil(); }
$('#skin').addEventListener('input', (e) => setSkin(e.target.value / 100));

/* ------------------------------------------- selection ownership & focus */
function applyConceal() {
  const sel = curId(), own = sel ? ownerOf(sel) : null;
  for (const m of allMorphs()) {
    const i = sid(m), n = SC[i];
    const c = !!(n && n.internal && !V2.reveal && ownerOf(i) !== own);
    if (c !== m.concealed) { m.concealed = c; m.g.classList.toggle('concealed', c); if (m.fxv) m.fxv.g.classList.toggle('concealed', c); }
  }
}
function updateDim() {
  const sel = curId(); let keep = null;
  if (V2.focus && sel) { keep = new Set(ancestry(sel)); keep.add(sel); descendants(sel, keep); }
  for (const m of allMorphs()) {
    const i = sid(m), n = SC[i];
    let dim = keep ? !keep.has(i) : false;
    if (V2.kindFocus && !(n && n.kind === V2.kindFocus)) dim = true;
    m.g.classList.toggle('fdim', dim); if (m.fxv) m.fxv.g.classList.toggle('fdim', dim);
  }
}
function v2Select() { applyConceal(); updateDim(); drawCrumbs(); sliceDimUpdate(); if (V2.treeMode === 'anatomy') anatomyReveal(); }

/* ---------------------------------------------- breadcrumbs & drilling */
function drawCrumbs() {
  const box = $('#crumbs'); box.textContent = '';
  const id = curId();
  if (!id) { box.append(mk('span', 'c cur', 'Body'), mk('span', 'hintc', '  select a structure · > goes inside it · < goes up')); return; }
  let path = ancestry(id);
  if (path.length > 6) path = ['…'].concat(path.slice(-5));
  path.forEach((p, i) => {
    if (i) box.append(mk('span', 'sep', '›'));
    if (p === '…') { box.append(mk('span', 'c', '…')); return; }
    const b = mk('span', 'c' + (i === path.length - 1 ? ' cur' : '') + (REGS[p] ? ' reg' : ''), labelOf(p));
    if (!REGS[p]) b.addEventListener('click', () => selectId(p)); box.append(b);
  });
  const k = (KIDS[id] || []).length, n = SC[id];
  const hier = n && n.hierarchy ? ` (${n.hierarchy})` : '';
  box.append(mk('span', 'hintc', k ? `${hier}  ·  ${k} part${k > 1 ? 's' : ''} inside · press >` : `${hier}  ·  smallest piece · < goes up`));
}
function drillDown(c = 1) {
  let id = curId(); let moved = false;
  for (let i = 0; i < c; i++) {
    let kids = id ? KIDS[id] : null;
    if (!id) { const r = (WORLD0.regions || []).find((x) => (KIDS[x.id] || []).length && x.id !== 'rg_body'); kids = r ? KIDS[r.id] : []; }
    if (!kids || !kids.length) { if (!moved) say(`${labelOf(id)} is the smallest piece drawn - press < to go back up`); break; }
    const pick = (id && V2.lastKid[id] && kids.includes(V2.lastKid[id])) ? V2.lastKid[id] : kids[0]; id = pick; moved = true;
  }
  if (moved) { selectId(id); say(`${ancestry(id).map(labelOf).join(' › ')}`); }
}
function drillUp(c = 1) {
  let id = curId(); if (!id) return say('nothing selected');
  for (let i = 0; i < c; i++) {
    const p = parentOf(id);
    if (!p || REGS[p]) { say(`${labelOf(id)} is top-level in the ${REGS[p] ? REGS[p].label.toLowerCase() : 'body'} - nothing above it to select`); break; }
    V2.lastKid[p] = id; id = p;
  }
  selectId(id); say(ancestry(id).map(labelOf).join(' › '));
}
function nextSibling(dir = 1, c = 1) {
  const id = curId(); if (!id) return; const sib = KIDS[parentOf(id)] || [id]; let i = sib.indexOf(id);
  i = ((i + dir * c) % sib.length + sib.length) % sib.length; V2.lastKid[parentOf(id)] = sib[i]; selectId(sib[i]); say(`${i + 1}/${sib.length} in ${labelOf(parentOf(id))}`);
}

/* --------------------------------------------------------- inspector */
function chip(id, text, title) {
  const b = mk('button', 'chip', text || labelOf(id)); b.type = 'button'; if (title) b.title = title;
  if (MBY[id]) b.addEventListener('click', () => select(MBY[id], { scroll: false }));
  else b.disabled = true;
  return b;
}
const FLOW_TXT = { artery: 'away from the heart', pulm_a: 'from the heart to the lungs', vein: 'towards the heart', pulm_v: 'from the lungs to the heart', portal: 'from the gut to the liver', hepatic_a: 'into the liver', bile: 'out of the liver', nerve: 'away from the brain / cord' };
function v2Inspector(target) {
  const id = sid(target), n = SC[id]; if (!n) return;
  const h = mk('h3', '', 'anatomy · scene graph'); insBody.appendChild(h);
  const row = (l, ctl) => mkRow(l, [].concat(ctl), 'sg');
  const par = parentOf(id);
  row('parent', REGS[par] ? mk('span', 'sgt', `${REGS[par].label} (region)`) : chip(par));
  row('path', mk('span', 'sgt', ancestry(id).map(labelOf).join(' › ')));
  const ks = KIDS[id] || [];
  row('children', ks.length ? [...ks.slice(0, 8).map((c) => chip(c)), ...(ks.length > 8 ? [mk('span', 'sgt', `+${ks.length - 8} more`)] : [])] : mk('span', 'sgt', 'none (smallest piece)'));
  const f = n.frame || {};
  row('frame', mk('span', 'sgt', f.origin ? `origin (${f.origin[0]}, ${f.origin[1]}) px · depth ${f.origin[2]}   [x right, y down, z 0 = front → 1 = back]` : '-'));
  if (f.offset) row('offset', mk('span', 'sgt', `from parent: ${r2(f.offset[0] * MM_PER_PX)} mm across, ${r2(f.offset[1] * MM_PER_PX)} mm down, ${r2(f.offset[2])} depth`));
  const b = n.boundary || {};
  row('boundary', mk('span', 'sgt', `${b.type || '-'} · ${b.pts ? b.pts.length : 0} points · ${n.size_mm ? n.size_mm[0] + ' × ' + n.size_mm[1] + ' mm' : ''}`));
  if (n.depth) row('depth', mk('span', 'sgt', n.depth.map((d) => `${d[0]} → ${d[1]}`).join(', ') + `  (z-order ${n.z})`));
  row('tissue', mk('span', 'sgt', `${n.system} · ${n.kind}${n.hierarchy ? ' · ' + n.hierarchy : ''}${n.internal ? ' · inside ' + labelOf(ownerOf(id)) : ''}`));
  if (n.diam) row('vessel', mk('span', 'sgt', `${n.diam[0]} → ${n.diam[1]} mm wide${n.level != null ? ' · branch level ' + n.level : ''}${n.len ? ' · ' + n.len + ' mm long' : ''}${n.flow && FLOW_TXT[n.kind] ? ' · flow ' + FLOW_TXT[n.kind] : ''}${n.dist ? ' · ' + r2(n.dist * MM_PER_PX / 10) + ' cm from ' + (n.kind === 'nerve' ? 'the brain/cord' : 'the heart') : ''}`));
  const cs = (n.connections || []);
  if (cs.length) row('connections', [...cs.slice(0, 14).map((c) => chip(c.to, `${c.kind}: ${labelOf(c.to)}`, c.dir)), ...(cs.length > 14 ? [mk('span', 'sgt', `+${cs.length - 14} more`)] : [])]);
}

/* ------------------------------------------------- anatomy tree tab */
function aRows(id, depth, out, q) {
  const ks = KIDS[id] || [];
  for (const c of ks) { out.push({ id: c, depth }); if (V2.aOpen.has(c) && (KIDS[c] || []).length) aRows(c, depth + 1, out); }
}
function v2RenderAnatomy() {
  const box = $('#treeWrap'); box.textContent = ''; const q = $('#filter').value.toLowerCase();
  const mkRowEl = (id, depth, flat) => {
    const n = SC[id], k = (KIDS[id] || []).length;
    const r = mk('div', 'ai'); r.dataset.id = id; r.style.paddingLeft = (8 + depth * 12) + 'px';
    const ar = mk('span', 'ar', k && !flat ? (V2.aOpen.has(id) ? '▾' : '▸') : ' ');
    ar.addEventListener('click', (e) => { e.stopPropagation(); if (!k) return; V2.aOpen.has(id) ? V2.aOpen.delete(id) : V2.aOpen.add(id); v2RenderAnatomy(); });
    const lb = mk('span', 'lb', labelOf(id)); r.append(ar, lb);
    if (k) r.append(mk('span', 'kc', k));
    if (flat && n) r.append(mk('span', 'kc', labelOf(n.parent)));
    r.addEventListener('click', () => { if (REGS[id]) { if (k) { V2.aOpen.has(id) ? V2.aOpen.delete(id) : V2.aOpen.add(id); v2RenderAnatomy(); } } else select(MBY[id], { scroll: false }); });
    if (MBY[id] && W.sel === MBY[id]) r.classList.add('sel'); if (MBY[id] && !MBY[id]._.visible) r.classList.add('off');
    box.appendChild(r);
  };
  if (q) {
    const hits = Object.keys(SC).filter((i) => MBY[i] && (labelOf(i).toLowerCase().includes(q) || i.includes(q))).slice(0, 80);
    hits.forEach((i) => mkRowEl(i, 0, true)); if (!hits.length) box.appendChild(mk('div', 'ai', 'no match'));
    return;
  }
  for (const r of WORLD0.regions || []) {
    if (r.id === 'rg_body' || !(KIDS[r.id] || []).length) continue;
    mkRowEl(r.id, 0, false);
    if (V2.aOpen.has(r.id)) { const rows = []; aRows(r.id, 1, rows); rows.slice(0, 400).forEach((x) => mkRowEl(x.id, x.depth, false)); }
  }
  const s = $('#treeWrap .ai.sel'); if (s) s.scrollIntoView({ block: 'nearest' });
}
function anatomyReveal() {
  const id = curId(); if (!id) return v2RenderAnatomy();
  ancestry(id).slice(0, -1).forEach((a) => { if (!REGS[a] || a !== 'rg_body') V2.aOpen.add(a); }); v2RenderAnatomy();
}
function setTreeMode(m) {
  V2.treeMode = m; $('#tabSys').classList.toggle('on', m === 'systems'); $('#tabAna').classList.toggle('on', m === 'anatomy');
  renderTree(); if (m === 'anatomy') anatomyReveal();
}
$('#tabSys').addEventListener('click', () => setTreeMode('systems')); $('#tabAna').addEventListener('click', () => setTreeMode('anatomy'));

/* ----------------------------------------------------- legend panel */
function buildLegend() {
  const box = $('#legend'); box.textContent = '';
  const h = mk('div', 'lh'); h.append(mk('b', '', 'Legend')); const x = mk('span', 'x', '×'); x.title = 'hide'; x.addEventListener('click', () => setLegend(false)); h.append(x); box.append(h);
  for (const l of LEG) {
    const r = mk('div', 'lr'); r.dataset.kind = l.kind;
    const sw = mk('i'); sw.style.background = l.color; r.append(sw, mk('span', '', l.label)); r.title = 'click: highlight only this kind';
    r.addEventListener('click', () => { V2.kindFocus = V2.kindFocus === l.kind ? null : l.kind; box.querySelectorAll('.lr').forEach((e) => e.classList.toggle('on', e.dataset.kind === V2.kindFocus)); updateDim(); });
    box.append(r);
  }
  const f = mk('div', 'lr plain'); f.innerHTML = '<i class="arrow">▶</i><span>Small arrows show which way blood (or a nerve signal) flows</span>'; box.append(f);
}
function setLegend(on) { V2.legend = on; $('#legend').style.display = on ? 'block' : 'none'; $('#cLegend').checked = on; }
$('#cLegend').addEventListener('change', (e) => setLegend(e.target.checked));
$('#cShade').addEventListener('change', (e) => { V2.shade = e.target.checked; stage.classList.toggle('noshade', !V2.shade); });
$('#cFocus').addEventListener('change', (e) => { V2.focus = e.target.checked; updateDim(); });

/* =============================================== physiology (schematic) */
const P = PHYS0.params || {}, WV = PHYS0.waves || {}, CPL = PHYS0.coupling || {};
const pv = (k, d) => (P[k] ? P[k].value : d);
const PH = { open: false, playing: false, t: 0, speed: 1, hr: pv('heart_rate', 72), rr: pv('respiratory_rate', 15),
  on: { heart: true, breath: true, nerve: true, portal: true, flow: true }, raf: 0, last: 0, lastR: 0, entries: [], targets: [] };
const interp = (arr, ph) => { if (!arr || !arr.length) return 0; const n = arr.length, x = frac(ph) * n, i = Math.floor(x) % n, f = x - Math.floor(x); return arr[i] * (1 - f) + arr[(i + 1) % n] * f; };
// pulsatile flow: velocity profile from the arterial pulse, normalised so the average speed is 1
const VPROF = (WV.arterial_pulse || [1]).map((a) => 0.25 + a);
const VMEAN = VPROF.reduce((a, b) => a + b, 0) / VPROF.length; const VCUM = [0];
for (let i = 0; i < VPROF.length; i++) VCUM.push(VCUM[i] + VPROF[i] / VMEAN / VPROF.length);
const cumFlow = (b) => { const w = Math.floor(b), x = frac(b) * VPROF.length, i = Math.min(Math.floor(x), VPROF.length - 1); return w + VCUM[i] + (VCUM[i + 1] - VCUM[i]) * (x - i); };
const PULSATILE = new Set(['artery', 'pulm_a', 'hepatic_a']);
const SPEED_PX = { artery: 62, pulm_a: 52, hepatic_a: 34, vein: 40, pulm_v: 38, portal: 36, bile: 12 };
const NERVE_CYCLE = 3.8, PACKET = 15;
const hashOf = (s) => { let h = 7; for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0; return h; };

function polyline(d, orient) {
  V2.probe.setAttribute('d', d); const L = V2.probe.getTotalLength(); if (!(L > 0.5)) return null;
  const nS = clamp(Math.ceil(L / 3.5), 4, 90), pts = [], cum = [];
  for (let i = 0; i <= nS; i++) { const p = V2.probe.getPointAtLength(L * i / nS); pts.push([p.x, p.y]); }
  if (orient < 0) pts.reverse();
  let c = 0; cum.push(0); for (let i = 1; i < pts.length; i++) { c += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]); cum.push(c); }
  return { pts, cum, L: c };
}
function posAt(en, s) {
  const { pts, cum } = en; let lo = 0, hi = cum.length - 1;
  while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (cum[mid] <= s) lo = mid; else hi = mid; }
  const a = pts[lo], b = pts[hi], seg = cum[hi] - cum[lo] || 1, f = clamp((s - cum[lo]) / seg, 0, 1);
  return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, Math.atan2(b[1] - a[1], b[0] - a[0]) * 180 / Math.PI];
}
function buildFx() {
  PH.entries = []; PH.targets = [];
  for (const l of W.layers) l.fx.textContent = '';
  for (const m of allMorphs()) {
    const n = SC[sid(m)]; if (!n || !n.cl || !n.flow || n.internal === undefined) continue;
    if (!(PULSATILE.has(n.kind) || SPEED_PX[n.kind] || n.kind === 'nerve')) continue;
    const pl = polyline(n.cl, n.flow); if (!pl || pl.L < 3) continue;
    const g = svg('g', { class: 'fxv ' + n.kind }, m.layer.fx), a = svg('g', { class: 'fxa' }, g);
    m.fxv = { g, a };
    const col = n.kind === 'nerve' ? '#e0b020' : (KIND_COLOR[n.kind] || '#444'), sw = Math.max(1, m._.strokeWidth);
    const en = { m, n, kind: n.kind, col, sw, pts: pl.pts, cum: pl.cum, L: pl.L, off: hashOf(m.id) % Math.ceil(pl.L), arrows: [], delay: ((n.dist || 0) / (PX_PER_CM * 100)) / pv('pulse_wave_speed', 7), pulsatile: PULSATILE.has(n.kind) };
    const d = 'M' + pl.pts.map((p) => p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join('L');
    if (n.kind === 'nerve') {
      en.sig = svg('path', { class: 'nsig', d, fill: 'none', stroke: '#fff6bd', 'stroke-width': sw + 2.4, 'stroke-linecap': 'round', opacity: 0 }, a);
      en.sig.setAttribute('stroke-dasharray', `${PACKET} ${pl.L + PACKET + 60}`); en.phr = m.id.startsWith('ne_phrenic');
    } else {
      if (en.pulsatile) en.glow = svg('path', { class: 'pglow', d, fill: 'none', stroke: '#fff', 'stroke-width': sw + 0.8, 'stroke-linecap': 'round', opacity: 0 }, a);
      const K = Math.max(1, Math.round(pl.L / 26)), sc = clamp(0.55 + sw * 0.3, 0.7, 1.7);
      for (let k = 0; k < K; k++) en.arrows.push(svg('path', { class: 'arr', d: 'M-2.4 -2.1L2.2 0L-2.4 2.1Z', fill: '#fff', stroke: col, 'stroke-width': 0.7, 'stroke-linejoin': 'round', 'data-sc': sc }, a));
      en.K = K; en.sc = sc;
    }
    PH.entries.push(en);
  }
  // body-motion targets
  const add = (id, part) => { const m = MBY[id]; if (!m) return; (m.__parts = m.__parts || []).push(part); if (!PH.targets.includes(m)) PH.targets.push(m); };
  for (const m of allMorphs()) m.__parts = null;
  if (CPL.heart) for (const id of CPL.heart.ids) add(id, { k: 'heart', c: CPL.heart });
  for (const g of CPL.breath_lung || []) for (const id of g.ids) add(id, { k: 'lung', c: g });
  if (CPL.breath_ribs) for (const id of CPL.breath_ribs.ids) add(id, { k: 'lung', c: CPL.breath_ribs });
  for (const s of CPL.breath_shift || []) add(s.id, { k: 'shift', f: s.f });
}
function scaleAround(c, v) { return `translate(${c.pivot[0]} ${c.pivot[1]}) scale(${(1 + c.sx * v).toFixed(4)} ${(1 + c.sy * v).toFixed(4)}) translate(${-c.pivot[0]} ${-c.pivot[1]})`; }

function phaseInfo() {
  const Tb = 60 / PH.hr, Tr = 60 / PH.rr, b = PH.t / Tb, r = PH.t / Tr, sf = pv('systole_fraction', 0.37), isf = pv('inspiration_share', 0.4);
  return { Tb, Tr, b, r, hp: frac(b), rp: frac(r), sys: frac(b) < sf, insp: frac(r) < isf, sf, isf, beats: Math.floor(b) };
}
function renderPhys() {
  const q = phaseInfo(), sq = PH.on.heart ? interp(WV.ventricle_squeeze, q.hp) : 0, vol = PH.on.breath ? interp(WV.lung_volume, q.rp) : 0;
  const travel = pv('diaphragm_travel', 1.5) * PX_PER_CM;
  for (const m of PH.targets) {
    let s = '';
    for (const p of m.__parts) {
      if (p.k === 'heart') s += scaleAround(p.c, sq); else if (p.k === 'lung') s += scaleAround(p.c, vol);
      else if (p.k === 'shift') s += `translate(0 ${(p.f * travel * vol * 1.3).toFixed(2)})`;
    }
    if (s !== m.__tf) { m.__tf = s; m.ag.setAttribute('transform', s); if (m.fxv) m.fxv.a.setAttribute('transform', s); }
  }
  const pvPortal = SPEED_PX.portal * pv('portal_flow', 1100) / 1100;
  for (const en of PH.entries) {
    const m = en.m; if (m.concealed || !m._.visible || !m.layer.shown) continue;
    if (en.kind === 'nerve') {
      if (!PH.on.nerve) { en.sig.setAttribute('opacity', 0); continue; }
      const v = pv('nerve_display_speed', 330); let tau = frac(PH.t / NERVE_CYCLE) * NERVE_CYCLE;
      if (en.phr) { const travel2 = ((en.n.dist || 0) + en.L) / v, Tr = q.Tr; tau = frac((PH.t + travel2) / Tr) * Tr; }
      const s = tau * v - (en.n.dist || 0), vis = s >= 0 && s <= en.L + PACKET;
      en.sig.setAttribute('opacity', vis ? 1 : 0); if (vis) en.sig.setAttribute('stroke-dashoffset', (PACKET - s).toFixed(1));
      continue;
    }
    const doFlow = PH.on.flow && (en.kind !== 'portal' || PH.on.portal) && (en.kind !== 'hepatic_a' || PH.on.portal);
    const speed = en.kind === 'portal' ? pvPortal : SPEED_PX[en.kind];
    let D;
    if (en.pulsatile && PH.on.heart) D = speed * q.Tb * cumFlow(q.b); else D = speed * PH.t;
    for (let k = 0; k < en.arrows.length; k++) {
      const a = en.arrows[k];
      if (!doFlow) { a.setAttribute('opacity', 0); continue; }
      const s = (D + en.off + k * en.L / en.K) % en.L, p = posAt(en, s);
      a.setAttribute('transform', `translate(${p[0].toFixed(1)} ${p[1].toFixed(1)}) rotate(${p[2].toFixed(0)}) scale(${en.sc})`);
      a.setAttribute('opacity', 0.95);
    }
    if (en.glow) {
      const a = PH.on.heart ? interp(WV.arterial_pulse, q.b - en.delay / q.Tb) : 0, g = clamp((a - 0.3) / 0.7, 0, 1);
      en.glow.setAttribute('opacity', (g * 0.8).toFixed(2));
    }
  }
  updatePanel(q);
}
function physFrame(ts) {
  if (!PH.playing) return;
  PH.raf = requestAnimationFrame(physFrame);
  if (!PH.last) PH.last = ts; const dt = (ts - PH.last) / 1000; if (ts - PH.lastR < 30) return;
  PH.last = ts; PH.lastR = ts; PH.t += Math.min(dt, 0.15) * PH.speed; renderPhys();
}
function physOpen(on) {
  PH.open = on; stage.classList.toggle('phys-on', on); $('#tl').style.display = on ? 'block' : 'none'; $('#bTl').classList.toggle('on', on); dockLayout();
  if (on) renderPhys(); else { physPlay(false); for (const m of PH.targets) { m.__tf = null; m.ag.removeAttribute('transform'); if (m.fxv) m.fxv.a.removeAttribute('transform'); } }
}
function physPlay(on) {
  if (on === undefined) on = !PH.playing; if (on && !PH.open) physOpen(true);
  PH.playing = on; cancelAnimationFrame(PH.raf); PH.last = 0; $('#tlPlay').textContent = on ? '❚❚' : '▶'; $('#tlPlay').title = on ? 'Pause (space)' : 'Play (space)';
  if (on) PH.raf = requestAnimationFrame(physFrame); else if (PH.open) renderPhys();
}
function physStep(dir, c = 1) { if (!PH.open) physOpen(true); physPlay(false); const dt = 60 / PH.hr / 20; PH.t = Math.max(0, PH.t + dir * dt * c); renderPhys(); }
function physSetTime(t) { PH.t = Math.max(0, +t || 0); if (PH.open) renderPhys(); }
function physSetPhase(ph) { const Tb = 60 / PH.hr; PH.t = (Math.floor(PH.t / Tb) + clamp(ph, 0, 0.999)) * Tb; if (PH.open) renderPhys(); }
function physReplay() { PH.t = 0; physPlay(true); }
function setHr(v) { PH.hr = clamp(Math.round(+v), 60, 100); $('#tlHr').value = PH.hr; $('#tlHrV').textContent = PH.hr + ' bpm'; if (PH.open) renderPhys(); }
function setRr(v) { PH.rr = clamp(Math.round(+v), 12, 20); $('#tlRr').value = PH.rr; $('#tlRrV').textContent = PH.rr + ' /min'; if (PH.open) renderPhys(); }

/* timeline panel: wave traces + phase labels */
const tlc = $('#tlc'), tlx = tlc.getContext('2d');
function trace(y0, h, arr, ph, col, label, fill) {
  const w = tlc.width - 74, x0 = 70; tlx.save();
  tlx.fillStyle = '#5b6678'; tlx.font = '10.5px system-ui,sans-serif'; tlx.fillText(label, 4, y0 + h / 2 + 3);
  tlx.strokeStyle = '#e1e6ee'; tlx.strokeRect(x0, y0, w, h);
  if (fill) { tlx.fillStyle = fill.col; tlx.fillRect(x0, y0, w * fill.w, h); }
  tlx.beginPath(); const n = arr.length; for (let i = 0; i <= n; i++) { const v = arr[i % n]; const x = x0 + w * i / n, y = y0 + h - 3 - (h - 6) * v; i ? tlx.lineTo(x, y) : tlx.moveTo(x, y); }
  tlx.strokeStyle = col; tlx.lineWidth = 1.8; tlx.stroke();
  const px = x0 + w * ph; tlx.strokeStyle = '#1b212c'; tlx.lineWidth = 1.4; tlx.beginPath(); tlx.moveTo(px, y0 - 2); tlx.lineTo(px, y0 + h + 2); tlx.stroke(); tlx.restore();
}
function updatePanel(q) {
  tlx.clearRect(0, 0, tlc.width, tlc.height);
  trace(4, 30, WV.arterial_pulse || [0], q.hp, '#d1222f', 'heart · pulse', { col: 'rgba(209,34,47,.10)', w: q.sf });
  trace(38, 30, WV.lung_volume || [0], q.rp, '#1d6fb8', 'breathing', { col: 'rgba(29,111,184,.10)', w: q.isf });
  trace(72, 30, WV.action_potential || [0], frac(PH.t / NERVE_CYCLE), '#c99a10', 'nerve signal');
  $('#tlT').textContent = `t = ${PH.t.toFixed(2)} s`; $('#tlScrub').value = Math.round(q.hp * 1000);
  $('#tlPh').innerHTML = `<div><b>Heart</b> ${PH.hr} bpm: <span class="ph">${q.sys ? 'systole - the ventricles squeeze' : 'diastole - the ventricles fill'}</span> (beat phase ${q.hp.toFixed(2)})</div>` +
    `<div><b>Breathing</b> ${PH.rr}/min: <span class="ph">${q.insp ? 'inspiration - diaphragm moves down, lungs widen' : 'expiration - diaphragm rises, lungs recoil'}</span></div>` +
    `<div><b>Nerve</b> signal ${Math.round(pv('nerve_display_speed', 330))} px/s on screen (real: ~${pv('nerve_speed', 60)} m/s)</div>`;
}
function buildPanel() {
  const t = $('#tlParams'); t.textContent = '';
  for (const k of Object.keys(P)) { const p = P[k]; const r = mk('div'); r.textContent = `${p.label}: ${p.value} ${p.unit}${p.range ? ' (typical ' + p.range[0] + '-' + p.range[1] + ')' : ''}`; t.append(r); }
  const s = mk('div', 'src', PHYS0.source || ''); t.append(s);
  $('#tlDisc').textContent = (PHYS0.disclaimer || 'Schematic animation.') + ' Movements are exaggerated for visibility and nerve signals are drawn about 100 times slower than real ones.';
}
$('#tlPlay').onclick = () => physPlay(); $('#tlRe').onclick = () => physReplay(); $('#tlBk').onclick = () => physStep(-1); $('#tlFw').onclick = () => physStep(1);
$('#tlClose').onclick = () => physOpen(false); $('#bTl').onclick = () => physOpen(!PH.open);
$('#tlSpd').onchange = (e) => { PH.speed = +e.target.value; };
$('#tlHr').oninput = (e) => setHr(e.target.value); $('#tlRr').oninput = (e) => setRr(e.target.value);
$('#tlScrub').oninput = (e) => { physPlay(false); physSetPhase(e.target.value / 1000); };
for (const k of ['heart', 'breath', 'nerve', 'flow', 'portal']) $('#tc_' + k).onchange = (e) => { PH.on[k] = e.target.checked; if (PH.open) renderPhys(); };

/* ================================================= cross-sections */
const SL = { mode: 'off', pos: { axial: 250, sagittal: 200, coronal: 0.4 }, clip: false, keep: 1, dim: true, hits: [], list: [] };
const LANDMARKS = [[0, 'head'], [125, 'neck'], [152, 'upper chest (thorax)'], [210, 'mid chest (thorax)'], [250, 'upper abdomen'], [300, 'lower abdomen'], [340, 'pelvis'], [410, 'thighs'], [600, 'lower legs'], [790, 'feet']];
const landmark = (y) => { let r = LANDMARKS[0][1]; for (const l of LANDMARKS) if (y >= l[0]) r = l[1]; return r; };
function polysOf(m) {
  if (m.__pd === m.shape.d) return m.__polys;
  const toks = (m.shape.d || '').match(/[MLCQHVAZ]|-?\d*\.?\d+(?:e-?\d+)?/gi) || []; const subs = []; let cur = null, x = 0, y = 0, sx = 0, sy = 0, i = 0, cmd = '';
  const num = () => parseFloat(toks[i++]); const push = (px, py) => { cur.pts.push([px, py]); x = px; y = py; };
  const bez = (c) => { const [x0, y0] = [x, y]; for (let t = 0.25; t <= 1.001; t += 0.25) { const u = 1 - t; let px, py; if (c.length === 6) { px = u * u * u * x0 + 3 * u * u * t * c[0] + 3 * u * t * t * c[2] + t * t * t * c[4]; py = u * u * u * y0 + 3 * u * u * t * c[1] + 3 * u * t * t * c[3] + t * t * t * c[5]; } else { px = u * u * x0 + 2 * u * t * c[0] + t * t * c[2]; py = u * u * y0 + 2 * u * t * c[1] + t * t * c[3]; } cur.pts.push([px, py]); } x = c[c.length - 2]; y = c[c.length - 1]; };
  while (i < toks.length) {
    if (/[A-Za-z]/.test(toks[i])) cmd = toks[i++];
    if (cmd === 'M') { x = num(); y = num(); cur = { pts: [[x, y]], closed: false }; subs.push(cur); sx = x; sy = y; cmd = 'L'; }
    else if (cmd === 'L') push(num(), num());
    else if (cmd === 'H') push(num(), y); else if (cmd === 'V') push(x, num());
    else if (cmd === 'C') bez([num(), num(), num(), num(), num(), num()]); else if (cmd === 'Q') bez([num(), num(), num(), num()]);
    else if (cmd === 'A') arcPts(cur, x, y, num(), num(), num(), num(), num(), num(), num()), (x = cur.pts[cur.pts.length - 1][0], y = cur.pts[cur.pts.length - 1][1]);
    else if (cmd === 'Z') { if (cur) { cur.closed = true; x = sx; y = sy; } cmd = ''; }
    else i++;
  }
  m.__pd = m.shape.d; m.__polys = subs; return subs;
}
function arcPts(cur, x1, y1, rx, ry, phi, fa, fs, x2, y2) {
  if (!rx || !ry) { cur.pts.push([x2, y2]); return; }
  const ph = phi * Math.PI / 180, c = Math.cos(ph), s = Math.sin(ph), dx = (x1 - x2) / 2, dy = (y1 - y2) / 2, x1p = c * dx + s * dy, y1p = -s * dx + c * dy;
  rx = Math.abs(rx); ry = Math.abs(ry); const lam = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry); if (lam > 1) { rx *= Math.sqrt(lam); ry *= Math.sqrt(lam); }
  const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p, den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
  const co = (fa === fs ? -1 : 1) * Math.sqrt(Math.max(0, num / den)), cxp = co * rx * y1p / ry, cyp = -co * ry * x1p / rx;
  const cx = c * cxp - s * cyp + (x1 + x2) / 2, cy = s * cxp + c * cyp + (y1 + y2) / 2;
  const ang = (ux, uy, vx, vy) => { const a = Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy); return a; };
  const th1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry); let dth = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
  if (!fs && dth > 0) dth -= 2 * Math.PI; else if (fs && dth < 0) dth += 2 * Math.PI;
  for (let k = 1; k <= 10; k++) { const t = th1 + dth * k / 10, ex = rx * Math.cos(t), ey = ry * Math.sin(t); cur.pts.push([c * ex - s * ey + cx, s * ex + c * ey + cy]); }
}
// intersect one morph with the plane; returns {spans:[[a,b]]} (area) or {pts:[u...]} (tube crossing), in drawing px
function planeCut(m, mode, pos) {
  const n = SC[sid(m)]; if (!n) return null;
  if (mode === 'coronal') { return (n.depth || []).some((d) => pos >= d[0] && pos <= d[1]) ? { depth: true } : null; }
  const axial = mode === 'axial', offV = axial ? m._.y : m._.x, offU = axial ? m._.x : m._.y, v0 = pos - offV;
  const polys = polysOf(m), area = m._.fill !== 'none', spans = [], cross = [];
  const xs = [];
  for (const s of polys) {
    const P2 = s.pts, ncount = P2.length; if (ncount < 2) continue;
    const isArea = (area || s.closed) && ncount > 2;
    const lim = isArea ? ncount : ncount - 1;
    for (let i = 0; i < lim; i++) {
      const a = P2[i], b = P2[(i + 1) % ncount], av = axial ? a[1] : a[0], bv = axial ? b[1] : b[0], au = axial ? a[0] : a[1], bu = axial ? b[0] : b[1];
      if ((av <= v0) !== (bv <= v0)) { const u = au + (bu - au) * (v0 - av) / (bv - av); (isArea ? xs : cross).push(u + offU); }
    }
  }
  xs.sort((p, q) => p - q); for (let i = 0; i + 1 < xs.length; i += 2) spans.push([xs[i], xs[i + 1]]);
  if (spans.length) return { spans }; if (cross.length) return { cross };
  return null;
}
const TREE_LABEL = {};
function sliceCompute() {
  const mode = SL.mode, pos = SL.pos[mode]; const groups = new Map(); SL.hits = [];
  for (const m of allMorphs()) {
    if (!m._.visible || !m.layer.shown) continue;
    const i = sid(m), n = SC[i]; if (!n) continue;
    if (m.layer.id === 'skin' && i !== 'skin_body') continue;
    if (m.layer.id === 'skeleton' && /^sk_(orbit|nasal)/.test(i)) continue;
    const cut = planeCut(m, mode, pos); if (!cut) continue;
    SL.hits.push({ m, cut });
    let key = i, label = m._.label, rep = i;
    if (n.internal) { key = 'in:' + ownerOf(i); label = labelOf(ownerOf(i)) + ' - inside'; rep = ownerOf(i); }
    else if (n.tree && n.level > 0) { key = 'tree:' + n.tree; label = `${labelOf(n.tree + '_0')} (branches)`; rep = i; }
    let g = groups.get(key); if (!g) { g = { key, label, rep, system: m.layer.id, color: m._.fill !== 'none' ? m._.fill : m._.stroke, n: 0, w: 0, parts: [], kind: n.internal ? 'inside' : n.tree && n.level > 0 ? 'tree' : 'one' }; groups.set(key, g); }
    g.n++; if (cut.spans) g.w += cut.spans.reduce((a, s) => a + (s[1] - s[0]), 0); if (n.internal && (n.hierarchy === 'segment' || n.hierarchy === 'lobe')) g.parts.push(m._.label.replace(/^Liver\s*/i, ''));
    if (n.internal && g.system === 'organs') g.system = 'organs';
  }
  SL.list = [...groups.values()].sort((a, b) => SYS_ORDER.indexOf(a.system) - SYS_ORDER.indexOf(b.system) || b.w - a.w);
}
function sliceDraw() {
  const g = V2.slfx; g.textContent = ''; if (SL.mode === 'off') return;
  const mode = SL.mode, pos = SL.pos[mode];
  if (mode === 'axial') { svg('rect', { x: -10, y: pos - 1.2, width: 420, height: 2.4, fill: '#0a84ff', opacity: 0.55 }, g); }
  else if (mode === 'sagittal') { svg('rect', { x: pos - 1.2, y: 6, width: 2.4, height: 836, fill: '#0a84ff', opacity: 0.55 }, g); }
  else { svg('rect', { x: -8, y: 6, width: 416, height: 836, fill: '#0a84ff', opacity: 0.05 }, g); }
  let drawn = 0;
  for (const h of SL.hits) {
    if (drawn > 500) break; const col = h.m._.fill !== 'none' ? h.m._.fill : h.m._.stroke;
    if (h.cut.spans) for (const s of h.cut.spans) { drawn++; const a = mode === 'axial' ? [s[0], pos, s[1], pos] : [pos, s[0], pos, s[1]]; svg('line', { x1: a[0], y1: a[1], x2: a[2], y2: a[3], stroke: col, 'stroke-width': 3.6, 'stroke-linecap': 'round', opacity: 0.95 }, g); svg('line', { x1: a[0], y1: a[1], x2: a[2], y2: a[3], stroke: '#fff', 'stroke-width': 1, opacity: 0.7 }, g); }
    else if (h.cut.cross) for (const u of h.cut.cross) { drawn++; svg('circle', { cx: mode === 'axial' ? u : pos, cy: mode === 'axial' ? pos : u, r: 2.2, fill: col, stroke: '#fff', 'stroke-width': 0.8 }, g); }
  }
}
function sliceDimUpdate() {
  const on = SL.mode !== 'off'; const hit = new Set(SL.hits.map((h) => h.m));
  for (const m of allMorphs()) {
    const dim = on && SL.dim && !SL.clip && !m.concealed && !hit.has(m) && m.layer.id !== 'skin';
    m.g.classList.toggle('sl-dim', dim);
    let cut = false;
    if (on && SL.clip && SL.mode === 'coronal' && !m.concealed) { const n = SC[sid(m)], pos = SL.pos.coronal; if (n && n.depth) cut = SL.keep > 0 ? n.depth.every((d) => d[0] > pos) : n.depth.every((d) => d[1] < pos); }
    m.g.classList.toggle('sl-cut', cut);
    if (m.fxv) { m.fxv.g.classList.toggle('sl-cut', cut || (on && SL.dim && !SL.clip && !hit.has(m))); }
  }
}
function sliceClip() {
  const on = SL.mode !== 'off' && SL.clip && SL.mode !== 'coronal', p = SL.pos[SL.mode], k = SL.keep, r = V2.clipRect;
  if (on) {
    if (SL.mode === 'axial') { r.setAttribute('x', -9999); r.setAttribute('width', 99999); if (k > 0) { r.setAttribute('y', p); r.setAttribute('height', 99999); } else { r.setAttribute('y', -9999); r.setAttribute('height', p + 9999); } }
    else { r.setAttribute('y', -9999); r.setAttribute('height', 99999); if (k > 0) { r.setAttribute('x', p); r.setAttribute('width', 99999); } else { r.setAttribute('x', -9999); r.setAttribute('width', p + 9999); } }
  }
  for (const l of W.layers) { if (on) l.g.setAttribute('clip-path', 'url(#slclip)'); else l.g.removeAttribute('clip-path'); }
}
function sliceRenderList() {
  const box = $('#slList'); box.textContent = '';
  const mode = SL.mode, pos = SL.pos[mode];
  if (mode === 'off') { box.append(mk('div', 'sln', 'Pick a plane above. The list shows which drawn structures the plane crosses.')); return; }
  $('#slInfo').textContent = mode === 'axial' ? `level y = ${Math.round(pos)} (around the ${landmark(pos)})` : mode === 'sagittal' ? `x = ${Math.round(pos)} (${Math.abs(pos - 200) < 6 ? 'midline' : pos < 200 ? 'patient\'s right of midline' : 'patient\'s left of midline'}, ${r2(Math.abs(pos - 200) * CM_PER_PX)} cm)` : `depth ${pos.toFixed(2)} (0 = front of body, 1 = back)`;
  const tot = SL.list.length; $('#slCount').textContent = `${SL.hits.length} pieces cut · ${tot} rows`;
  let lastSys = '';
  for (const g of SL.list.slice(0, 70)) {
    if (g.system !== lastSys) { lastSys = g.system; box.append(mk('div', 'slh', W.layerById[g.system] ? W.layerById[g.system]._.label : g.system)); }
    const r = mk('div', 'slr'); const dot = mk('i'); dot.style.background = g.color === 'none' ? '#999' : g.color;
    let detail = '';
    if (g.kind === 'inside') detail = `${g.n} inner pieces${g.parts.length ? ': ' + [...new Set(g.parts)].slice(0, 5).join(', ') : ''}`;
    else if (g.kind === 'tree') detail = `${g.n} branch cuts`;
    else if (g.w) detail = `${r2(g.w * CM_PER_PX)} cm across`;
    else if (SL.mode !== 'coronal') detail = g.n > 1 ? `${g.n} crossings` : 'crossed';
    r.append(dot, mk('span', 'nm', g.label), mk('span', 'dt', detail)); r.addEventListener('click', () => selectId(g.rep)); box.append(r);
  }
  if (tot > 70) box.append(mk('div', 'sln', `+${tot - 70} more rows`));
  if (!tot) box.append(mk('div', 'sln', 'Nothing drawn is cut at this position.'));
}
function sliceUpdate(quiet) {
  if (!V2.ready) return;
  $('#slice').style.display = SL.mode === 'off' && !SL.open ? 'none' : 'block';
  document.querySelectorAll('#slModes button').forEach((b) => b.classList.toggle('on', b.dataset.m === SL.mode));
  const mode = SL.mode, sl = $('#slPos');
  if (mode !== 'off') { if (mode === 'coronal') { sl.min = 0; sl.max = 100; sl.value = Math.round(SL.pos.coronal * 100); } else { sl.min = 0; sl.max = mode === 'axial' ? 840 : 400; sl.value = Math.round(SL.pos[mode]); } }
  sl.disabled = mode === 'off'; $('#slClip').checked = SL.clip; $('#slDim').checked = SL.dim;
  const ko = $('#slKeep'); const opts = mode === 'axial' ? ['above the plane', 'below the plane'] : mode === 'sagittal' ? ['patient\'s right half', 'patient\'s left half'] : ['front part', 'back part'];
  ko.options[0].text = 'keep ' + opts[0]; ko.options[1].text = 'keep ' + opts[1]; ko.selectedIndex = SL.keep > 0 ? 1 : 0;
  if (mode === 'off') { SL.hits = []; SL.list = []; } else sliceCompute();
  sliceDraw(); sliceClip(); sliceDimUpdate(); sliceRenderList(); $('#bSlice').classList.toggle('on', mode !== 'off'); dockLayout();
}
function sliceSet(mode, pos) {
  if (mode === 'off') { SL.mode = 'off'; SL.open = false; sliceUpdate(); return; }
  SL.mode = mode; SL.open = true;
  if (pos != null) SL.pos[mode] = mode === 'coronal' ? clamp(pos > 1.001 ? pos / 100 : pos, 0, 1) : +pos;
  else if (curId() && SC[curId()]) { const o = SC[curId()].origin || (SC[curId()].frame && SC[curId()].frame.origin); if (o) SL.pos[mode] = mode === 'axial' ? o[1] : mode === 'sagittal' ? o[0] : o[2]; }
  sliceUpdate();
}
document.querySelectorAll('#slModes button').forEach((b) => { b.onclick = () => sliceSet(b.dataset.m); });
$('#slPos').oninput = (e) => { const v = +e.target.value; SL.pos[SL.mode] = SL.mode === 'coronal' ? v / 100 : v; sliceUpdate(); };
$('#slClip').onchange = (e) => { SL.clip = e.target.checked; sliceUpdate(); }; $('#slDim').onchange = (e) => { SL.dim = e.target.checked; sliceUpdate(); };
$('#slKeep').onchange = (e) => { SL.keep = e.target.selectedIndex ? 1 : -1; sliceUpdate(); };
$('#slClose').onclick = () => sliceSet('off'); $('#bSlice').onclick = () => (SL.mode === 'off' ? sliceSet('axial') : sliceSet('off'));
SL.keep = 1;

function dockLayout() {
  const open = PH.open || SL.mode !== 'off'; $('#dock').classList.toggle('on', open);
  const pl = open ? 372 : 0; if (W.padL !== pl) { W.padL = pl; if (W.autoFit) fitView(); }
}

/* =================================================== validation modal */
function showValidation(on) {
  const box = $('#valid'); if (on === undefined) on = !box.classList.contains('on'); box.classList.toggle('on', on); if (!on) return;
  box.textContent = '';
  box.append(mk('h2', '', 'Anatomy checks'));
  box.append(mk('p', 'vs', `Run by build_atlas.rb every time the atlas is built: ${VAL.pass} passed · ${VAL.warn} warnings · ${VAL.fail} failed.`));
  for (const c of VAL.checks) { const r = mk('div', 'vr ' + c.status.toLowerCase()); r.append(mk('span', 'b', c.status), mk('span', 'nm', c.name)); if (c.detail) r.append(mk('span', 'dt', Array.isArray(c.detail) ? c.detail.join('; ') : c.detail)); box.append(r); }
  box.append(mk('p', 'vf', VAL.future || '')); const x = mk('button', 'btn', 'Close'); x.onclick = () => showValidation(false); box.append(x);
}
$('#bVal').onclick = () => showValidation();
$('#bVal').textContent = `Checks ${VAL.pass}/${VAL.checks.length}`;
function v2Esc() { showValidation(false); }

/* ============================================ ex commands & vim keys */
function v2Ex(c, rest, args) {
  const onoff = (v, d) => (v === undefined ? d : /^(on|1|yes|true)$/i.test(v));
  switch (c) {
    case 'children': { const id = curId(); if (!id) { say('nothing selected', true); return true; } const k = KIDS[id] || []; say(k.length ? `${k.length} inside ${labelOf(id)}: ${k.slice(0, 12).map(labelOf).join(', ')}${k.length > 12 ? '…' : ''}` : `${labelOf(id)} has no smaller pieces`); return true; }
    case 'parent': case 'up': drillUp(+args[0] || 1); return true;
    case 'down': case 'drill': drillDown(+args[0] || 1); return true;
    case 'path': { const id = curId(); say(id ? ancestry(id).map(labelOf).join(' › ') : 'nothing selected'); return true; }
    case 'focus': V2.focus = onoff(args[0], !V2.focus); $('#cFocus').checked = V2.focus; updateDim(); say('focus branch ' + (V2.focus ? 'on' : 'off')); return true;
    case 'skin': if (args[0] === undefined) { say(`skin opacity ${Math.round(V2.skin * 100)}%`); return true; } { let v = parseFloat(args[0]); if (v > 1) v /= 100; setSkin(v); say(`skin opacity ${Math.round(V2.skin * 100)}%`); } return true;
    case 'shade': V2.shade = onoff(args[0], !V2.shade); $('#cShade').checked = V2.shade; stage.classList.toggle('noshade', !V2.shade); say('shading ' + (V2.shade ? 'on' : 'off')); return true;
    case 'reveal': V2.reveal = onoff(args[0], !V2.reveal); applyConceal(); say(V2.reveal ? 'all inner structures shown' : 'inner structures appear when you select their organ'); return true;
    case 'legend': setLegend(onoff(args[0], !V2.legend)); return true;
    case 'tree': setTreeMode(args[0] === 'anatomy' ? 'anatomy' : 'systems'); return true;
    case 'timeline': case 'tl': physOpen(onoff(args[0], !PH.open)); return true;
    case 'play': physPlay(true); say('playing (schematic)'); return true;
    case 'pause': physPlay(false); say('paused'); return true;
    case 'step': physStep(1, +args[0] || 1); return true;
    case 'replay': physReplay(); say('replay from t = 0'); return true;
    case 'hr': if (!args.length) { say(`heart rate ${PH.hr} bpm (60-100)`); return true; } setHr(args[0]); say(`heart rate ${PH.hr} bpm`); return true;
    case 'rr': if (!args.length) { say(`breathing ${PH.rr}/min (12-20)`); return true; } setRr(args[0]); say(`breathing ${PH.rr}/min`); return true;
    case 'speed': PH.speed = clamp(parseFloat(args[0]) || 1, 0.1, 4); $('#tlSpd').value = [0.25, 0.5, 1, 2].includes(PH.speed) ? PH.speed : 1; say(`playback speed ${PH.speed}x`); return true;
    case 'slice': {
      const a = (args[0] || '').toLowerCase();
      if (!a) { say(SL.mode === 'off' ? 'usage: :slice axial|sagittal|coronal [position] | off' : `slice ${SL.mode} at ${r2(SL.pos[SL.mode])}`); return true; }
      if (a === 'off') { sliceSet('off'); say('slice off'); return true; }
      const mm = { a: 'axial', ax: 'axial', axial: 'axial', s: 'sagittal', sag: 'sagittal', sagittal: 'sagittal', c: 'coronal', cor: 'coronal', coronal: 'coronal' }[a];
      if (!mm) { say('slice: axial, sagittal, coronal or off', true); return true; }
      sliceSet(mm, args[1] !== undefined ? parseFloat(args[1]) : undefined); say(`${mm} slice: ${SL.list.length} rows`); return true;
    }
    case 'clip': SL.clip = onoff(args[0], !SL.clip); sliceUpdate(); return true;
    case 'zoom': { const id = args[0] && args[0] !== 'out' && args[0] !== 'fit' ? args[0] : (args[0] ? null : curId()); if (!id || !String(id).split(',').some((x) => SC[x])) { fitView(); say('zoom: fit whole body'); return true; } zoomTo(id); say('zoomed to ' + labelOf(id) + ' (:zoom out to fit again)'); return true; }
    case 'validate': case 'checks': showValidation(true); return true;
    default: return false;
  }
}
function v2Key(k, n, e) {
  switch (k) {
    case '>': drillDown(n); break;
    case '<': drillUp(n); break;
    case 'Tab': nextSibling(e.shiftKey ? -1 : 1, n); break;
    case ' ': physPlay(); break;
    case '.': physStep(1, n); break;
    case ',': physStep(-1, n); break;
    case 'T': physOpen(!PH.open); break;
    case 'Z': if (SL.mode === 'off') sliceSet('axial'); else sliceSet(SL.mode === 'axial' ? 'sagittal' : SL.mode === 'sagittal' ? 'coronal' : 'off'); break;
    case '(': setSkin(V2.skin - 0.1 * n); say(`skin ${Math.round(V2.skin * 100)}%`); break;
    case ')': setSkin(V2.skin + 0.1 * n); say(`skin ${Math.round(V2.skin * 100)}%`); break;
    default: break;
  }
}
function zoomTo(id) {
  const ns = String(id).split(',').map((x) => SC[x]).filter((n) => n && n.bbox); if (!ns.length) return;
  const bb = [Math.min(...ns.map((n) => n.bbox[0])), Math.min(...ns.map((n) => n.bbox[1])), Math.max(...ns.map((n) => n.bbox[2])), Math.max(...ns.map((n) => n.bbox[3]))];
  const r = stage.getBoundingClientRect(), pl = W.padL || 0;
  const w = bb[2] - bb[0] + 24, h = bb[3] - bb[1] + 24;
  const k = Math.min((r.width - pl - 60) / w, (r.height - 100) / h, 6);
  W.view.k = k; W.view.tx = pl + (r.width - pl - w * k) / 2 - (bb[0] - 12) * k; W.view.ty = (r.height - h * k) / 2 - (bb[1] - 12) * k;
  W.autoFit = false; applyView();
}
function v2Api() {
  return { scene: SC, kids: KIDS, ownerOf, ancestry, drillDown, drillUp, nextSibling, selectId, isConcealed: (id) => !!(MBY[id] && MBY[id].concealed),
    setSkin, getSkin: () => V2.skin, legend: LEG,
    phys: { state: PH, open: physOpen, play: physPlay, step: physStep, setTime: physSetTime, setPhase: physSetPhase, replay: physReplay, setHr, setRr, info: phaseInfo, render: renderPhys, entries: () => PH.entries.length },
    slice: { set: sliceSet, state: SL, list: () => SL.list.map((g) => ({ key: g.key, label: g.label, kind: g.kind, n: g.n })) },
    showValidation, v2: V2, planeCut, zoomTo };
}
buildLegend(); buildPanel(); setHr(PH.hr); setRr(PH.rr);


/* ================================================================== boot */
function boot() {
  W.defaults = deepCopy({ layers: WORLD0.layers, morphs: WORLD0.morphs.map((d) => ({ ...d, strokeWidth: d.stroke_width })) });
  buildWorld(deepCopy(W.defaults));
  W.committed = stateKey();
  fitView(); setMode('normal'); say('Click a piece · right-click or i = inspector · : = command line · ? = help');
  const saved = store.get(LS_KEY);
  if (saved) $('#hint').textContent = 'A saved world exists — :load restores it.';
  window.addEventListener('resize', () => { if (W.autoFit) fitView(); else updateHalo(); });
  // debug / scripting hook: the world is just JS objects you can poke
  window.morphic = { ...(typeof v2Api === 'function' ? v2Api() : {}), world: W, allMorphs, findMorph, select, setExplode, isolate: setIso, runEx, cmd, openInspector, closeInspector, undo, redo, fitView, Morph, Layer };
  window.addEventListener('error', (e) => say('error: ' + e.message, true));
}
boot();
})();
