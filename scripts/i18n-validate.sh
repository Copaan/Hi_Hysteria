#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json
import pathlib
import re
import sys
root = pathlib.Path('server/i18n')
base = json.loads((root / 'en.json').read_text(encoding='utf-8'))
errors = []
def placeholders(text):
    return [p for p in re.findall(r'%(?:%|s|d)', text) if p != '%%']
for file in sorted(root.glob('*.json')):
    data = json.loads(file.read_text(encoding='utf-8'))
    missing, extra = base.keys() - data.keys(), data.keys() - base.keys()
    if missing or extra:
        errors.append(f'{file}: missing={sorted(missing)}, extra={sorted(extra)}')
    for key in base.keys() & data.keys() - {'_meta'}:
        if placeholders(base[key]) != placeholders(data[key]):
            errors.append(f'{file}: placeholder mismatch in {key}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('All translation files and ordered placeholders are consistent.')
PY
