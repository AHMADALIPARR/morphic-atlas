
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
