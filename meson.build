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
  files('src/geo.vala', 'src/services.vala', 'src/mapview.vala', 'src/search.vala', 'src/window.vala', 'src/app.vala') + [resources],
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

install_data('data/dev.sinty.maps.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/icons/dev.sinty.maps.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
