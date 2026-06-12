#!/usr/bin/env python3
"""
Add ConfigProfile / ProfileStore / ProfileQRCodec / ProfilesView / ConfigProfileTests
to OmniTAK.xcodeproj/project.pbxproj.

UUIDs are deterministic (hard-coded) so the script is idempotent.
Run from anywhere; uses absolute paths.
"""

import re, sys, os

PBXPROJ = os.path.expanduser(
    "~/Projects/wt-ios-profiles/OmniTAK.xcodeproj/project.pbxproj"
)

# ── New files ─────────────────────────────────────────────────────────────────
# Each entry: (fileref_uuid, buildfile_uuid, display_name, path, is_test)
NEW_FILES = [
    (
        "CF000001A000000000000001",
        "CF000001B000000000000001",
        "ConfigProfile.swift",
        "OmniTAKMobile/Features/Profiles/Models/ConfigProfile.swift",
        False,
    ),
    (
        "CF000002A000000000000001",
        "CF000002B000000000000001",
        "ProfileQRCodec.swift",
        "OmniTAKMobile/Features/Profiles/Services/ProfileQRCodec.swift",
        False,
    ),
    (
        "CF000003A000000000000001",
        "CF000003B000000000000001",
        "ProfileStore.swift",
        "OmniTAKMobile/Features/Profiles/Services/ProfileStore.swift",
        False,
    ),
    (
        "CF000004A000000000000001",
        "CF000004B000000000000001",
        "ProfilesView.swift",
        "OmniTAKMobile/Features/Profiles/Views/ProfilesView.swift",
        False,
    ),
    (
        "CF000005A000000000000001",
        "CF000005B000000000000001",
        "ConfigProfileTests.swift",
        "OmniTAKMobileTests/ConfigProfileTests.swift",
        True,
    ),
]

# ── Anchor anchors ─────────────────────────────────────────────────────────────
# We insert new PBXFileReference entries just before the end of that section.
FILE_REF_SECTION_END = "/* End PBXFileReference section */"

# We insert new PBXBuildFile entries at the start of that section.
BUILD_FILE_SECTION_END = "/* End PBXBuildFile section */"

# Main app Sources build phase UUID (see project.pbxproj grep above)
APP_SOURCES_PHASE_UUID = "A11111111111111111111111000000C1"

# Tests Sources build phase UUID
TESTS_SOURCES_PHASE_UUID = "692AC278500B76F26848B899"

# PBXGroup for OmniTAKMobileTests (to list the test file reference)
TESTS_GROUP_UUID = "1D3ED0E6F3C20B29A5C0C506"

# ── Load ──────────────────────────────────────────────────────────────────────
with open(PBXPROJ, "r") as f:
    content = f.read()

original = content  # keep for diff check

def already_present(uuid: str) -> bool:
    return uuid in content

# ── 1. PBXFileReference entries ───────────────────────────────────────────────
file_ref_inserts = []
for fref, _bf, name, path, _test in NEW_FILES:
    if already_present(fref):
        print(f"  skip (already present): {name}")
        continue
    entry = (
        f"\t\t{fref} /* {name} */ = "
        f"{{isa = PBXFileReference; includeInIndex = 1; "
        f"lastKnownFileType = sourcecode.swift; name = {name}; "
        f"path = {path}; sourceTree = \"<group>\"; }};\n"
    )
    file_ref_inserts.append(entry)

if file_ref_inserts:
    insert_block = "".join(file_ref_inserts)
    content = content.replace(
        FILE_REF_SECTION_END,
        insert_block + FILE_REF_SECTION_END,
        1,
    )

# ── 2. PBXBuildFile entries ───────────────────────────────────────────────────
build_file_inserts = []
for fref, bf, name, _path, _test in NEW_FILES:
    if already_present(bf):
        continue
    entry = (
        f"\t\t{bf} /* {name} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {fref} /* {name} */; }};\n"
    )
    build_file_inserts.append(entry)

if build_file_inserts:
    insert_block = "".join(build_file_inserts)
    content = content.replace(
        BUILD_FILE_SECTION_END,
        insert_block + BUILD_FILE_SECTION_END,
        1,
    )

# ── 3. Add file refs to appropriate PBXGroup ──────────────────────────────────
# Tests group — add ConfigProfileTests.swift fileref
for fref, _bf, name, _path, is_test in NEW_FILES:
    if not is_test:
        continue
    if already_present(fref) and fref in original:
        continue
    # Insert before the Info.plist entry in the tests group
    anchor = "A99C500AFB1B09E55ABEDBBF /* Info.plist */,"
    replacement = f"\t\t\t\t{fref} /* {name} */,\n\t\t\t\t" + anchor
    content = content.replace(anchor, replacement, 1)

# ── 4. Add buildfile refs to Sources build phases ────────────────────────────
# App sources phase
app_src_anchor = "42DCF526B899E93E4340934B /* ADSBPlugin.swift in Sources */,"
app_inserts = []
for fref, bf, name, _path, is_test in NEW_FILES:
    if is_test:
        continue
    if bf in original:
        continue
    app_inserts.append(f"\t\t\t\t\t{bf} /* {name} in Sources */,")

if app_inserts:
    insert_str = "\n".join(app_inserts) + "\n\t\t\t\t\t"
    content = content.replace(
        "\t\t\t\t\t" + app_src_anchor,
        insert_str + app_src_anchor,
        1,
    )

# Tests sources phase
tests_src_anchor = "F831B10A1D135F2E88925F52 /* PluginSDKTests.swift in Sources */,"
tests_inserts = []
for fref, bf, name, _path, is_test in NEW_FILES:
    if not is_test:
        continue
    if bf in original:
        continue
    tests_inserts.append(f"\t\t\t\t\t{bf} /* {name} in Sources */,")

if tests_inserts:
    insert_str = "\n".join(tests_inserts) + "\n\t\t\t\t\t"
    content = content.replace(
        "\t\t\t\t\t" + tests_src_anchor,
        insert_str + tests_src_anchor,
        1,
    )

# ── Write back ────────────────────────────────────────────────────────────────
if content == original:
    print("No changes needed (all UUIDs already present).")
else:
    with open(PBXPROJ, "w") as f:
        f.write(content)
    print("project.pbxproj updated successfully.")
