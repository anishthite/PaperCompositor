# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Anish Thite
"""Check build guards without compiling, downloading assets, or launching the app."""
import os
from pathlib import Path
import subprocess
import tempfile

script = Path(__file__).resolve().parents[1] / "scripts/build.sh"
with tempfile.TemporaryDirectory() as directory:
    env = dict(os.environ, PAPER_COMPOSITOR_BUILD_DIR=directory, PAPER_TEXTURE=f"{directory}/missing.png")
    result = subprocess.run([str(script), "--unknown"], env=env, capture_output=True, text=True)
    assert result.returncode == 2 and "Unknown option" in result.stderr
    result = subprocess.run([str(script), "--self-check", "--advanced"], env=env, capture_output=True, text=True)
    assert result.returncode == 2 and "must be used alone" in result.stderr
    result = subprocess.run([str(script), "--reading"], env=env, capture_output=True, text=True)
    assert result.returncode == 1 and "Paper PNG missing" in result.stderr
    executable = Path(directory) / "PaperCompositor.app/Contents/MacOS/PaperCompositor"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"test")
    with executable.open("rb"):
        result = subprocess.run([str(script), "--build-only"], env=env, capture_output=True, text=True)
        assert result.returncode == 1 and "before overwriting" in result.stderr
    result = subprocess.run([str(script), "--build-only"], env=env, capture_output=True, text=True)
    assert result.returncode == 1 and "Paper PNG missing" in result.stderr
print("PASS: build argument, missing-asset, and in-use executable guards")
