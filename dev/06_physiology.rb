
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
