"""Regenerate the checked-in Xcode project in the JSON (project.xcproj) format.

Recursively discovers Swift sources under ``DiskUnbloat/`` and mirrors the
directory tree into the project's file tree. Target membership is expressed
per file via ``"target-membership": ["<Target>/compile-sources"]`` (or
``.../resources``), so adding a source file is a single entry in one place.

Build settings shared across configurations are written once; configuration
specific differences use ``[config=Debug]`` / ``[config=Release]`` key suffixes.
Owner-configured signing/team/bundle overrides are read back from the existing
``project.xcproj`` and preserved, matching the previous pbxproj generator's
contract. The output is canonicalized with Apple's ``xcprojformatter`` so the
checked-in file stays stable and diff-friendly.

Run with: ``python3 Tools/generate-project.py``
"""

from pathlib import Path
import json
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
app_dir = root / 'DiskUnbloat'
project_bundle = root / 'DiskUnbloat.xcodeproj'
xcproj_path = project_bundle / 'project.xcproj'
scheme_path = project_bundle / 'xcshareddata' / 'xcschemes' / 'DiskUnbloat.xcscheme'

# --- stable identifiers -------------------------------------------------------
# Targets and build products keep opaque IDs so external references (the shared
# scheme's BlueprintIdentifier values) and cross-target references stay valid.
# The hex values match the historical pbxproj IDs, so the existing scheme works
# unchanged after conversion.
def uid(n):
    return f'{n:024X}'


APP_TARGET_ID = uid(5)
APP_PRODUCT_ID = uid(6)
UITESTS_TARGET_ID = uid(40)
UITESTS_PRODUCT_ID = uid(41)
TESTS_TARGET_ID = uid(60)
TESTS_PRODUCT_ID = uid(61)

# Signing settings that survive regeneration (owner-configured in Xcode's UI).
SIGNING_KEYS = {
    'DEVELOPMENT_TEAM',
    'PRODUCT_BUNDLE_IDENTIFIER',
    'CODE_SIGN_STYLE',
    'CODE_SIGN_IDENTITY',
    'PROVISIONING_PROFILE_SPECIFIER',
    'PROVISIONING_PROFILE',
}


# --- existing-project readback (for signing preservation) --------------------
def strip_json5(text):
    """Drop JSON5 trailing commas so the stdlib parser can read Apple's xcproj."""
    return re.sub(r',(\s*[}\]])', r'\1', text)


def load_existing():
    """Read the current project.xcproj, if present, else return an empty model."""
    if not xcproj_path.exists():
        return {}
    return json.loads(strip_json5(xcproj_path.read_text(encoding='utf-8')))


def signing_overrides(existing, target_name):
    """Return the signing settings a user configured for one target."""
    for target in existing.get('targets', []):
        if target.get('name') == target_name:
            settings = target.get('build-settings', {})
            return {k: v for k, v in settings.items() if k.split('[')[0] in SIGNING_KEYS}
    return {}


# --- build settings -----------------------------------------------------------
def project_build_settings():
    return {
        'CLANG_ENABLE_MODULES': 'YES',
        'MACOSX_DEPLOYMENT_TARGET': '26.0',
        'SDKROOT': 'macosx',
        'SWIFT_STRICT_CONCURRENCY': 'complete',
        'SWIFT_VERSION': '6.0',
        'SWIFT_OPTIMIZATION_LEVEL[config=Debug]': '-Onone',
        'SWIFT_OPTIMIZATION_LEVEL[config=Release]': '-O',
        'ONLY_ACTIVE_ARCH[config=Debug]': 'YES',
        'ONLY_ACTIVE_ARCH[config=Release]': 'NO',
        'ENABLE_TESTABILITY[config=Debug]': 'YES',
        'ENABLE_TESTABILITY[config=Release]': 'NO',
    }


def app_build_settings(existing):
    settings = {
        'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
        'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME': 'AccentColor',
        'CODE_SIGN_ENTITLEMENTS': 'DiskUnbloat/App/DiskUnbloat.entitlements',
        'CODE_SIGN_STYLE': 'Automatic',
        'COMBINE_HIDPI_IMAGES': 'YES',
        'CURRENT_PROJECT_VERSION': '1',
        'ENABLE_APP_SANDBOX': 'YES',
        'ENABLE_HARDENED_RUNTIME': 'YES',
        'GENERATE_INFOPLIST_FILE': 'YES',
        'INFOPLIST_FILE': 'DiskUnbloat/App/Info.plist',
        'INFOPLIST_KEY_CFBundleDisplayName': 'DiskUnbloat',
        'INFOPLIST_KEY_LSApplicationCategoryType': 'public.app-category.utilities',
        'INFOPLIST_KEY_NSHumanReadableCopyright': 'Copyright © 2026 DiskUnbloat',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/../Frameworks'],
        'MARKETING_VERSION': '1.0',
        'PRODUCT_BUNDLE_IDENTIFIER': 'com.diskunbloat.app',
        'PRODUCT_NAME': '$(TARGET_NAME)',
        'SWIFT_EMIT_LOC_STRINGS': 'YES',
        'SWIFT_STRICT_CONCURRENCY': 'complete',
        'SWIFT_VERSION': '6.0',
    }
    settings.update(signing_overrides(existing, 'DiskUnbloat'))
    return settings


