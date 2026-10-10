#!/usr/bin/env python3
"""Offline pattern scan. Reports locations only, never secret values.

This is not an antivirus or a proof that encoded/custom secrets cannot exist.
Scans current source, reachable local Git blobs and the supplied app ZIP files.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

RULES = {
    'private_key': r'-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----',
    'github_token': r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})\b',
    'openai_key': r'\bsk-(?:(?:proj|svcacct)-)?[A-Za-z0-9_-]{20,}',
    'aws_access_key': r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    'google_api_key': r'\bAIza[A-Za-z0-9_-]{30,}',
    'slack_token': r'\bxox[baprs]-[A-Za-z0-9-]{20,}',
    'stripe_secret': r'\b(?:sk|rk)_live_[A-Za-z0-9]{16,}',
    'credential_literal': r'''(?i)\b(?:api[_-]?key|client[_-]?secret|access[_-]?token|password)\s*["']?\s*[:=]\s*["'][^"'\n]{8,}["']''',
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', action='append', type=Path, default=[])
    parser.add_argument('--git', action='append', type=Path, default=[])
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = root if (root / 'MyAppLauncher.xcodeproj').exists() else root / 'outputs/MyAppLauncher'
    files = set()
    for directory in ['Shared', 'MyAppLauncher', 'MyAppLauncherWidget', 'MyAppLauncher.xcodeproj']:
        files.update(p for p in (source / directory).rglob('*') if p.is_file()
                     and 'xcuserdata' not in p.parts and '.DS_Store' != p.name)
    for directory in ['script', 'Tests']:
        files.update(p for p in (root / directory).rglob('*') if p.is_file())
    files.update(p for p in [source / 'README.md', source / 'Rapport-audit-securite.md', root / 'LICENSE', root / '.gitignore'] if p.is_file())
    findings, scanned = [], 0
    compiled = {name: re.compile(pattern) for name, pattern in RULES.items()}

    def scan(label, data):
        nonlocal scanned
        scanned += 1
        text = data.decode('utf-8', errors='replace')
        for rule, expression in compiled.items():
            for match in expression.finditer(text):
                findings.append({'location': label, 'line': text.count('\n', 0, match.start()) + 1,
                                 'rule': rule, 'value': '[REDACTED]'})

    files.update(p for p in root.glob('.env*') if p.is_file())
    for path in sorted(files):
        scan(str(path.relative_to(root)), path.read_bytes())
    repositories = [root] + args.git
    for repository in repositories:
        if not (repository / '.git').exists():
            continue
        objects = subprocess.check_output(['git', '-C', str(repository), 'rev-list', '--objects', '--all'], text=True)
        for entry in objects.splitlines():
            oid = entry.split(' ', 1)[0]
            kind = subprocess.check_output(['git', '-C', str(repository), 'cat-file', '-t', oid], text=True).strip()
            if kind not in {'blob', 'commit', 'tag'}:
                continue
            data = subprocess.check_output(['git', '-C', str(repository), 'cat-file', '-p', oid])
            scan('git:' + repository.name + ':' + oid, data)
    archives = {}
    for archive in args.archive:
        archives[archive.name] = hashlib.sha256(archive.read_bytes()).hexdigest()
        with zipfile.ZipFile(archive) as bundle:
            for entry in bundle.infolist():
                if not entry.is_dir():
                    scan(archive.name + ':' + entry.filename, bundle.read(entry))
    print(json.dumps({'scanned_files_or_blobs': scanned, 'rules': list(RULES),
                      'findings': findings, 'archive_sha256': archives,
                      'scope': 'Current source/assets/scripts/tests and root dotenv files, reachable Git blobs/commits/tags, decompressed app ZIPs',
                      'limitation': 'Pattern scan only; arbitrary, custom or encoded secrets are not ruled out.'}, indent=2))
    return 1 if findings else 0

if __name__ == '__main__':
    raise SystemExit(main())
