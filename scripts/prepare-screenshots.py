#!/usr/bin/env python3
"""Build a separate offline demo app for privacy-safe screenshots.

Only the copied sources under build/ScreenshotDemo are adapted. The shipping
sources, accounts, recordings and attachment store are not changed.
"""
import json, platform, re, shutil, subprocess, sys
from pathlib import Path
repo = Path(__file__).resolve().parent.parent
fixture = repo / 'scripts/screenshot-fixtures'
work = repo / 'build/ScreenshotDemo'
work.mkdir(parents=True, exist_ok=True)
source = work / 'Sources'
shutil.copytree(repo / 'Sources/LiveKitObserver', source, dirs_exist_ok=True)
def replace(path, old, new):
    text = path.read_text()
    if old not in text:
        raise RuntimeError(f'Screenshot fixture integration changed: {path.name}')
    path.write_text(text.replace(old, new))
replace(source / 'LiveKitObserverApp.swift', '@main\n', '')
appmodel = source / 'AppModel.swift'
text = appmodel.read_text()
text, count = re.subn(r'    static var isTesting: Bool \{[^\n]+\}', '    static var isTesting: Bool { true }', text)
assert count == 1
text, count = re.subn(r'    var cli: LiveKitCLI\? \{.*?\n    \}', '    var cli: LiveKitCLI? { nil }', text, count=1, flags=re.S)
assert count == 1
appmodel.write_text(text)
replace(appmodel, 'let captures = PacketCaptureModel()', 'let captures = PacketCaptureModel(store: ScreenshotFixture.store)')
replace(appmodel, 'var selection: SessionRow.ID? { didSet { if selection != oldValue { openSelection() } } }', 'var selection: SessionRow.ID?')
# Synthetic IDs can never recover real annotations. Keep fixture rendering read-only.
replace(appmodel, 'flags = Self.loadFlags(row.id)', 'flags = []')
shutil.copy2(fixture / 'ScreenshotApp.swift', source / 'ScreenshotApp.swift')
data = work / 'DemoData'
subprocess.run([sys.executable, str(fixture / 'make-fixtures.py'), str(data)], check=True)
spec = {
    'name': 'ObserverScreenshots',
    'options': {'deploymentTarget': {'macOS': '15.0'}},
    'packages': {
        'ObserverCore': {'path': str(repo / 'Packages/ObserverCore')},
        'LiveKit': {'url': 'https://github.com/livekit/client-sdk-swift', 'exactVersion': '2.19.0'},
        'Yams': {'url': 'https://github.com/jpsim/Yams', 'exactVersion': '6.2.2'},
        'Sparkle': {'url': 'https://github.com/sparkle-project/Sparkle', 'exactVersion': '2.10.1'}
    },
    'targets': {'ObserverScreenshots': {
        'type': 'application', 'platform': 'macOS',
        'sources': [{'path': 'Sources'}, {'path': 'DemoData', 'type': 'folder', 'buildPhase': 'resources'}],
        'dependencies': [{'package': n} for n in ['ObserverCore', 'LiveKit', 'Yams', 'Sparkle']],
        'settings': {'base': {
            'SWIFT_VERSION': '5.0', 'PRODUCT_NAME': 'Observer Screenshots',
            'PRODUCT_BUNDLE_IDENTIFIER': 'com.yepher.observer-screenshots',
            'GENERATE_INFOPLIST_FILE': True, 'INFOPLIST_KEY_CFBundleDisplayName': 'Observer Screenshots',
            'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'CODE_SIGNING_ALLOWED': False,
            'ENABLE_HARDENED_RUNTIME': False, 'ENABLE_APP_SANDBOX': False,
            'MARKETING_VERSION': '0.2.0', 'CURRENT_PROJECT_VERSION': '1'
        }}
    }},
    'schemes': {'ObserverScreenshots': {'build': {'targets': {'ObserverScreenshots': 'all'}}}}
}
(work / 'project.json').write_text(json.dumps(spec, indent=2))
subprocess.run(['xcodegen', 'generate', '--spec', str(work / 'project.json'), '--project', str(work), '--quiet'], check=True)
pbx = work / 'ObserverScreenshots.xcodeproj/project.pbxproj'
pbx.write_text(re.sub(r'(?m)^.*isa = PBXFileReference;.*path = .*ObserverCore;.*$', lambda m: m[0].replace('lastKnownFileType = folder;', 'lastKnownFileType = wrapper;'), pbx.read_text()))
lock = repo / 'LiveKitObserver.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
if lock.exists():
    target = work / 'ObserverScreenshots.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(lock, target)
subprocess.run([
    'xcodebuild', '-project', str(work / 'ObserverScreenshots.xcodeproj'), '-scheme', 'ObserverScreenshots',
    '-configuration', 'Debug', '-derivedDataPath', str(repo / 'build/ScreenshotDerivedData'),
    '-clonedSourcePackagesDirPath', str(repo / 'build/DerivedData/SourcePackages'),
    '-skipPackageUpdates', '-disableAutomaticPackageResolution', '-quiet', 'build',
    'ARCHS=' + platform.machine(), 'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO'
], check=True)
app = repo / 'build/ScreenshotDerivedData/Build/Products/Debug/Observer Screenshots.app'
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
print(f'Built offline screenshot app: {app}')
