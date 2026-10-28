
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