def uitests_build_settings(existing):
    settings = {
        'CODE_SIGN_STYLE': 'Automatic',
        'GENERATE_INFOPLIST_FILE': 'YES',
        'PRODUCT_BUNDLE_IDENTIFIER': 'com.diskunbloat.app.uitests',
        'PRODUCT_NAME': '$(TARGET_NAME)',
        'SWIFT_VERSION': '6.0',
        'TEST_TARGET_NAME': 'DiskUnbloat',
    }
    settings.update(signing_overrides(existing, 'DiskUnbloatUITests'))
    return settings


def tests_build_settings(existing):
    settings = {
        'BUNDLE_LOADER': '$(TEST_HOST)',
        'CODE_SIGN_STYLE': 'Automatic',
        'GENERATE_INFOPLIST_FILE': 'YES',
        'PRODUCT_BUNDLE_IDENTIFIER': 'com.diskunbloat.app.tests',
        'PRODUCT_NAME': '$(TARGET_NAME)',
        'SWIFT_VERSION': '6.0',
        'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/DiskUnbloat.app/Contents/MacOS/DiskUnbloat',
    }
    settings.update(signing_overrides(existing, 'DiskUnbloatTests'))
    return settings


# --- file tree ----------------------------------------------------------------
def file_node(name, membership=None):
    node = {'path': name}
    if membership:
        node['target-membership'] = list(membership)
    return node


def app_tree():
    """Mirror DiskUnbloat/'s on-disk directories as a nested file tree."""
    entries = []  # (relative_path, node)
    for p in sorted(app_dir.rglob('*.swift')):
        rel = p.relative_to(app_dir)
        entries.append((rel, file_node(rel.name, ['DiskUnbloat/compile-sources'])))

    # Fixed resources, in the order they appear in the navigator.
    entries.extend([
        (Path('Resources/Localizable.xcstrings'),
         file_node('Localizable.xcstrings', ['DiskUnbloat/resources'])),
        (Path('App/Info.plist'), file_node('Info.plist')),
        (Path('Resources/PrivacyInfo.xcprivacy'),
         file_node('PrivacyInfo.xcprivacy', ['DiskUnbloat/resources'])),
        (Path('Resources/Assets.xcassets'),
         file_node('Assets.xcassets', ['DiskUnbloat/resources'])),
        (Path('App/DiskUnbloat.entitlements'), file_node('DiskUnbloat.entitlements')),
    ])

    directories = sorted(
        {parent for rel, _ in entries for parent in rel.parents if parent != Path('.')},
        key=str,
    )

    def group_node(directory):
        label = 'DiskUnbloat' if directory == Path('.') else directory.name
        children = [node for rel, node in entries if rel.parent == directory]
        children += [group_node(sub) for sub in directories if sub.parent == directory]
        return {'kind': 'group', 'path': label, 'children': children}

    return group_node(Path('.'))


def products_group():
    return {
        'kind': 'group',
        'name': 'Products',
        'children': [
            {'path': '<PRODUCTS>/DiskUnbloat.app', 'id': APP_PRODUCT_ID,
             'type': 'wrapper.application', 'index': False},
            {'path': '<PRODUCTS>/DiskUnbloatUITests.xctest', 'id': UITESTS_PRODUCT_ID,
             'type': 'wrapper.cfbundle'},
            {'path': '<PRODUCTS>/DiskUnbloatTests.xctest', 'id': TESTS_PRODUCT_ID,
             'type': 'wrapper.cfbundle'},
        ],
    }


# --- targets ------------------------------------------------------------------
def diskcore_product_members():
    # Faithful to the prior pbxproj, which linked DiskCore both via the target's
    # package-product declaration and an explicit frameworks build phase.
    member = {'package': 'DiskCore', 'product-name': 'DiskCore',
              'build-phase': {'build-phase': 'frameworks'}}
    return [member, member]


def targets(existing):
    return [
        {
            'name': 'DiskUnbloat',
            'id': APP_TARGET_ID,
            'product': 'Products/DiskUnbloat.app',
            'product-type': 'application',
            'build-phases': ['compile-sources', 'frameworks', 'resources'],
            'package-product-members': diskcore_product_members(),
            'build-settings': app_build_settings(existing),
        },
        {
            'name': 'DiskUnbloatUITests',
            'id': UITESTS_TARGET_ID,
            'product': 'Products/DiskUnbloatUITests.xctest',
            'product-type': 'bundle.ui-testing',
            'dependencies': ['DiskUnbloat'],
            'build-phases': ['compile-sources', 'frameworks'],
            'build-settings': uitests_build_settings(existing),
        },
        {
            'name': 'DiskUnbloatTests',
            'id': TESTS_TARGET_ID,
            'product': 'Products/DiskUnbloatTests.xctest',
            'product-type': 'bundle.unit-test',
            'dependencies': ['DiskUnbloat'],
            'build-phases': ['compile-sources', 'frameworks'],
            'package-product-members': diskcore_product_members(),
            'build-settings': tests_build_settings(existing),
        },
    ]


