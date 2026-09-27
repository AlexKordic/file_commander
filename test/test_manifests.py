"""Tree comparisons must detect wrong bytes, type, names and raw link text."""
from pathlib import Path
import shutil
import tempfile
from fixture_tool import manifest
from test_results import require

with tempfile.TemporaryDirectory(prefix='fc-manifest-') as directory:
    root = Path(directory)
    source, output = root / "source ' quoted", root / 'output'
    source.mkdir()
    (source / 'empty').mkdir()
    (source / 'line\nUnicode-é').write_bytes(b'\0\xffbinary\0')
    (source / 'dangling').symlink_to("missing ' \n target")
    shutil.copytree(source, output, symlinks=True)
    expected = manifest(source)
    require(manifest(output) == expected, 'valid tree differs')
    (output / 'line\nUnicode-é').write_bytes(b'corrupted')
    require(manifest(output) != expected, 'corruption escaped manifest')
    shutil.copyfile(source / 'line\nUnicode-é', output / 'line\nUnicode-é')
    (output / 'extra').touch()
    require(manifest(output) != expected, 'extra entry escaped manifest')
    (output / 'extra').unlink()
    (output / 'dangling').unlink()
    require(manifest(output) != expected, 'missing link escaped manifest')
    (output / 'dangling').symlink_to('wrong')
    require(manifest(output) != expected, 'wrong link target escaped manifest')
print('PASS binary-safe independent tree manifests')
