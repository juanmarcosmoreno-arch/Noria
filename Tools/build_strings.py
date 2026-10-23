#!/usr/bin/env python3
"""Regenerates App/Resources/Localizable.xcstrings from the Swift sources.

Extracts user-facing string literals (SwiftUI LocalizedStringKey literals and
String(localized:)) from App/**/*.swift, converts interpolations to format
specifiers and attaches the Spanish translations from translations_es.py.
Exits with an error listing any string that has no translation.
"""
import glob, json, os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from translations_es import ES

ROOT = os.path.join(os.path.dirname(__file__), '..')
INT_INTERPOLATIONS = re.compile(r'(Days|\.phase)$')
NOT_UI = re.compile(r'^[a-z0-9.\-]+$')  # SF Symbols, identifiers
IGNORED = {'', ' ', ' · ', '—', 'MB', 'r', 'macOS'}

def keys():
    found = set()
    literal = re.compile(r'"((?:[^"\\]|\\.)*)"')
    for path in glob.glob(os.path.join(ROOT, 'App', '**', '*.swift'), recursive=True):
        for line in open(path, encoding='utf-8'):
            if line.strip().startswith('//'):
                continue
            for match in literal.finditer(line):
                before = line[:match.start()]
                if re.search(r'(systemName:|systemImage:|verbatim:|forKey:|forInfoDictionaryKey:|string:)\s*$', before):
                    continue
                text = match.group(1)
                # Lowercase identifiers are SF Symbol names unless they have a translation.
                if text in IGNORED or (NOT_UI.match(text) and text not in ES):
                    continue
                if text.startswith('x-apple'):
                    continue
                def spec(m):
                    return '%lld' if INT_INTERPOLATIONS.search(m.group(1)) else '%@'
                key = re.sub(r'\\\(((?:[^()]|\([^()]*\))*)\)', spec, text).replace('\\"', '"')
                found.add(key)
    return found

def main():
    found = keys()
    missing = sorted(k for k in found if k not in ES)
    if missing:
        print('Missing Spanish translations:', file=sys.stderr)
        for key in missing:
            print('  ' + json.dumps(key, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    strings = {}
    for key in sorted(found):
        strings[key] = {
            'extractionState': 'manual',
            'localizations': {
                'es': {'stringUnit': {'state': 'translated', 'value': ES[key]}},
            },
        }
    catalog = {'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'}
    out = os.path.join(ROOT, 'App', 'Resources', 'Localizable.xcstrings')
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write('\n')
    print(f'Wrote {len(strings)} strings to {os.path.relpath(out, ROOT)}')

if __name__ == '__main__':
    main()
