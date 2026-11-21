#!/usr/bin/env python3
"""Keep Xcode from opening the local Swift package as a plain folder.

XcodeGen currently emits `folder`; Xcode then refuses to load the same path
as a Swift Package Dependency. `wrapper` preserves native package navigation.
The hook is idempotent and only touches our local package's navigator entry.
"""
from pathlib import Path
import re

project = Path(__file__).resolve().parent.parent / 'LiveKitObserver.xcodeproj/project.pbxproj'
original = project.read_text()
updated = re.sub(
    r'(?m)^([^\n]*isa = PBXFileReference;[^\n]*path = Packages/ObserverCore;[^\n]*)$',
    lambda match: match[0].replace('lastKnownFileType = folder;', 'lastKnownFileType = wrapper;'),
    original,
)
if updated != original:
    project.write_text(updated)
