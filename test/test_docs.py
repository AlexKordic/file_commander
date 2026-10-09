"""Documentation must cover every command and Lua function, and its links must resolve."""
from pathlib import Path
import re
import sys
from test_results import require

root = Path(__file__).resolve().parent.parent
documents = sorted({*root.glob('*.md'), *root.glob('doc/**/*.md'), *root.glob('dependencies/*.md'),
                    *root.glob('boost/*.md'), *root.glob('.github/*.md')})


def prose(text):
    """Markdown without fenced code blocks, where link syntax is literal."""
    return re.sub(r'^```.*?^```', '', text, flags=re.M | re.S)


def anchors(path):
    slugs, seen = set(), {}
    for heading in re.findall(r'^#{1,6}\s+(.+?)\s*#*$', prose(path.read_text()), flags=re.M):
        heading = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', heading)
        slug = re.sub(r'[^\w\- ]', '', heading.lower()).replace(' ', '-')
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        slugs.add(slug if count == 0 else f'{slug}-{count}')
    return slugs


broken = []
for document in documents:
    text = re.sub(r'`[^`\n]*`', '', prose(document.read_text()))
    for target in re.findall(r'\]\(([^)\s]+)(?:\s+"[^"]*")?\)', text):
        if re.match(r'[a-z]+:', target):
            continue
        file_part, _, anchor = target.partition('#')
        linked = (document.parent / file_part).resolve() if file_part else document
        if not linked.exists():
            broken.append(f'{document.relative_to(root)}: missing {target}')
        elif anchor and linked.suffix == '.md' and anchor not in anchors(linked):
            broken.append(f'{document.relative_to(root)}: missing anchor {target}')
require(not broken, 'broken documentation links:\n' + '\n'.join(broken))

commands = re.findall(r'available\.push_back\(\{"([a-z_]+)"', (root / 'commands.cpp').read_text())
require(len(commands) > 20, 'command catalog was not found in commands.cpp')
keys = (root / 'doc/keys.md').read_text()
missing = [command for command in commands if f'`{command}`' not in keys]
require(not missing, 'commands missing from doc/keys.md: ' + ', '.join(missing))

functions = re.findall(r'\breg\("([a-z_]+)"', (root / 'scripting.cpp').read_text())
functions += re.findall(r'^fc\.([a-z_]+)\s*=', (root / 'fc_framework.lua').read_text(), flags=re.M)
require(len(functions) > 10, 'Lua function registrations were not found')
scripting = (root / 'doc/scripting.md').read_text()
missing = sorted({name for name in functions if not re.search(rf'\bfc\.{name}\b', scripting)})
require(not missing, 'Lua functions missing from doc/scripting.md: ' + ', '.join(missing))

print(f'PASS {len(documents)} documents, {len(commands)} commands, {len(set(functions))} Lua functions')
sys.exit(0)
