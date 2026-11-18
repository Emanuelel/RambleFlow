#!/usr/bin/env python3
"""Build the app. By default a development build that runs this checkout's worker with the installed Node;
with --bundle a self-contained app that carries its own Node, worker and runtime dependencies."""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--model', required=True, type=pathlib.Path, help='Path to compatible GGUF refiner weights.')
parser.add_argument('--bundle', action='store_true', help='Bundle the runtime and the supplied refiner weights.')
parser.add_argument('--fast-runtime', action='store_true', help='Require the Brew-installed timed ASR runtime on first launch.')
parser.add_argument('--refiner-url', help='HTTPS address the app downloads the --model weights from on first launch, instead of bundling them.')
parser.add_argument('--adapter', type=pathlib.Path)
parser.add_argument('--output', type=pathlib.Path, default=ROOT / '.local/app')
parser.add_argument('--identity', help='Code-signing identity from the keychain. Remembered privately for later builds; "-" returns to ad-hoc.')
args = parser.parse_args()
model = args.model.resolve()
adapter = args.adapter.resolve() if args.adapter else None
for weights in (model, adapter):
    if weights is not None and not weights.is_file():
        parser.error(f'Weights file not found: {weights}')
if args.refiner_url and (not args.bundle or adapter or not args.refiner_url.startswith('https://')):
    parser.error('--refiner-url needs --bundle, an https:// address and no separate adapter.')
if args.refiner_url and args.refiner_url.rsplit('/', 1)[-1] != model.name:
    parser.error(f'--refiner-url must end with the model file name, {model.name}.')
output = args.output.resolve()
if '.local' not in output.parts:
    parser.error('Keep local binaries and private settings in an ignored .local directory.')
node = shutil.which('node')
if not node:
    parser.error('Node was not found on this shell PATH.')
for tool in ['swiftc', 'codesign']:
    if not shutil.which(tool):
        parser.error(f'{tool} was not found on this shell PATH.')
def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()
if args.fast_runtime and (not args.bundle or adapter or digest(model) != '5f04f1d6366d58cd42f6da32832f64735c5cba3f04205adca22d573221f135c3'):
    parser.error('--fast-runtime requires a standalone bundle with the exact merged Literal192 Q4 weights and no separate adapter.')
output.mkdir(parents=True, exist_ok=True)
bundle = output / 'RambleFlow.app'
if args.bundle and (bundle.exists() or bundle.is_symlink()):
    parser.error('Choose a fresh --output directory to preserve the existing app bundle.')
macos = bundle / 'Contents/MacOS'
resources = bundle / 'Contents/Resources'
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
for notice in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
    shutil.copy2(ROOT / notice, resources / notice)
shutil.copy2(ROOT / 'app/RambleFlowMenu.png', resources / 'RambleFlowMenu.png')

shutil.copy2(ROOT / 'app/RambleFlowWaveform.png', resources / 'RambleFlowWaveform.png')
config = output / 'config.json'
if not args.bundle and not config.exists():
    settings = {'version': 1, 'cacheDirectory': str(ROOT / '.local/models'),
                'modelPath': str(model), 'modelSha256': digest(model), 'vocabulary': [], 'autoInsert': True}
    if adapter:
        settings.update(adapterPath=str(adapter), adapterSha256=digest(adapter), adapterBaseSha256=settings['modelSha256'])
    config.write_text(json.dumps(settings, indent=2) + '\n')
    os.chmod(config, 0o600)
launch = {'bundled': True} if args.bundle else {'projectRoot': str(ROOT), 'nodePath': node, 'configPath': str(config)}
if args.fast_runtime:
    launch['fastRuntime'] = True
(resources / 'launch.json').write_text(json.dumps(launch, indent=2) + '\n')
runtime = resources / 'runtime'
if runtime.exists():
    shutil.rmtree(runtime)
