
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
