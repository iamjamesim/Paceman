#!/usr/bin/env python3
"""Generate a dependency-free Xcode project; safe to rerun after adding Swift files."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import shutil

root = Path(__file__).resolve().parents[1] / "ios"
objects = {}
# Preserve user-selected signing settings when regenerating on the Mac.
previous_settings = {}
existing_project = root / "AgentCompanion.xcodeproj/project.pbxproj"
if existing_project.exists() and shutil.which("plutil"):
    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(existing_project)], capture_output=True, text=True)
    if result.returncode == 0:
        previous_settings = json.loads(result.stdout).get("objects", {})


def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


class Ref(str):
    pass


def add(name, value):
    key = ident(name)
    objects[key] = value
    return Ref(key)


def encode(value):
    if isinstance(value, Ref): return value
    if isinstance(value, str): return json.dumps(value)
    if isinstance(value, int): return str(value)
    if isinstance(value, list): return "(" + ", ".join(encode(v) for v in value) + ")"
    return "{\n" + "\n".join(f"{json.dumps(k)} = {encode(v)};" for k, v in value.items()) + "\n}"


groups, targets, products = [], [], []
for name in ["AgentCompanion", "AgentCompanionTests", "AgentCompanionWidgets"]:
    files, builds, resources = [], [], []
    test = name.endswith("Tests")
    widget = name.endswith("Widgets")
    paths = sorted((root / name).glob("*.swift"))
    if not test: paths += sorted((root / "Shared").glob("*.swift"))
    for path in paths:
        ref = add(name + "/ref/" + str(path.relative_to(root)), {"isa": "PBXFileReference", "lastKnownFileType": "sourcecode.swift",
                                              "path": path.name if path.parent.name == name else "../Shared/" + path.name, "sourceTree": "<group>"})
        files.append(ref)
        builds.append(add("build/" + name + "/" + str(path.relative_to(root)), {"isa": "PBXBuildFile", "fileRef": ref}))
    if not test:
        for path in sorted((root / "Resources").glob("*")):
            if path.suffix not in (".ttf", ".txt") and path.suffix != ".xcassets": continue
            typ = "folder.assetcatalog" if path.suffix == ".xcassets" else "file"
            ref = add(name + "/resource/" + path.name, {"isa": "PBXFileReference", "lastKnownFileType": typ,
                "path": "../Resources/" + path.name, "sourceTree": "<group>"})
            files.append(ref)
            resources.append(add(name + "/resource-build/" + path.name, {"isa": "PBXBuildFile", "fileRef": ref}))
    groups.append(add(name + "/group", {"isa": "PBXGroup", "children": files, "path": name, "sourceTree": "<group>"}))
    source_phase = add(name + "/sources", {"isa": "PBXSourcesBuildPhase", "buildActionMask": 2147483647,
                      "files": builds, "runOnlyForDeploymentPostprocessing": 0})
    framework_phase = add(name + "/frameworks", {"isa": "PBXFrameworksBuildPhase", "buildActionMask": 2147483647,
                         "files": [], "runOnlyForDeploymentPostprocessing": 0})
    resource_phase = add(name + "/resources", {"isa": "PBXResourcesBuildPhase", "buildActionMask": 2147483647,
                        "files": resources, "runOnlyForDeploymentPostprocessing": 0})
    test = name.endswith("Tests")
    product = add(name + "/product", {"isa": "PBXFileReference", "explicitFileType": "wrapper.cfbundle" if test else "wrapper.app-extension" if widget else "wrapper.application",
                  "includeInIndex": 0, "path": name + (".xctest" if test else ".appex" if widget else ".app"), "sourceTree": "BUILT_PRODUCTS_DIR"})
    products.append(product)
    configs = []
    for config in ["Debug", "Release"]:
        settings = {"PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "com.apselabs.agentcompanion.prototype" + (".tests" if test else ".widgets" if widget else ""),
                    "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "18.0", "TARGETED_DEVICE_FAMILY": "1",
                    "CODE_SIGN_STYLE": "Automatic", "SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                    "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if config == "Debug" else "",
                    "ENABLE_TESTABILITY": "YES" if config == "Debug" else "NO",
                    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
                    "GENERATE_INFOPLIST_FILE": "YES" if test else "NO"}
        if test:
            settings.update({"TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AgentCompanion.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/AgentCompanion",
                             "BUNDLE_LOADER": "$(TEST_HOST)"})
        elif widget:
            settings.update({"INFOPLIST_FILE": "AgentCompanionWidgets/Info.plist", "CODE_SIGN_ENTITLEMENTS": "AgentCompanionWidgets/AgentCompanionWidgets.entitlements",
                "APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES", "DEVELOPMENT_TEAM": "CF5Q5833P7",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"]})
        else:
            settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
            settings["INFOPLIST_FILE"] = "AgentCompanion/Info.plist"
            settings["APNS_ENVIRONMENT"] = "development" if config == "Debug" else "production"
            settings["CODE_SIGN_ENTITLEMENTS"] = "AgentCompanion/AgentCompanion.entitlements"
        old = previous_settings.get(ident(name + "/" + config), {}).get("buildSettings", {})
        for key in ["DEVELOPMENT_TEAM", "PRODUCT_BUNDLE_IDENTIFIER", "CODE_SIGN_STYLE", "PROVISIONING_PROFILE_SPECIFIER"]:
            if key in old:
                settings[key] = old[key]
        configs.append(add(name + "/" + config, {"isa": "XCBuildConfiguration", "buildSettings": settings, "name": config}))
    config_list = add(name + "/configs", {"isa": "XCConfigurationList", "buildConfigurations": configs,
                      "defaultConfigurationIsVisible": 0, "defaultConfigurationName": "Release"})
    deps = []
    if test:
        proxy = add("test/proxy", {"isa": "PBXContainerItemProxy", "containerPortal": Ref(ident("project")),
                    "proxyType": 1, "remoteGlobalIDString": Ref(ident("AgentCompanion/target")), "remoteInfo": "AgentCompanion"})
        deps.append(add("test/dependency", {"isa": "PBXTargetDependency", "target": Ref(ident("AgentCompanion/target")), "targetProxy": proxy}))
    phases = [source_phase, framework_phase, resource_phase]
    if not test and not widget:
        proxy = add("widget/proxy", {"isa": "PBXContainerItemProxy", "containerPortal": Ref(ident("project")),
            "proxyType": 1, "remoteGlobalIDString": Ref(ident("AgentCompanionWidgets/target")), "remoteInfo": "AgentCompanionWidgets"})
        deps.append(add("widget/dependency", {"isa": "PBXTargetDependency", "target": Ref(ident("AgentCompanionWidgets/target")), "targetProxy": proxy}))
        embed = add("widget/embed-build", {"isa": "PBXBuildFile", "fileRef": Ref(ident("AgentCompanionWidgets/product")), "settings": {"ATTRIBUTES": ["RemoveHeadersOnCopy"]}})
        phases.append(add("widget/embed-phase", {"isa": "PBXCopyFilesBuildPhase", "buildActionMask": 2147483647, "dstPath": "", "dstSubfolderSpec": 13, "files": [embed], "name": "Embed App Extensions", "runOnlyForDeploymentPostprocessing": 0}))
    targets.append(add(name + "/target", {"isa": "PBXNativeTarget", "buildConfigurationList": config_list,
                       "buildPhases": phases, "buildRules": [], "dependencies": deps,
                       "name": name, "productName": name, "productReference": product,
                       "productType": "com.apple.product-type.bundle.unit-test" if test else "com.apple.product-type.app-extension" if widget else "com.apple.product-type.application"}))

product_group = add("products", {"isa": "PBXGroup", "children": products, "name": "Products", "sourceTree": "<group>"})
main_group = add("main", {"isa": "PBXGroup", "children": groups + [product_group], "sourceTree": "<group>"})
configs = []
for config in ["Debug", "Release"]:
    configs.append(add("project/" + config, {"isa": "XCBuildConfiguration", "name": config,
        "buildSettings": {"CLANG_ENABLE_MODULES": "YES", "SWIFT_STRICT_CONCURRENCY": "minimal",
                          "DEBUG_INFORMATION_FORMAT": "dwarf", "ONLY_ACTIVE_ARCH": "YES" if config == "Debug" else "NO"}}))
config_list = add("project/configs", {"isa": "XCConfigurationList", "buildConfigurations": configs,
    "defaultConfigurationIsVisible": 0, "defaultConfigurationName": "Release"})
project = add("project", {"isa": "PBXProject", "attributes": {"LastUpgradeCheck": "1600", "BuildIndependentTargetsInParallel": "YES"},
    "buildConfigurationList": config_list, "compatibilityVersion": "Xcode 14.0", "developmentRegion": "en",
    "hasScannedForEncodings": 0, "knownRegions": ["en", "Base"], "mainGroup": main_group,
    "productRefGroup": product_group, "projectDirPath": "", "projectRoot": "", "targets": targets})
project_dir = root / "AgentCompanion.xcodeproj"
project_dir.mkdir(exist_ok=True)
document = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}
(project_dir / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(document) + "\n")

scheme_dir = project_dir / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
def build_ref(name):
    ext = ".xctest" if name.endswith("Tests") else ".app"
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(name + "/target")}" BuildableName="{name}{ext}" BlueprintName="{name}" ReferencedContainer="container:AgentCompanion.xcodeproj"/>'
(scheme_dir / "AgentCompanion.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{build_ref("AgentCompanion")}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{build_ref("AgentCompanionTests")}</TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{build_ref("AgentCompanion")}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{build_ref("AgentCompanion")}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
info = {"CFBundleDevelopmentRegion": "en", "CFBundleDisplayName": "Paceman",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "Paceman", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2", "LSRequiresIPhoneOS": True,
        "NSSupportsLiveActivities": True, "UILaunchScreen": {}, "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        "UIBackgroundModes": ["bluetooth-central", "remote-notification", "fetch"],
        "APNSEnvironment": "$(APNS_ENVIRONMENT)",
        "NSBluetoothAlwaysUsageDescription": "Connect your watch to receive agent updates on your wrist.",
        "NSLocationWhenInUseUsageDescription": "Use your approximate location to show local weather on your watch.",
        "NSLocationDefaultAccuracyReduced": True,
        "NSLocationAlwaysAndWhenInUseUsageDescription": "Keep weather on your watch local as you travel, even when Paceman is closed.",
        "BGTaskSchedulerPermittedIdentifiers": ["com.apselabs.agentcompanion.weather"],
        "NSCameraUsageDescription": "Scan a pairing invitation from your work computer.",
        "NSAccessorySetupKitSupports": ["Bluetooth"],
        "NSAccessorySetupBluetoothServices": ["7F510001-1B15-4F0D-B7A5-4CF3A2C98EE1"],
        "NSAccessorySetupBluetoothNames": ["Watch"]}
info["UIAppFonts"] = ["JetBrainsMono-Regular.ttf", "JetBrainsMono-SemiBold.ttf"]
info["CFBundleURLTypes"] = [{"CFBundleURLName": "companion", "CFBundleURLSchemes": ["agentcompanion"]}]
widget_info = {"CFBundleDevelopmentRegion": "en", "CFBundleDisplayName": "Paceman",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "Paceman", "CFBundlePackageType": "XPC!",
    "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2", "UIAppFonts": info["UIAppFonts"],
    "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}}
with (root / "AgentCompanionWidgets/Info.plist").open("wb") as file: plistlib.dump(widget_info, file)
for name in ("AgentCompanion", "AgentCompanionWidgets"):
    entitlement = {"com.apple.security.application-groups": ["group.com.apselabs.agentcompanion.prototype"]}
    if name == "AgentCompanion":
        entitlement["aps-environment"] = "$(APNS_ENVIRONMENT)"
        entitlement["com.apple.developer.weatherkit"] = True
    with (root / name / (name + ".entitlements")).open("wb") as file: plistlib.dump(entitlement, file)
with (root / "AgentCompanion/Info.plist").open("wb") as file:
    plistlib.dump(info, file)
print("Created ios/AgentCompanion.xcodeproj (no package dependencies)")
