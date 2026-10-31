"""Validate catalog completeness; optionally pass a compiler stringsdata directory."""
from pathlib import Path
import json
import re
import sys

root = Path(__file__).resolve().parents[1]
strings = json.loads((root / 'DiskUnbloat/Resources/Localizable.xcstrings').read_text())['strings']
errors = []
for key, entry in strings.items():
    for language in ('en', 'ru'):
        value = entry.get('localizations', {}).get(language, {})
        if not value:
            errors.append(f'{language}: missing {key}')
        plural = value.get('variations', {}).get('plural')
        if plural and not ({'one', 'few', 'many', 'other'} if language == 'ru' else {'one', 'other'}) <= plural.keys():
            errors.append(f'{language}: incomplete plurals for {key}')
        def units(item):
            if 'stringUnit' in item:
                yield item['stringUnit']['value']
            for child in item.values():
                if isinstance(child, dict):
                    yield from units(child)
        expected = sorted(re.findall(r'%(?:\d+\$)?(?:lld|@)', key))
        for text in units(value):
            if sorted(re.findall(r'%(?:\d+\$)?(?:lld|@)', text)) != expected:
                errors.append(f'{language}: incompatible placeholders for {key}')
if len(sys.argv) > 1:
    for path in Path(sys.argv[1]).rglob('*.stringsdata'):
        for row in json.loads(path.read_text()).get('tables', {}).get('Localizable', []):
            if row['key'] not in strings:
                errors.append(f'{path.name}: missing key {row["key"]}')
for path in (root / 'DiskUnbloat').rglob('*.swift'):
    if re.search(r'(?:appendingPathComponent|fileURLWithPath:)\s*\(L10n\.', path.read_text()):
        errors.append(f'{path}: translated filesystem path')
if errors:
    raise SystemExit('\n'.join(sorted(set(errors))))
print(f'Validated {len(strings)} English/Russian catalog entries and stable filesystem paths.')
