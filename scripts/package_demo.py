"""Package the Flutter browser build and a clean source download."""
from pathlib import Path
import shutil
import zipfile

root = Path(__file__).resolve().parent.parent
output = root / 'dist'
if output.exists():
    shutil.rmtree(output)
shutil.copytree(root / 'build/web', output)
source_files = []
for folder in ('lib', 'assets', 'test', 'web', 'scripts', '.github'):
    source_files.extend(p for p in (root / folder).rglob('*') if p.is_file())
source_files.extend(root / name for name in ('pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', 'README.md', '.gitignore', '.metadata'))
source_files.extend((root / 'docs').glob('*.md'))
with zipfile.ZipFile(output / 'paul-demo-source.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(source_files):
        archive.write(file, Path('paul-demo') / file.relative_to(root))
print('Packaged Flutter preview and source download.')
