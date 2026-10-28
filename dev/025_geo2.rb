
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
