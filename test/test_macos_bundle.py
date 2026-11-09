"""Real Mach-O relocation tests; no installed apps or signing identities used."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bundler', ROOT / 'macos/tools/bundle_dylibs.py')
bundler = importlib.util.module_from_spec(spec); spec.loader.exec_module(bundler)


@unittest.skipUnless(sys.platform == 'darwin', 'Mach-O tooling requires macOS')
class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='fc native bundle ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / 'Original app.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'LSMinimumSystemVersion': '14.0'}))

    def library(self, directory, name, source, linked=(), deployment='14.0'):
        directory.mkdir(parents=True, exist_ok=True)
        code = directory / (name + '.c'); code.write_text(source)
        library = directory / ('lib' + name + '.dylib')
        subprocess.run(['/usr/bin/clang', '-dynamiclib', str(code), *map(str, linked),
                        '-mmacosx-version-min=' + deployment,
                        '-Wl,-headerpad_max_install_names', '-Wl,-install_name,' + str(library),
                        '-o', str(library)], check=True, capture_output=True)
        return library

    def executable(self, name, linked):
        source = self.root / (name + '.c')
        source.write_text('extern int answer(void); int main(void) { return answer() == 42 ? 0 : 1; }')
        binary = self.app / 'Contents/MacOS' / name
        subprocess.run(['/usr/bin/clang', str(source), str(linked), '-mmacosx-version-min=14.0', '-Wl,-headerpad_max_install_names',
                        '-o', str(binary)], check=True, capture_output=True)
        return binary

    def test_transitive_libraries_run_after_moving_app_and_removing_original_sources(self):
        external = self.root / 'External sources/lib'
        base = self.library(external, 'base', 'int base(void) { return 40; }')
        top = self.library(external, 'top', 'extern int base(void); int answer(void) { return base() + 2; }', [base])
        (external.parent / 'LICENSE').write_text('Fixture license')
        main = self.executable('consumer', top)
        original_library = top.read_bytes()
        with main.open('rb') as mapped_file:
            previous = mapped_file.read()
            self.assertEqual(bundler.bundle(self.app), ['libbase.dylib', 'libtop.dylib'])
            mapped_file.seek(0)
            self.assertEqual(mapped_file.read(), previous, 'An existing executable mapping was edited')
        self.assertEqual(top.read_bytes(), original_library, 'An external dependency was modified')
        self.assertEqual(bundler.bundle(self.app), ['libbase.dylib', 'libtop.dylib'])
        notice = self.app / 'Contents/Resources/licenses/native-libraries/libtop.dylib/LICENSE'
        self.assertEqual(notice.read_text(), 'Fixture license')
        for path in list((self.app / 'Contents/Frameworks').iterdir()) + [main]:
            self.assertFalse(any(dep.startswith(str(external)) for dep in bundler.dependencies(path)))
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(path)], check=True, capture_output=True)
        moved = self.root / 'Relocated app.app'
        shutil.move(self.app, moved); shutil.rmtree(external.parent)
        subprocess.run([str(moved / 'Contents/MacOS/consumer')], check=True, timeout=5)

    def test_missing_external_library_stops_packaging(self):
        provider = self.library(self.root / 'external', 'provider', 'int answer(void) { return 42; }')
        self.executable('consumer', provider); provider.unlink()
        with self.assertRaises(FileNotFoundError): bundler.bundle(self.app)

    def test_bundle_minimum_matches_a_newer_native_dependency(self):
        provider = self.library(self.root / 'external', 'provider', 'int answer(void) { return 42; }', deployment='15.0')
        self.executable('consumer', provider)
        bundler.bundle(self.app)
        self.assertEqual(plistlib.loads((self.app / 'Contents/Info.plist').read_bytes())['LSMinimumSystemVersion'], '15.0')

    def test_different_libraries_with_the_same_name_are_rejected(self):
        first = self.library(self.root / 'first', 'provider', 'int answer(void) { return 42; }')
        second = self.library(self.root / 'second', 'provider', 'int answer(void) { return 7; }')
        self.executable('first', first); self.executable('second', second)
        with self.assertRaisesRegex(ValueError, 'share a bundle name'): bundler.bundle(self.app)


if __name__ == '__main__': unittest.main()
