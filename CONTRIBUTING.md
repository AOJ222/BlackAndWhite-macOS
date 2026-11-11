# Contributing

Small, focused changes are easiest to review.

## Not accepted

- Game files, disc images, installers, or files copied from a game disc
- Game executables or DLLs, serials, cracks, or copy-protection bypass material
- Game artwork, music, video, logos, or other copyrighted assets
- Saved games or profiles containing personal information
- Code generated or lifted from the original game unless a maintainer has asked for
  that specific work and its provenance is recorded

If you are unsure whether something is safe to include, open an issue first and ask.

## Contributions

By contributing original work, you agree that it is provided under the project’s MIT
licence for project-authored code. Do not submit work you do not have the right to
share.

Useful checks for app-layer changes:

```sh
native/app/tests/frontdoor.sh
native/app/tests/picture-settings.sh
native/app/tests/settings-app.sh
python3 native/app/tests/icon.py
```

Please say which checks you ran in the pull request. Do not weaken or skip a check to
make it pass; if a check fails for an unrelated reason, say so plainly.
