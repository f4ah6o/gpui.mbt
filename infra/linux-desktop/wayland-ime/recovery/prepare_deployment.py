#!/usr/bin/python3
"""Bind a NEW reviewed recovery closure. Never launches services or input.

Historical deployment/qualification files are never written. Exact expected
new build hashes are explicit inputs, not inferred approvals or historic pins.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import sys
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
DESKTOP = HERE.parents[1]
REPO = HERE.parents[3]
sys.dont_write_bytecode = True
sys.path.insert(0, str(DESKTOP))
import build_manifest
import candidate_bundle

MARKER = '.gpui-ime-recovery-evidence'
MARKER_TEXT = 'native-ime-recovery-evidence-v1\n'
EXPECTED_FIELDS = {'engine', 'component', 'mozc_build_result', 'candidate_manifest'}
REQUIRED_SOURCE_FILES = {
    'build_manifest.py', 'candidate_bundle.py', 'case_runner.py', 'input_cases.py',
    'gpui-desktop.py', 'profile.lock.json', 'mozc-prefix/rebuild.py',
    'mozc-prefix/build.lock.json', 'mozc-prefix/0001-scope-gyp-to-ibus.patch',
    'wayland-ime/probe.py', 'wayland-ime/evidence.py', 'wayland-ime/gpui_probe.py',
    'wayland-ime/gpui_evidence.py', 'wayland-ime/prepare-gpui-deployment.py',
    'wayland-ime/prepare-gpui-launcher.py', 'wayland-ime/prepare-launcher.py',
    'wayland-ime/recovery/__init__.py', 'wayland-ime/recovery/prepare_deployment.py',
    'wayland-ime/recovery/baseline_utilities.py', 'wayland-ime/recovery/transport_diagnostics.py'}


def sha(path):
    return build_manifest.digest(path)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def absolute(path):
    path = Path(path)
    require(path.is_absolute() and path != Path('/') and not path.is_symlink(), 'expected a direct absolute private path')
    require(path.resolve() == path, 'indirect private path is not admitted')
    return path


def directory(path):
    path = absolute(path)
    metadata = path.stat()
    require(stat.S_ISDIR(metadata.st_mode) and metadata.st_uid == os.geteuid(), 'directory is not current-user owned')
    return path


def inside(path, root):
    path, root = absolute(path), absolute(root)
    require(root in path.parents, 'foreign path outside its declared root: ' + str(path))
    return path


def regular(path):
    path = absolute(path)
    require(path.is_file(), 'expected a regular input file: ' + str(path))
    require(path.stat().st_uid == os.geteuid(), 'input file is not current-user owned')
    return path


def matched(path, expected, *, host=False):
    candidate_bundle.sha(expected, 'reviewed input')
    path = Path(path) if host else regular(path)
    require(path.is_file() and sha(path) == expected, 'unexpected input hash: ' + str(path))
    return path


def load(path):
    return candidate_bundle.load_json(regular(path))


def xml_bytes(tree):
    output = io.BytesIO()
    tree.write(output, encoding='utf-8', xml_declaration=True)
    return output.getvalue()


def verify_config(root, recipe):
    """Exact unmodified bootstrap configuration, no includes or new execs."""
    prefix = root / 'prefix'
    fonts = ET.Element('fontconfig')
    for name in ('truetype/dejavu', 'opentype/noto', 'truetype/noto'):
        ET.SubElement(fonts, 'dir').text = str(prefix / 'usr/share/fonts' / name)
    ET.SubElement(fonts, 'cachedir').text = str(root / 'cache/fontconfig')
    require(regular(root/'config/fonts.conf').read_bytes() == xml_bytes(ET.ElementTree(fonts)), 'unexpected Fontconfig bytes or paths')
    components = root/'config/ibus/component'
    require({p.name for p in components.iterdir()} == set(recipe['generated_component_names']), 'unexpected IBus component inventory')
    for name in recipe['generated_component_names']:
        tree = ET.parse(regular(prefix/'usr/share/ibus/component'/name))
        for element in tree.iter():
            if element.tag == 'exec' and element.text:
                element.text = element.text.replace('/usr/', str(prefix/'usr')+'/')
            if 'exec' in element.attrib:
                element.set('exec', element.get('exec').replace('/usr/', str(prefix/'usr')+'/'))
        require(regular(components/name).read_bytes() == xml_bytes(tree), 'unexpected generated IBus component: '+name)
    expected_schemas = {Path(n).name for n in recipe['fixed_config_files'] if n.startswith('config/schemas/')}
    require({p.name for p in (root/'config/schemas').iterdir()} == expected_schemas, 'unexpected private schema inventory')


def output_location(root, output, forbidden_roots):
    root, output = absolute(root), absolute(output)
    inside(output, root)
    require(output.parent == root and output.suffix == '.json', 'deployment must be a direct fresh JSON file in the dedicated evidence root')
    for forbidden in forbidden_roots:
        require(root != forbidden and forbidden not in root.parents and root not in forbidden.parents, 'evidence root overlaps source or runtime inputs')
    require(root.parent.is_dir() and root.parent.stat().st_uid == os.geteuid(), 'evidence parent must already be current-user owned')
    if root.exists():
        directory(root)
        require(not root.stat().st_mode & 0o077, 'existing evidence root is not private')
        marker = root/MARKER
        require(marker.is_file() and not marker.is_symlink() and marker.read_text() == MARKER_TEXT, 'refusing unowned existing evidence directory')
    return root, output


def verify_candidate_layout(runtime, profile_root, candidate_repo, recipe):
    """Reject foreign executable probes before the established verifier runs."""
    prefix=profile_root/'prefix'
    require(runtime.get('compiler_command') in (['cc'],['/usr/bin/cc']) and runtime.get('pkg_config_command') in (['pkg-config'],['/usr/bin/pkg-config']), 'unreviewed compiler/pkg-config command or wrapper')
    tools=recipe['build_tools'];seen=set()
    require(set(tools) == {'moon','moonc','moonrun','cc','pkg-config','wayland-scanner','fc-list','tcc'}, 'incomplete reviewed tool closure')
    for row in runtime['files']:
        role=row.get('role','');path=Path(row['path'])
        if role.startswith('tool:'):
            name=role[5:]
            require(name in tools and name not in seen, 'unexpected or duplicate captured runtime tool')
            seen.add(name);tool=tools[name]
            location=tool['location']
            expected_path=(profile_root/tool['relative_path']).resolve() if location=='profile' else Path(tool['path']).resolve()
            require(path == expected_path and row['sha256'] == tool['sha256'], 'foreign captured runtime executable: '+name)
            matched(path,tool['sha256'],host=location=='host')
        elif role=='profile-lock':
            require(row['sha256']==recipe['profile_lock_sha256'], 'foreign captured profile lock')
        elif role=='installed-profile':
            require(path==profile_root/'installed.json', 'foreign captured installed marker')
        elif role=='fontconfig':
            require(path==profile_root/'config/fonts.conf', 'foreign captured Fontconfig')
        elif role=='configured-font':
            inside(path,prefix/'usr/share/fonts')
        elif role.startswith('xkb:'):
            require(path==prefix/'usr/share/X11/xkb'/role[4:], 'foreign captured XKB data')
        else:
            raise RuntimeError('unrecognized candidate runtime file role')
    require(seen==set(tools), 'missing captured build tool')
    trees={row['role']:row for row in runtime['trees']}
    require(len(trees)==len(runtime['trees'])==2 and set(trees)=={'native-profile','moon-core'}, 'unexpected captured runtime tree inventory')
    require(trees['native-profile']['path']==str(prefix) and trees['native-profile']['sha256']==recipe['fixed_prefix_tree_sha256'] and trees['moon-core']['path']==str(profile_root/'moon/lib/core'), 'foreign captured prefix/core tree')
    generated=runtime['generated_protocols']
    require({row['path'] for row in generated}=={str(candidate_repo/'ubuntu'/name) for name in build_manifest.GENERATED_PROTOCOLS} and len(generated)==len(build_manifest.GENERATED_PROTOCOLS), 'foreign generated protocol inventory')


def construct(*, profile_root, mozc_build_root, candidate_repo, candidate_build_root,
              candidate_manifest, output_root, output, expected):
    """Read and bind explicit roots/hashes. Returns bytes to review, not a pass."""
    require(type(expected) is dict and set(expected) == EXPECTED_FIELDS, 'exact four reviewed build hashes required')
    for value in expected.values(): candidate_bundle.sha(value, 'explicit reviewed build')
    profile_root, mozc_build_root = directory(profile_root), directory(mozc_build_root)
    candidate_repo, candidate_build_root = directory(candidate_repo), directory(candidate_build_root)
    iac_repo = directory(REPO)
    roots = (profile_root, mozc_build_root, candidate_repo, candidate_build_root, iac_repo)
    require(len({profile_root, mozc_build_root, candidate_build_root}) == 3, 'build/profile roots must be separate')
    # A reviewed combined checkout can own both app and IaC source. Its actual
    # combined HEAD/worktree is then verified by both source snapshots.
    for source in (candidate_repo, iac_repo):
        for runtime in (profile_root, mozc_build_root, candidate_build_root):
            require(source != runtime and source not in runtime.parents and runtime not in source.parents, 'source and runtime roots must not overlap')
    output_root, output = output_location(output_root, output, roots)
    recipe_path = HERE/'recipe.lock.json'
    recipe = load(recipe_path)
    require(recipe.get('schema_version') == 1 and recipe.get('kind') == 'native-ime-recovery-recipe' and recipe.get('native_qualified') is False, 'unsupported recovery recipe')
    require(bool(recipe['source_files']), 'recovery source closure has not been frozen')
    require(REQUIRED_SOURCE_FILES <= set(recipe['source_files']), 'incomplete public recovery source closure')
    pins = {}
    for relative, expected_sha in recipe['source_files'].items():
        path = inside(DESKTOP/relative, DESKTOP)
        pins[str(path)] = expected_sha
        matched(path, expected_sha)
    matched(HERE.parent/'deployment.lock.json', recipe['historical_deployment_sha256'])
    profile_lock = matched(DESKTOP/'profile.lock.json', recipe['profile_lock_sha256'])
    mozc_lock = matched(DESKTOP/'mozc-prefix/build.lock.json', recipe['mozc_recipe_lock_sha256'])
    profile = load(profile_lock)
    require(regular(profile_root/'.gpui-desktop-profile').read_text() == 'gpui-linux-desktop-v1\n', 'profile is not owned by the original bootstrap')
    installed_path = regular(profile_root/'installed.json')
    installed = load(installed_path)
    require(installed.get('lock_sha256') == recipe['profile_lock_sha256'] and installed.get('profile') == profile, 'base installation manifest differs from exact official lock')
    prefix = directory(profile_root/'prefix')
    require(build_manifest.tree_digest(prefix) == recipe['fixed_prefix_tree_sha256'], 'unexpected complete official prefix tree')
    for relative, expected_sha in recipe['fixed_prefix_files'].items():
        path = inside(prefix/relative, prefix); matched(path, expected_sha); pins[str(path)] = expected_sha
    for relative, expected_sha in recipe['fixed_config_files'].items():
        path = inside(profile_root/relative, profile_root); matched(path, expected_sha); pins[str(path)] = expected_sha
    for path, expected_sha in recipe['host_executables'].items():
        require(path in ('/usr/bin/python3', '/usr/bin/dbus-daemon', '/usr/bin/convert'), 'unrecognized host execution path')
        matched(path, expected_sha, host=True); pins[path] = expected_sha
    verify_config(profile_root, recipe)
    for name in recipe['generated_component_names']:
        path=profile_root/'config/ibus/component'/name; pins[str(path)]=sha(path)
    pins[str(profile_root/'config/fonts.conf')] = sha(profile_root/'config/fonts.conf')
    pins[str(installed_path)] = sha(installed_path)
    pins[str(recipe_path)] = sha(recipe_path)

    result_path = mozc_build_root/'build-result.json'
    matched(result_path, expected['mozc_build_result'])
    result = load(result_path); contract = load(mozc_lock)
    engine, component = mozc_build_root/'artifacts/ibus-engine-mozc', mozc_build_root/'artifacts/mozc.xml'
    matched(engine, expected['engine']); matched(component, expected['component'])
    require(result.get('schema_version') == 1 and result.get('source_version') == contract['source_version'], 'unexpected Mozc build schema/source')
    require(result.get('recipe_lock_sha256') == recipe['mozc_recipe_lock_sha256'], 'Mozc build used another recipe')
    require(result.get('runtime_prefix') == str(prefix) and result.get('compiled_server_directory') == str(prefix/'usr/lib/mozc'), 'foreign compiled Mozc server directory')
    require(result.get('engine') == str(engine) and result.get('engine_sha256') == expected['engine'], 'foreign Mozc engine identity')
    require(result.get('registration_xml') == str(component) and result.get('registration_xml_sha256') == expected['component'], 'foreign Mozc component identity')
    require(result.get('stock_server') == str(prefix/'usr/lib/mozc/mozc_server') and result.get('stock_server_sha256') == contract['server_elf_sha256'], 'foreign Mozc stock server identity')
    require(result.get('security_source_verified') is True and result.get('runtime_linkage_passed') is True and result.get('renderer_built') is False and result.get('candidate_window') == 'ibus' and result.get('native_conversion_tested') is False, 'Mozc result is not the bounded built-unqualified contract')
    expected_configure=['/usr/bin/python3','build_mozc.py','gyp','--gypdir='+str(mozc_build_root/'build-prefix/usr/bin'),'--target_platform=Linux','--noqt','--server_dir='+str(prefix/'usr/lib/mozc'),'--verbose']
    require(result.get('configure_command') == expected_configure and result.get('build_command') == ['ninja','-C','out_linux/Release','-j4','ibus_mozc'], 'unreviewed Mozc build command')
    registration = ET.parse(component).getroot()
    require(registration.findtext('exec') == str(engine)+' --ibus' and registration.find('engines').get('exec') == str(engine)+' --xml', 'unexpected rebuilt Mozc component execution')
    records = contract['sources'] + [{'filename':Path(r['Filename']).name,'size':int(r['Size']),'sha256':r['SHA256']} for r in contract['extra_build_packages']]
    for record in records:
        archive = inside(mozc_build_root/'archives'/record['filename'], mozc_build_root)
        matched(archive,record['sha256']); require(archive.stat().st_size == record['size'], 'Mozc archive size drift')
    require(result.get('source_build_archive_bytes') == sum(r['size'] for r in records), 'Mozc archive budget identity changed')
    for relative, expected_sha in contract['build_contract']['security_source_sha256'].items():
        path=inside(mozc_build_root/'source'/relative, mozc_build_root);matched(path,expected_sha);pins[str(path)]=expected_sha
    for path in (result_path, engine, component): pins[str(path)] = sha(path)
    ldd_path=regular(mozc_build_root/'runtime-ldd.txt')
    require('not found' not in ldd_path.read_text() and bool(ldd_path.read_text().strip()), 'missing retained Mozc linkage evidence')
    pins[str(ldd_path)]=sha(ldd_path)

    candidate_manifest = regular(candidate_manifest)
    require(candidate_build_root in candidate_manifest.parents or candidate_manifest.parent == profile_root, 'foreign candidate manifest location')
    matched(candidate_manifest,expected['candidate_manifest'])
    sampled=load(candidate_manifest)
    require(sampled.get('mode') == 'built' and sampled.get('source_consistent') is True and sampled.get('source',{}).get('repo') == str(candidate_repo), 'candidate is not an exact-source compiled build')
    runtime=sampled.get('runtime',{})
    require(runtime.get('profile_root') == str(profile_root) and runtime.get('prefix') == str(prefix) and runtime.get('fontconfig') == str(profile_root/'config/fonts.conf'), 'candidate used foreign runtime/config roots')
    verify_candidate_layout(runtime,profile_root,candidate_repo,recipe)
    app=inside(sampled['binary']['path'],candidate_build_root);regular(app)
    # Expected hash and exact layout are checked before the established verifier
    # may run its captured read-only fc-list/git probes.
    captured=build_manifest.verify_build_manifest(candidate_manifest)
    require(captured == sampled, 'candidate manifest changed during verification')
    pins[str(candidate_manifest)]=expected['candidate_manifest'];pins[str(app)]=captured['binary']['sha256']
    source_snapshot=build_manifest.capture_source(iac_repo)
    profile_closure={'prefix':{'path':str(prefix),'sha256':recipe['fixed_prefix_tree_sha256']},
        'mozc_source':{'path':str(mozc_build_root/'source'),'sha256':build_manifest.tree_digest(mozc_build_root/'source')},
        'mozc_build_prefix':{'path':str(mozc_build_root/'build-prefix'),'sha256':build_manifest.tree_digest(mozc_build_root/'build-prefix')}}
    result={'schema_version':1,'kind':'native-ime-recovery-baseline','native_qualified':False,
        'ownership_model':'gpui-task-owner-birth-v1',
        'ownership_boundary':'Stable current native caller UID/PID/starttime captured before private runtime or child creation; strictly older stable births are outside this fresh run. Same-tick/newer live unreadable or ambiguous entries fail closed. This never verifies an earlier runtime.',
        'qualification_status':'prepared-native-unqualified','prefix':str(prefix),'support':str(profile_root),
        'engine':str(engine),'component':str(component),'gpui_app':str(app),
        'gpui_build_manifest':str(candidate_manifest),'driver':str(DESKTOP/'case_runner.py'),
        'baseline_utilities':str(HERE/'baseline_utilities.py'),'transport_parser':str(HERE/'transport_diagnostics.py'),
        'schema_compiler':str(prefix/'usr/lib/x86_64-linux-gnu/glib-2.0/glib-compile-schemas'),
        'output_root':str(output_root),'pins':pins,'iac_source':source_snapshot,
        'candidate_runtime_closure':captured['runtime'],'recovery_tree_closure':profile_closure,
        'recovery_inputs':{'profile_root':str(profile_root),'mozc_build_root':str(mozc_build_root),
            'candidate_repo':str(candidate_repo),'candidate_build_root':str(candidate_build_root),
            'candidate_manifest':str(candidate_manifest),'output_root':str(output_root),'output':str(output),'expected':expected},
        'historical_deployment_unchanged_sha256':recipe['historical_deployment_sha256'],
        'qualification_scope':'New reviewed recovery closure. Native qualification is pending; host ABI/dynamic libraries and approved native launch context remain prerequisites. Not a hermetic OS image.'}
    require(source_snapshot == build_manifest.capture_source(iac_repo), 'IaC source changed during recovery binding')
    return result


def verify_deployment(path):
    """Recheck the new closure before launcher preparation or native preflight."""
    data=load(path)
    require(data.get('kind') == 'native-ime-recovery-baseline' and data.get('native_qualified') is False, 'unsupported new recovery deployment')
    require(str(absolute(path)) == data['recovery_inputs']['output'], 'deployment moved outside its bound evidence location')
    rebuilt=construct(**data['recovery_inputs'])
    require(data == rebuilt, 'recovery deployment or complete source/runtime closure changed')
    return data


def prepare(**arguments):
    data=construct(**arguments);root=Path(data['output_root']);output=Path(arguments['output'])
    require(not output.exists(), 'refusing an existing deployment file')
    if not root.exists():
        root.mkdir(mode=0o700)
        (root/MARKER).write_text(MARKER_TEXT)
    with output.open('x',encoding='utf-8') as stream:
        stream.write(json.dumps(data,ensure_ascii=False,sort_keys=True,indent=2)+'\n')
    # Invalid output is retained for diagnosis and never labelled verified.
    verify_deployment(output)
    return output,data


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check',type=Path,help='reverify an already prepared new recovery deployment without native launch')
    for name in ('profile-root','mozc-build-root','candidate-repo','candidate-build-root','candidate-manifest','output-root','output'):
        parser.add_argument('--'+name,type=Path)
    for name in sorted(EXPECTED_FIELDS): parser.add_argument('--expected-'+name.replace('_','-')+'-sha256')
    args=parser.parse_args()
    if args.check:
        data=verify_deployment(args.check);output=args.check
    else:
        arguments={name:getattr(args,name) for name in ('profile_root','mozc_build_root','candidate_repo','candidate_build_root','candidate_manifest','output_root','output')}
        require(all(arguments.values()), 'all explicit source/runtime/output roots are required')
        arguments['expected']={name:getattr(args,'expected_'+name+'_sha256') for name in EXPECTED_FIELDS}
        output,data=prepare(**arguments)
    print(json.dumps({'prepared_deployment':str(output),'kind':data['kind'],'native_qualified':False,'native_executed':False,'pin_count':len(data['pins'])},indent=2))


if __name__ == '__main__': main()
