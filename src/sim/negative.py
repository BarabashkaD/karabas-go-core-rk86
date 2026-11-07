"""Deliberate faults of the testbenches as unified diffs (docs/integration.md section 12).

A fault is a .patch made with git diff against the repository root. apply_patch copies nothing
itself: the runner first copies the files a patch touches under copy_root, keeping their paths
relative to the repository root, then calls apply_patch, which applies the patch to those
copies with git apply --directory and fails when it does not apply exactly.
"""
import os
import subprocess


def apply_patch(root, copy_root, patch):
    rel = os.path.relpath(copy_root, root).replace(os.sep, '/')
    for extra in (['--check'], []):
        res = subprocess.run(['git', '-C', root, 'apply'] + extra + ['--directory=' + rel, patch],
                             capture_output=True, text=True)
        if res.returncode:
            raise ValueError('patch %s does not apply: %s' % (patch, (res.stderr or res.stdout).strip()))


def patched_files(patch):
    """The repository-relative paths that a patch changes (its +++ b/ lines)."""
    files = []
    with open(patch, encoding='utf-8') as f:
        for line in f:
            if line.startswith('+++ b/'):
                files.append(line[6:].strip())
    return files
