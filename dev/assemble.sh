#!/bin/sh
# dev helper: concatenate the parts into the single deliverable build_atlas.rb
set -e
cd "$(dirname "$0")"
{
  cat 01_geo.rb 025_geo2.rb 02_anatomy.rb 04_scene.rb 05_scene_graph.rb 06_physiology.rb 07_validation.rb 03_main.rb
  printf '@@css\n'; cat tpl.css
  printf '@@html\n'; cat tpl.html
  printf '@@js\n'
  ruby -e 'print File.read("tpl.js").sub("/*__V2__*/") { File.read("tpl_v2.js") }'
} > ../build_atlas.rb
