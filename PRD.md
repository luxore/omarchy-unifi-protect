# UniFi Protect Viewer

## Purpose

UniFi Protect Viewer makes checking a camera a one-click desktop
action. It belongs in the bar because the job is brief and frequent: open the
viewer, switch to the relevant camera, see what is happening, and leave.

The plugin is a viewer, not another security-console implementation. Protect
continues to own recordings, detections, exports, users, camera configuration,
stream creation, and every destructive or privileged action.

## Product contract

- One quiet bar icon opens a focused single-camera surface.
- Viewer, Preferences, and Connection are separate tabs.
- A saved favorite camera is selected every time the popup opens.
- The popup discovers cameras from the supported local Protect integration API.
- One selected camera streams or refreshes snapshots while the popup is
  visible. Closing the popup stops all camera traffic.
- Real-time mode uses one parallel snapshot as its startup preview, then stops
  snapshot work when video begins.
- Camera switching is immediate and does not preload every camera.
- An existing RTSPS feed can play in the popup or open in a tileable `mpv`
  window for low-latency live viewing.
- The plugin never creates, changes, or removes a Protect stream.
- Offline, unauthorized, TLS, malformed-response, and missing-stream states are
  visible and distinct.
- The API key lives only in Secret Service. It never enters shell settings,
  files, URLs, process arguments, logs, or screenshots.

## Supported environment

The first release targets Omarchy 4 and UniFi Protect's official local
integration API. The console must be reachable over the local network or a VPN.
The expected operating envelope is one selected camera using one RTSPS feed or
one snapshot every 0.75 to 2 seconds, with camera discovery performed once
when the popup opens. Real-time startup briefly adds one snapshot request so a
truthful image can appear before video. Camera count does not increase
steady-state traffic.

The runtime uses Python, Secret Service, Qt Multimedia, FFmpeg, `mpv`, and
`xdg-open`.
There is no daemon, service, package installer, account proxy, cloud backend,
or writable plugin data store.

## Non-goals

- Timelines, recorded events, detections, exports, or notifications.
- PTZ, talkback, lights, sirens, doors, microphones, or camera settings.
- Creating RTSPS streams on behalf of the user.
- Remote access that bypasses the user's network and Protect permissions.
- Supporting reverse-engineered Protect endpoints or session-cookie login.
- A thumbnail wall that polls every camera continuously.

## Success evidence

The repository must pass Omarchy manifest validation, unit tests, lint, and a
source-to-sink security review. Acceptance on a real system must prove camera
discovery, snapshot refresh, camera switching, live-stream handoff, popup-close
cancellation, authentication failure, certificate failure, offline cameras,
and shell logs without relevant QML errors.