if args.bundle:
    # Production dependencies exactly as locked, installed once per lockfile and kept for later builds.
    lock = ROOT / 'package-lock.json'
    cache = output / 'runtime-cache' / digest(lock)[:16]
    # The marker is written last, so an interrupted install or prune is redone rather than shipped.
    if not (cache / 'complete').exists():
        if cache.exists():
            shutil.rmtree(cache)
        cache.mkdir(parents=True)
        for name in ['package.json', 'package-lock.json']:
            shutil.copy2(ROOT / name, cache / name)
        subprocess.run(['npm', 'ci', '--omit=dev', '--no-audit', '--no-fund'], cwd=cache, check=True)
        # Native packages ship builds for every platform; this app runs on Apple silicon only.
        for prebuilds in (cache / 'node_modules').rglob('prebuilds'):
            for platform in prebuilds.iterdir():
                if platform.is_dir() and platform.name != 'darwin-arm64':
                    shutil.rmtree(platform)
        (cache / 'complete').write_text('')
    (runtime / 'app').mkdir(parents=True)
    (runtime / 'scripts').mkdir()
    shutil.copy2(pathlib.Path(node).resolve(), runtime / 'node')
    # A Node that links libraries outside macOS itself (Homebrew's does) would not start on another Mac.
    linked = subprocess.run(['otool', '-L', str(runtime / 'node')], check=True, capture_output=True, text=True).stdout.splitlines()[1:]
    foreign = [line.strip() for line in linked if not line.strip().startswith(('/usr/lib/', '/System/'))]
    if foreign:
        parser.error('This Node links libraries a fresh Mac lacks: ' + '; '.join(foreign) + '. Use an official or nvm Node build.')
    for name in ['worker.mjs', 'core.mjs', 'timed-asr.mjs', 'model-download.mjs']:
        shutil.copy2(ROOT / 'app' / name, runtime / 'app' / name)
    shutil.copy2(ROOT / 'scripts/refiner-common.mjs', runtime / 'scripts/refiner-common.mjs')
    models = runtime / 'models'
    models.mkdir()
    manifest = {}
    for role, weights in [('base', model), ('adapter', adapter)]:
        if weights is None:
            continue
        filename = f'{role}.gguf'
        if args.refiner_url:
            # Too large to ship inside the installer: the worker downloads and checks it on first launch.
            manifest[role] = {'file': weights.name, 'sha256': digest(weights), 'bytes': weights.stat().st_size, 'url': args.refiner_url}
            continue
        bundled_weights = models / filename
        shutil.copy2(weights, bundled_weights)
        manifest[role] = {'file': filename, 'sha256': digest(bundled_weights)}
    (runtime / 'app/default-refiner.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (runtime / 'package.json').write_text(json.dumps({'private': True, 'type': 'module'}) + '\n')
    shutil.copytree(cache / 'node_modules', runtime / 'node_modules', symlinks=True)
shutil.copy2(ROOT / 'app/RambleFlow.icns', resources / 'RambleFlow.icns')
info = {'CFBundleExecutable': 'RambleFlow', 'CFBundleIdentifier': 'io.rambleflow.app',
        'CFBundleName': 'RambleFlow', 'CFBundleDisplayName': 'RambleFlow',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.1.0', 'CFBundlePackageType': 'APPL',
        'LSMinimumSystemVersion': '14.0', 'CFBundleIconFile': 'RambleFlow.icns',
        'NSMicrophoneUsageDescription': 'Record dictation while you hold the shortcut. Speech is processed locally with QVAC.'}
with (bundle / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump(info, stream)
subprocess.run(['swiftc', '-swift-version', '5', '-target', 'arm64-apple-macosx14.0', '-O', '-framework', 'AppKit', '-framework', 'AVFoundation',
                '-framework', 'ApplicationServices', '-framework', 'Carbon', *map(str, sorted((ROOT / 'app/native').glob('*.swift'))),
                '-o', str(macos / 'RambleFlow')], check=True)
# An ad-hoc signature identifies the app by its exact contents, so macOS drops its microphone and
# Accessibility permissions on every rebuild. A keychain identity keeps them.
remembered = output / 'sign-identity'
identity = args.identity or (remembered.read_text().strip() if remembered.exists() else '-')
def mach_o(path):
    with path.open('rb') as stream:
        return stream.read(4) in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
if args.bundle:
    # Notarization needs every executable signed with the hardened runtime. Node and Bare compile JavaScript
    # at run time and load native add-ons, which the entitlements allow; the app itself needs the microphone.
    engine = output / 'engine.entitlements'
    with engine.open('wb') as stream:
        plistlib.dump({'com.apple.security.cs.allow-jit': True, 'com.apple.security.cs.allow-unsigned-executable-memory': True,
                       'com.apple.security.cs.disable-library-validation': True}, stream)
    shell = output / 'app.entitlements'
    with shell.open('wb') as stream:
        plistlib.dump({'com.apple.security.device.audio-input': True}, stream)
    hardened = ['--options', 'runtime'] + (['--timestamp'] if identity != '-' else [])
    nested = sorted((p for p in runtime.rglob('*') if p.is_file() and not p.is_symlink() and mach_o(p)), key=lambda p: -len(p.parts))
    for path in nested:
        signed = subprocess.run(['codesign', '--force', '--sign', identity, *hardened, '--entitlements', str(engine), str(path)], capture_output=True, text=True)
        if signed.returncode:
            raise SystemExit(f'Signing {path} failed: {signed.stderr.strip()}')
    print(f'Signed {len(nested)} bundled executables and libraries.')
    subprocess.run(['codesign', '--force', '--sign', identity, *hardened, '--entitlements', str(shell), str(bundle)], check=True)
else:
    subprocess.run(['codesign', '--force', '--sign', identity, str(bundle)], check=True)
if args.identity:
    remembered.write_text(identity + '\n')
    os.chmod(remembered, 0o600)
print(f'Built {bundle}')
print('Signed ad-hoc: macOS will ask for permissions again after each rebuild.' if identity == '-' else 'Signed with the remembered keychain identity: permissions persist across rebuilds.')
if args.bundle:
    print('Self-contained: settings, statistics and models go to ~/Library/Application Support/RambleFlow; the speech model downloads on first start.')
else:
    print(f'Private model settings: {config}')
    print('Existing settings are preserved on rebuild. Update model paths and checksums in that file, then reload models.')
