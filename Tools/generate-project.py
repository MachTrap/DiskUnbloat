from pathlib import Path
import json
import re
import subprocess
root=Path(__file__).resolve().parents[1]
files=sorted((root/'DiskUnbloat').rglob('*.swift'))
def uid(n): return f'{n:024X}'
objects=[]
project_path = root/'DiskUnbloat.xcodeproj/project.pbxproj'
previous_objects = {}
if project_path.exists():
 result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(project_path)], capture_output=True, text=True, check=True)
 previous_objects = json.loads(result.stdout)['objects']
# Keep owner-configured signing when regenerating source membership.
signing_keys = {'DEVELOPMENT_TEAM', 'PRODUCT_BUNDLE_IDENTIFIER', 'CODE_SIGN_STYLE', 'CODE_SIGN_IDENTITY', 'PROVISIONING_PROFILE_SPECIFIER', 'PROVISIONING_PROFILE'}
def obj(n, v):
 if 'isa = XCBuildConfiguration;' in v:
  previous = previous_objects.get(uid(n), {}).get('buildSettings', {})
  for key,value in previous.items():
   if key.split('[')[0] not in signing_keys:
    continue
   setting = json.dumps(key)+' = '+json.dumps(value)+';'
   pattern = r'(?<![A-Za-z0-9_])'+re.escape(key)+r'\s*=\s*(?:"[^"\n]*"|[^;]*);'
   if re.search(pattern, v):
    v = re.sub(pattern, lambda _: setting, v, count=1)
   else:
    v = v.replace(' }; name =', ' '+setting+' }; name =', 1)
 objects.append(f'{uid(n)} = {{ {v} }};')