# --- assembly -----------------------------------------------------------------
def build_project(existing):
    return {
        'default-configuration': 'Release',
        'configurations': ['Debug', 'Release'],
        'localizations': {'development': 'en', 'supported': ['Base', 'ru']},
        'packages': [{'kind': 'local', 'path': 'Packages/DiskCore'}],
        'files': [
            app_tree(),
            products_group(),
            # Test sources are flat directories; discovered recursively like app sources.
            {'kind': 'group', 'path': 'DiskUnbloatUITests', 'children': [
                file_node(f.name, ['DiskUnbloatUITests/compile-sources'])
                for f in sorted((root / 'DiskUnbloatUITests').rglob('*.swift'))
            ]},
            {'kind': 'group', 'path': 'DiskUnbloatTests', 'children': [
                file_node(f.name, ['DiskUnbloatTests/compile-sources'])
                for f in sorted((root / 'DiskUnbloatTests').rglob('*.swift'))
            ]},
        ],
        'targets': targets(existing),
        'build-settings': project_build_settings(),
        'last-upgrade': '26.6',
    }


def canonicalize():
    """Normalize project.xcproj with Apple's formatter (validates + orders keys)."""
    attempts = (
        ['xcrun', 'xcprojformatter'],
        ['/Applications/Xcode.app/Contents/Developer/usr/bin/xcprojformatter'],
    )
    for cmd in attempts:
        try:
            subprocess.run(cmd + ['--update', str(project_bundle)],
                           check=True, capture_output=True, text=True)
            return
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
    print('warning: xcprojformatter not found; wrote non-canonical (but valid) '
          'project.xcproj', file=sys.stderr)


def write_scheme():
    scheme_path.parent.mkdir(parents=True, exist_ok=True)
    scheme_path.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Scheme LastUpgradeVersion="2660" version="1.3">'
        '<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">'
        '<BuildActionEntries>'
        '<BuildActionEntry buildForTesting="YES" buildForRunning="YES" '
        'buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">'
        '<BuildableReference BuildableIdentifier="primary" '
        f'BlueprintIdentifier="{APP_TARGET_ID}" BuildableName="DiskUnbloat.app" '
        'BlueprintName="DiskUnbloat" ReferencedContainer="container:DiskUnbloat.xcodeproj"/>'
        '</BuildActionEntry></BuildActionEntries></BuildAction>'
        '<TestAction buildConfiguration="Debug"><Testables>'
        '<TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" '
        f'BlueprintIdentifier="{TESTS_TARGET_ID}" BuildableName="DiskUnbloatTests.xctest" '
        'BlueprintName="DiskUnbloatTests" ReferencedContainer="container:DiskUnbloat.xcodeproj"/>'
        '</TestableReference>'
        '<TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" '
        f'BlueprintIdentifier="{UITESTS_TARGET_ID}" BuildableName="DiskUnbloatUITests.xctest" '
        'BlueprintName="DiskUnbloatUITests" ReferencedContainer="container:DiskUnbloat.xcodeproj"/>'
        '</TestableReference></Testables></TestAction>'
        '<LaunchAction buildConfiguration="Debug" '
        'selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" '
        'selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" '
        'useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" '
        'debugDocumentVersioning="YES" allowLocationSimulation="YES">'
        '<BuildableProductRunnable runnableDebuggingMode="0">'
        '<BuildableReference BuildableIdentifier="primary" '
        f'BlueprintIdentifier="{APP_TARGET_ID}" BuildableName="DiskUnbloat.app" '
        'BlueprintName="DiskUnbloat" ReferencedContainer="container:DiskUnbloat.xcodeproj"/>'
        '</BuildableProductRunnable></LaunchAction>'
        '<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" '
        'savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">'
        '<BuildableProductRunnable runnableDebuggingMode="0">'
        '<BuildableReference BuildableIdentifier="primary" '
        f'BlueprintIdentifier="{APP_TARGET_ID}" BuildableName="DiskUnbloat.app" '
        'BlueprintName="DiskUnbloat" ReferencedContainer="container:DiskUnbloat.xcodeproj"/>'
        '</BuildableProductRunnable></ProfileAction>'
        '<AnalyzeAction buildConfiguration="Debug"/>'
        '<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>'
        '</Scheme>'
    )


def main():
    existing = load_existing()
    project = build_project(existing)
    xcproj_path.write_text(json.dumps(project, indent=2, ensure_ascii=False) + '\n',
                           encoding='utf-8')
    canonicalize()
    write_scheme()


if __name__ == '__main__':
    main()
