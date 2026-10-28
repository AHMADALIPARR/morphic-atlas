
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
