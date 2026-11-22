project('singularity-maps', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-maps"', language: 'c')
subdir('po')

gtk_dep   = dependency('gtk4')
gee_dep   = dependency('gee-0.8')
soup_dep  = dependency('libsoup-3.0')
json_dep  = dependency('json-glib-1.0')
posix_dep = meson.get_compiler('vala').find_library('posix')
math_dep  = meson.get_compiler('c').find_library('m')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

gnome = import('gnome')
resources = gnome.compile_resources(
  'singularity-maps-resources',
  'resources/dev.sinty.maps.gresource.xml',
  source_dir: meson.current_source_dir() / 'data' / 'icons',
)

executable('singularity-maps',
  files('src/geo.vala', 'src/services.vala', 'src/mapview.vala', 'src/search.vala', 'src/window.vala', 'src/travel_bus.vala', 'src/app.vala', 'src/agent_intents.vala') + [resources],
  dependencies: [gtk_dep, gee_dep, soup_dep, json_dep, posix_dep, math_dep, libsingularity_dep],
  install: true
)

maps_test = executable('maps-test',
  files('src/geo.vala', 'src/services.vala', 'tests/maps_test.vala'),
  dependencies: [gee_dep, soup_dep, json_dep, posix_dep, math_dep, dependency('gio-2.0')],
)
test('maps', maps_test, env: ['MAPS_FIXTURES=' + meson.current_source_dir() / 'tests' / 'fixtures'])

install_data('data/search-providers/dev.sinty.maps.ini',
  install_dir: get_option('datadir') / 'singularity' / 'search-providers'
)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.maps.service.in',
  output: 'dev.sinty.maps.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

install_data('data/capabilities/dev.sinty.Maps1.ini',
  install_dir: get_option('datadir') / 'singularity' / 'capabilities'
)

install_data('data/dev.sinty.maps.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/icons/dev.sinty.maps.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

iride = find_program('iride', required: get_option('iride'))
if iride.found()
  custom_target('iride-icon',
    input: 'data/icons/iride/iride.json',
    output: 'dev.sinty.maps.iride',
    depend_files: files(
      'data/icons/iride/layers/000.svg',
      'data/icons/iride/layers/001.svg',
      'data/icons/iride/layers/002.svg',
      'data/icons/iride/layers/003.svg',
      'data/icons/iride/layers/004.svg',
      'data/icons/iride/layers/005.svg',
      'data/icons/iride/layers/006.svg',
      'data/icons/iride/layers/007.svg',
      'data/icons/iride/layers/008.svg',
      'data/icons/iride/layers/009.svg',
      'data/icons/iride/layers/010.svg',
      'data/icons/iride/layers/011.svg',
      'data/icons/iride/layers/012.svg',
      'data/icons/iride/layers/013.svg',
      'data/icons/iride/layers/014.svg',
      'data/icons/iride/layers/015.svg',
      'data/icons/iride/layers/016.svg',
      'data/icons/iride/layers/017.svg',
      'data/icons/iride/layers/018.svg',
      'data/icons/iride/layers/019.svg',
      'data/icons/iride/layers/020.svg',
      'data/icons/iride/layers/021.svg',
      'data/icons/iride/layers/022.svg',
      'data/icons/iride/layers/023.svg',
      'data/icons/iride/layers/024.svg',
      'data/icons/iride/layers/025.svg',
      'data/icons/iride/layers/026.svg',
      'data/icons/iride/layers/027.svg',
      'data/icons/iride/layers/028.svg',
      'data/icons/iride/layers/029.svg',
      'data/icons/iride/layers/030.svg',
      'data/icons/iride/layers/031.svg',
      'data/icons/iride/layers/032.svg',
      'data/icons/iride/layers/033.svg',
      'data/icons/iride/layers/034.svg',
      'data/icons/iride/layers/035.svg',
      'data/icons/iride/layers/036.svg',
      'data/icons/iride/layers/037.svg',
      'data/icons/iride/layers/038.svg',
      'data/icons/iride/layers/039.svg',
      'data/icons/iride/layers/040.svg',
      'data/icons/iride/layers/041.svg',
      'data/icons/iride/layers/042.svg',
      'data/icons/iride/layers/043.svg',
      'data/icons/iride/layers/044.svg',
      'data/icons/iride/layers/045.svg',
      'data/icons/iride/layers/046.svg',
    ),
    command: [iride, 'build', meson.current_source_dir() / 'data' / 'icons' / 'iride', '@OUTPUT@'],
    install: true,
    install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
  )
endif
