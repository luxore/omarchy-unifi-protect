# Security policy

## Supported version

Security fixes target the current `main` branch. Omarchy installs and updates
plugins from that branch.

## Report a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/luxore/omarchy-unifi-protect/security/advisories/new).
Do not open a public issue for an unpatched vulnerability.

Include the affected commit, Omarchy version, impact, and a minimal sanitized
reproduction. Do not include API keys, console addresses, camera names or IDs,
RTSPS URLs, private camera images, or other personal data.

## Trust boundary

Omarchy plugins run as unsandboxed code inside the desktop shell. Review the
source before installation. This plugin makes read-only requests to the local
UniFi Protect integration API, stores the API key in Secret Service, and does
not install a service or background job.
