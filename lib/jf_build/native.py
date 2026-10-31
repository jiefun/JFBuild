"""处理工程信息、plist、描述文件和 IPA。"""
import base64
import datetime
import json
import pathlib
import plistlib
import subprocess
import sys
import zipfile
import xml.etree.ElementTree as ET


def decode_profile(data):
    result = subprocess.run(
        ['/usr/bin/openssl', 'smime', '-verify', '-noverify', '-inform', 'DER'],
        input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
    return plistlib.loads(result.stdout)


def project_options(root, selected=''):
    root = pathlib.Path(root)
    workspaces = sorted(path.name for path in root.glob('*.xcworkspace') if path.is_dir())
    projects = sorted(path.name for path in root.glob('*.xcodeproj') if path.is_dir())
    if not selected:
        candidates = workspaces or projects
        selected = candidates[0] if len(candidates) == 1 else ''
    containers = [root / selected] if selected else [root / name for name in workspaces or projects]
    scheme_files = set()
    project_paths = set()
    for container in containers:
        if container.suffix == '.xcodeproj':
            project_paths.add(container)
            continue
        scheme_files.update(container.glob('xcshareddata/xcschemes/*.xcscheme'))
        try:
            workspace = ET.parse(container / 'contents.xcworkspacedata').getroot()
        except (OSError, ET.ParseError):
            continue

        def visit(node, base):
            location = node.get('location', '')
            kind, separator, value = location.partition(':')
            value = value if separator else location
            anchor = container.parent if kind == 'container' else base
            path = anchor / value
            if node.tag == 'FileRef' and path.suffix == '.xcodeproj':
                project_paths.add(path)
            for child in node:
                visit(child, path if node.tag == 'Group' and location else base)

        visit(workspace, container.parent)
    project_paths = {project for project in project_paths if project.name != 'Pods.xcodeproj'}
    for project in project_paths:
        scheme_files.update(project.glob('xcshareddata/xcschemes/*.xcscheme'))
    for container in set(containers) | project_paths:
        scheme_files.update(container.glob('xcuserdata/*/xcschemes/*.xcscheme'))
    schemes = set()
    defined_schemes = set()
    for path in scheme_files:
        try:
            entries = ET.parse(path).getroot().findall('./BuildAction/BuildActionEntries/BuildActionEntry')
        except (OSError, ET.ParseError):
            continue
        defined_schemes.add(path.stem)
        if any(entry.get('buildForArchiving', 'YES') != 'NO' and
               any(ref.get('BuildableName', '').endswith('.app') for ref in entry.findall('BuildableReference'))
               for entry in entries):
            schemes.add(path.stem)
    if selected:
        try:
            flag = '-workspace' if pathlib.Path(selected).suffix == '.xcworkspace' else '-project'
            result = subprocess.run(
                ['xcodebuild', flag, selected, '-list', '-json'], cwd=root,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True, timeout=30)
            info = json.loads(result.stdout)
            available = set(info[flag[1:]]['schemes'])
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
            available = None
        if available is not None:
            # Xcode 自动生成的 Scheme 没有 XML 文件，按 App Target 识别并核对可用列表。
            for project in project_paths:
                try:
                    result = subprocess.run(
                        ['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(project / 'project.pbxproj')],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
                    objects = json.loads(result.stdout)['objects'].values()
                except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
                    continue
                schemes.update(target['name'] for target in objects
                               if target.get('isa') == 'PBXNativeTarget'
                               and target.get('productType') == 'com.apple.product-type.application'
                               and target.get('name') and target['name'] not in defined_schemes)
            schemes.intersection_update(available)
    return {'workspace': workspaces, 'project': projects, 'scheme': sorted(schemes), 'selected': selected}


def main():
    action, *paths = sys.argv[1:]
    if action == 'project-options':
        return project_options(paths[0], paths[1] if len(paths) > 1 else '')
    if action == 'read-plist':
        return plistlib.loads(pathlib.Path(paths[0]).read_bytes())
    if action == 'write-plist':
        pathlib.Path(paths[0]).write_bytes(plistlib.dumps(json.load(sys.stdin)))
        return True
    if action == 'read-profile':
        return decode_profile(sys.stdin.buffer.read())
    with zipfile.ZipFile(paths[0]) as ipa:
        names = ipa.namelist()
        # 校验路径后解压；zipfile 将符号链接保存为普通文件。
        for name in names:
            parts = name.replace('\\', '/').split('/')
            if name.startswith('/') or '..' in parts or '\\' in name:
                raise ValueError('unsafe IPA path')
        mains = [name for name in names if len(name.split('/')) == 3
                 and name.startswith('Payload/') and name.split('/')[1].endswith('.app')
                 and name.endswith('/Info.plist')]
        if len(mains) != 1:
            raise ValueError('IPA requires one main app')
        if action == 'ipa-info':
            return plistlib.loads(ipa.read(mains[0]))
        if action == 'extract-ipa':
            ipa.extractall(paths[1])
            return True
        if action == 'ipa-profiles':
            main = mains[0].replace('Info.plist', 'embedded.mobileprovision')
            profiles = [name for name in names if name.startswith('Payload/')
                        and name.endswith('/embedded.mobileprovision')]
            if profiles.count(main) != 1:
                raise ValueError('IPA requires one main profile')
            return [{'main': name == main, 'profile': decode_profile(ipa.read(name)),
                     'info': plistlib.loads(ipa.read(name.replace('embedded.mobileprovision', 'Info.plist')))}
                    for name in profiles]
        raise ValueError('unknown operation')


def encode_date(value):
    if isinstance(value, datetime.datetime):
        return value.isoformat() + 'Z'
    if isinstance(value, bytes):
        return base64.b64encode(value).decode('ascii')
    raise TypeError('unsupported plist value')


try:
    json.dump(main(), sys.stdout, default=encode_date)
except Exception:
    # 避免异常信息带出文件内容。
    sys.exit(1)
