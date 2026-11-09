"""Package the browser preview and optionally a separate source archive."""

import argparse
from pathlib import Path
import shutil
import subprocess
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--include-source',
    action='store_true',
    help='Write a tracked-source archive to build/, outside the browser preview.',
)
args = parser.parse_args()

root = Path(__file__).resolve().parent.parent
output = root / 'dist'
if output.exists():
    shutil.rmtree(output)
shutil.copytree(root / 'build/web', output)
print('Packaged Flutter browser preview in dist/.')

if args.include_source:
    allowed_paths = (
        'lib', 'assets', 'test', 'web', 'scripts',
        'pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml',
        '.gitignore', '.metadata',
    )
    tracked = subprocess.check_output(
        ['git', 'ls-files', '-z', '--', *allowed_paths], cwd=root,
    )
    source_archive = root / 'build/paul-demo-source.zip'
    with zipfile.ZipFile(source_archive, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(tracked.decode('utf-8').split('\0')):
            if not name:
                continue
            file = root / name
            if file.is_symlink():
                continue
            archive.write(file, Path('paul-demo') / name)
    print('Packaged tracked source in build/paul-demo-source.zip.')
