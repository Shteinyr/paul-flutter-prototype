"""Regression checks for browser/source artifact separation."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


class PackageDemoTest(unittest.TestCase):
    def setUp(self):
        source_root = Path(__file__).resolve().parent.parent
        self.temp = tempfile.TemporaryDirectory(
            prefix='.package-demo-test-', dir=source_root,
        )
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        files = {
            'build/web/index.html': '<html>preview</html>',
            'dist/paul-demo-source.zip': 'old source download',
            'lib/main.dart': 'void main() {}',
            'lib/untracked.dart': 'local scratch file',
            'assets/fonts/OFL.txt': 'font license',
            'pubspec.yaml': 'name: example',
            'docs/private.md': 'private project document',
            'client/OFFER.md': 'commercial context',
            '.env': 'PRIVATE_TEST_VALUE=sentinel',
        }
        for name, content in files.items():
            file = self.root / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(content)
        (self.root / 'scripts').mkdir()
        shutil.copy(source_root / 'scripts/package_demo.py', self.root / 'scripts')
        (self.root / 'assets/private-link').symlink_to('../docs/private.md')
        subprocess.run(['git', 'init', '-q', self.root], check=True)
        subprocess.run(
            ['git', 'add', 'lib/main.dart', 'assets', 'pubspec.yaml',
             'scripts', 'docs', 'client', '.env'],
            cwd=self.root, check=True,
        )

    def package(self, *args):
        subprocess.run(
            [sys.executable, 'scripts/package_demo.py', *args],
            cwd=self.root, check=True, capture_output=True, text=True,
        )

    def test_default_preview_removes_previous_source_download(self):
        self.package()
        self.assertEqual(
            [file.name for file in (self.root / 'dist').iterdir()],
            ['index.html'],
        )
        self.assertFalse((self.root / 'build/paul-demo-source.zip').exists())

    def test_explicit_source_archive_contains_only_allowed_tracked_files(self):
        self.package('--include-source')
        with zipfile.ZipFile(self.root / 'build/paul-demo-source.zip') as archive:
            self.assertEqual(set(archive.namelist()), {
                'paul-demo/lib/main.dart',
                'paul-demo/assets/fonts/OFL.txt',
                'paul-demo/pubspec.yaml',
                'paul-demo/scripts/package_demo.py',
            })
        self.assertFalse((self.root / 'dist/paul-demo-source.zip').exists())


if __name__ == '__main__':
    unittest.main()
