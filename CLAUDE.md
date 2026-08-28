# UniFi Protect Viewer development

## Quick start

```bash
omarchy plugin validate .
python3 -m unittest discover -s test -v
test/lint
```

## Architecture

- `ProtectWidget.qml` is the Omarchy bar and popup surface.
- `ProtectPreferences.qml` owns user preferences; `ProtectSetup.qml` owns the
  connection and credential workflow.
- `bin/omarchy-protect` is the only process boundary used by QML.
- `omarchy_protect/client.py` owns URL validation, Secret Service, HTTP,
  snapshot files, and the `mpv` handoff.
- `manifest.json` is the public Omarchy plugin contract.

The plugin uses only the official read-only Protect integration endpoints. Do
not add session-cookie authentication, reverse-engineered APIs, background
services, stream creation, controls, or camera polling while the popup is
closed.

## Security invariants

- API keys travel over QML process standard input and live only in Secret
  Service.
- Every remote string rendered by QML uses `Text.PlainText`.
- Credentialed HTTP redirects remain on the configured origin.
- Runtime frames require `XDG_RUNTIME_DIR`, use an owner-only directory, and
  are atomically replaced with mode `0600`.
- RTSPS URLs enter `mpv` or FFmpeg through anonymous pipes, never process
  arguments.
- Closing the popup terminates snapshot work.

## Release

Keep `manifest.json`, the README release badge, and CLI behavior aligned. Run
the full quick-start gate and verify the real popup before committing. Public
repository creation, pushing, workstation installation, and marketplace issue
creation are separate approval-gated actions.
