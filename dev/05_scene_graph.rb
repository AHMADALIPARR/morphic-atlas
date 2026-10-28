
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
