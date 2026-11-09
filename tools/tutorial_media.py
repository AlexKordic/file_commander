#!/usr/bin/env python3
"""FC adapter for narrated tutorial media. See doc/tutorial_recording.md."""
import os
import sys
sys.dont_write_bytecode = True
for key in ('FC_FRESH_BIN', 'FC_NATIVE_RICH_COMPOSE', 'FC_NATIVE_MEASURED_TABLES'):
    os.environ.pop(key, None)
from tutorial_media.cli import main

if __name__ == '__main__':
    main()