for i,f in enumerate(files):
 obj(10000+i,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{f.name}"; sourceTree = "<group>";')
 obj(20000+i,f'isa = PBXBuildFile; fileRef = {uid(10000+i)};')
obj(1,'isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2660; }; buildConfigurationList = '+uid(10)+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, ru, Base); mainGroup = '+uid(2)+'; productRefGroup = '+uid(4)+'; projectDirPath = ""; projectRoot = ""; targets = ('+uid(5)+','+uid(40)+','+uid(60)+'); packageReferences = ('+uid(30)+');')
obj(2,'isa = PBXGroup; children = ('+uid(3)+','+uid(4)+','+uid(48)+','+uid(67)+'); sourceTree = "<group>";')
# Mirror actual directories in the Xcode navigator; new nested Swift files are discovered recursively.
source_ids = {f.relative_to(root/'DiskUnbloat'): 10000+i for i,f in enumerate(files)}
resource_ids = {Path('Resources/Localizable.xcstrings'): 38, Path('App/Info.plist'): 39, Path('Resources/PrivacyInfo.xcprivacy'): 33, Path('Resources/Assets.xcassets'): 35, Path('App/DiskUnbloat.entitlements'): 37}
all_ids = source_ids | resource_ids
directories = sorted({parent for path in all_ids for parent in path.parents if parent != Path('.')}, key=str)
group_ids = {directory: 100000+i for i,directory in enumerate(directories)}
def group_children(directory):
 children = [number for path,number in all_ids.items() if path.parent == directory]
 children += [number for path,number in group_ids.items() if path.parent == directory]
 return ','.join(uid(number) for number in children)
obj(3,'isa = PBXGroup; children = ('+group_children(Path('.'))+'); path = DiskUnbloat; sourceTree = "<group>";')
for directory,number in group_ids.items():
 obj(number,'isa = PBXGroup; children = ('+group_children(directory)+'); path = "'+directory.name+'"; sourceTree = "<group>";')
obj(4,'isa = PBXGroup; children = ('+uid(6)+','+uid(41)+','+uid(61)+'); name = Products; sourceTree = "<group>";')
obj(5,'isa = PBXNativeTarget; buildConfigurationList = '+uid(11)+'; buildPhases = ('+uid(7)+','+uid(8)+','+uid(9)+'); buildRules = (); dependencies = (); name = DiskUnbloat; packageProductDependencies = ('+uid(31)+'); productName = DiskUnbloat; productReference = '+uid(6)+'; productType = "com.apple.product-type.application";')
obj(6,'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = DiskUnbloat.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj(7,'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(uid(20000+i) for i in range(len(files)))+'); runOnlyForDeploymentPostprocessing = 0;')
obj(8,'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ('+uid(32)+'); runOnlyForDeploymentPostprocessing = 0;')
obj(9,'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ('+uid(34)+','+uid(36)+','+uid(138)+'); runOnlyForDeploymentPostprocessing = 0;')
obj(10,'isa = XCConfigurationList; buildConfigurations = ('+uid(12)+','+uid(13)+'); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj(11,'isa = XCConfigurationList; buildConfigurations = ('+uid(14)+','+uid(15)+'); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
for n,name in [(12,'Debug'),(13,'Release')]:
 obj(n,f'isa = XCBuildConfiguration; buildSettings = {{ CLANG_ENABLE_MODULES = YES; MACOSX_DEPLOYMENT_TARGET = 26.0; SDKROOT = macosx; SWIFT_VERSION = 6.0; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_OPTIMIZATION_LEVEL = "'+('-Onone' if name=='Debug' else '-O')+'"; ONLY_ACTIVE_ARCH = '+('YES' if name=='Debug' else 'NO')+'; ENABLE_TESTABILITY = '+('YES' if name=='Debug' else 'NO')+'; }; name = '+name+';')
for n,name in [(14,'Debug'),(15,'Release')]:
 obj(n,'isa = XCBuildConfiguration; buildSettings = { ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor; CODE_SIGN_ENTITLEMENTS = DiskUnbloat/App/DiskUnbloat.entitlements; CODE_SIGN_STYLE = Automatic; COMBINE_HIDPI_IMAGES = YES; CURRENT_PROJECT_VERSION = 1; ENABLE_APP_SANDBOX = YES; ENABLE_HARDENED_RUNTIME = YES; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_FILE = DiskUnbloat/App/Info.plist; INFOPLIST_KEY_CFBundleDisplayName = DiskUnbloat; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.utilities"; INFOPLIST_KEY_NSHumanReadableCopyright = "Copyright © 2026 DiskUnbloat"; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks"; MARKETING_VERSION = 1.0; PRODUCT_BUNDLE_IDENTIFIER = com.diskunbloat.app; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_EMIT_LOC_STRINGS = YES; SWIFT_VERSION = 6.0; SWIFT_STRICT_CONCURRENCY = complete; }; name = '+name+';')
obj(40,'isa = PBXNativeTarget; buildConfigurationList = '+uid(42)+'; buildPhases = ('+uid(43)+','+uid(44)+'); buildRules = (); dependencies = ('+uid(47)+'); name = DiskUnbloatUITests; productName = DiskUnbloatUITests; productReference = '+uid(41)+'; productType = "com.apple.product-type.bundle.ui-testing";')
obj(41,'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = DiskUnbloatUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj(42,'isa = XCConfigurationList; buildConfigurations = ('+uid(50)+','+uid(51)+'); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj(43,'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+uid(53)+'); runOnlyForDeploymentPostprocessing = 0;')
obj(44,'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj(46,'isa = PBXContainerItemProxy; containerPortal = '+uid(1)+'; proxyType = 1; remoteGlobalIDString = '+uid(5)+'; remoteInfo = DiskUnbloat;')
obj(47,'isa = PBXTargetDependency; target = '+uid(5)+'; targetProxy = '+uid(46)+';')
obj(48,'isa = PBXGroup; children = ('+uid(52)+'); path = DiskUnbloatUITests; sourceTree = "<group>";')
obj(52,'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DiskUnbloatUITests.swift; sourceTree = "<group>";')
obj(53,'isa = PBXBuildFile; fileRef = '+uid(52)+';')
for n,name in [(50,'Debug'),(51,'Release')]:
 obj(n,'isa = XCBuildConfiguration; buildSettings = { CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = com.diskunbloat.app.uitests; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 6.0; TEST_TARGET_NAME = DiskUnbloat; }; name = '+name+';')
# Hosted presentation tests run without UI automation privileges.
obj(60,'isa = PBXNativeTarget; buildConfigurationList = '+uid(62)+'; buildPhases = ('+uid(63)+','+uid(64)+'); buildRules = (); dependencies = ('+uid(66)+'); name = DiskUnbloatTests; packageProductDependencies = ('+uid(31)+'); productName = DiskUnbloatTests; productReference = '+uid(61)+'; productType = "com.apple.product-type.bundle.unit-test";')
obj(61,'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = DiskUnbloatTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj(62,'isa = XCConfigurationList; buildConfigurations = ('+uid(70)+','+uid(71)+'); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj(63,'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+uid(69)+'); runOnlyForDeploymentPostprocessing = 0;')
obj(64,'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ('+uid(72)+'); runOnlyForDeploymentPostprocessing = 0;')
obj(65,'isa = PBXContainerItemProxy; containerPortal = '+uid(1)+'; proxyType = 1; remoteGlobalIDString = '+uid(5)+'; remoteInfo = DiskUnbloat;')
obj(66,'isa = PBXTargetDependency; target = '+uid(5)+'; targetProxy = '+uid(65)+';')
obj(67,'isa = PBXGroup; children = ('+uid(68)+'); path = DiskUnbloatTests; sourceTree = "<group>";')
obj(68,'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PresentationTests.swift; sourceTree = "<group>";')
obj(69,'isa = PBXBuildFile; fileRef = '+uid(68)+';')
obj(72,'isa = PBXBuildFile; productRef = '+uid(31)+';')
for n,name in [(70,'Debug'),(71,'Release')]:
 obj(n,'isa = XCBuildConfiguration; buildSettings = { BUNDLE_LOADER = "$(TEST_HOST)"; CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = com.diskunbloat.app.tests; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 6.0; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/DiskUnbloat.app/Contents/MacOS/DiskUnbloat"; }; name = '+name+';')
obj(30,'isa = XCLocalSwiftPackageReference; relativePath = Packages/DiskCore;')
obj(31,'isa = XCSwiftPackageProductDependency; package = '+uid(30)+'; productName = DiskCore;')
obj(32,'isa = PBXBuildFile; productRef = '+uid(31)+';')
obj(33,'isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>";')
obj(38,'isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = Localizable.xcstrings; sourceTree = "<group>";')
obj(138,'isa = PBXBuildFile; fileRef = '+uid(38)+';')
obj(39,'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
obj(37,'isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = DiskUnbloat.entitlements; sourceTree = "<group>";')
obj(35,'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
obj(36,'isa = PBXBuildFile; fileRef = '+uid(35)+';')
obj(34,'isa = PBXBuildFile; fileRef = '+uid(33)+';')
(root/'DiskUnbloat.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+uid(1)+'; }\n')
(root/'DiskUnbloat.xcodeproj/xcshareddata/xcschemes/DiskUnbloat.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(5)}" BuildableName="DiskUnbloat.app" BlueprintName="DiskUnbloat" ReferencedContainer="container:DiskUnbloat.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(60)}" BuildableName="DiskUnbloatTests.xctest" BlueprintName="DiskUnbloatTests" ReferencedContainer="container:DiskUnbloat.xcodeproj"/></TestableReference><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(40)}" BuildableName="DiskUnbloatUITests.xctest" BlueprintName="DiskUnbloatUITests" ReferencedContainer="container:DiskUnbloat.xcodeproj"/></TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(5)}" BuildableName="DiskUnbloat.app" BlueprintName="DiskUnbloat" ReferencedContainer="container:DiskUnbloat.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(5)}" BuildableName="DiskUnbloat.app" BlueprintName="DiskUnbloat" ReferencedContainer="container:DiskUnbloat.xcodeproj"/></BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
