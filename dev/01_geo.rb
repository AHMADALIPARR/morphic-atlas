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
