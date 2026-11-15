#!/usr/bin/env python3
"""Checks that build-app.py keeps this Mac's folders out of a release (no game, no bw_native).

    python3 native/app/tests/release-paths.py

A program linked from an object file made with -g carries, in its symbol table, the path of that
object file: the folder of the Mac that built it. A release is stripped of that map and then
checked for any file that names a folder of the building Mac. This test links a small program that
way, in a temporary folder with a name of its own, and checks that:
  - the folder's name is found in the linked program (so the scan can see such a leak at all);
  - after strip_debug_map and a fresh ad hoc signature the name is gone and the program still runs;
  - files_naming reports a text file that holds the name, and nothing for one that does not;
  - release_path_problems words the finding with the file's place inside the app;
  - private_paths names the home folder and the repository.

Needs the compiler tools of the Mac (xcode-select) and nothing else. Exit status 0 when every
check passes, 1 when one fails.
"""
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_app", HERE / "build-app.py")
build_app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_app)

failures = []


def check(ok, what):
    print(("pass: " if ok else "FAIL: ") + what)
    if not ok:
        failures.append(what)


def run(*args):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit("failed: %s\n%s%s" % (" ".join(str(a) for a in args), p.stdout, p.stderr))
    return p


with tempfile.TemporaryDirectory(prefix="bw-release-paths-") as tmp:
    tmp = Path(tmp).resolve()
    marker = tmp / "folder-of-the-building-mac"
    (marker / "src").mkdir(parents=True)
    app = tmp / "Fake.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (marker / "src" / "hello.c").write_text('#include <stdio.h>\nint main(void) { puts("hello"); return 0; }\n')
    obj = marker / "hello.o"
    run("/usr/bin/clang", "-g", "-c", marker / "src" / "hello.c", "-o", obj)
    exe = app / "Contents" / "MacOS" / "hello"
    run("/usr/bin/clang", obj, "-o", exe)
    folders = [str(marker)]

    before = build_app.files_naming(folders, app)
    check([p for p, _f in before] == [exe],
          "the folder the program was linked in is found in its debug map (%d file(s))" % len(before))

    build_app.strip_debug_map(exe)
    build_app.sign(exe)
    after = build_app.files_naming(folders, app)
    check(not after, "after strip_debug_map no file names the folder (%d left)" % len(after))
    p = subprocess.run([str(exe)], capture_output=True, text=True)
    check(p.returncode == 0 and p.stdout.strip() == "hello", "the stripped, signed program still runs")
    r = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(exe)], capture_output=True, text=True)
    check(r.returncode == 0, "the stripped program's new signature verifies")

    note = app / "Contents" / "Resources" / "note.txt"
    note.parent.mkdir(parents=True)
    note.write_text("built in " + str(marker) + "\n")
    named = build_app.files_naming(folders, app)
    check([p for p, _f in named] == [note], "a text file that holds the folder is reported")
    problems = build_app.release_path_problems(app, folders)
    check(len(problems) == 1 and "Fake.app/Contents/Resources/note.txt" in problems[0]
          and str(marker) in problems[0], "the finding names the file inside the app and the folder")
    note.write_text("built somewhere else\n")
    check(not build_app.files_naming(folders, app), "a file without the folder is not reported")

names = build_app.private_paths(Path("/tmp/some-checkout"))
check(str(Path.home()) in names and str(build_app.REPO) in names and "/tmp/some-checkout" in names,
      "private_paths names the home folder, the repository and the checkouts it is given")

if failures:
    print("%d check(s) failed" % len(failures))
    sys.exit(1)
print("all checks passed")
