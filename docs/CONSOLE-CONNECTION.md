# Console connection candidate (0.7.0, build 9)

Use **Connect to Console** at the bottom of the sidebar, or **Workspace → Console
Connection**. The app opens the console through macOS's browser authentication
session. Sign in, explicitly choose a workspace and approve the connection, then
return to the app. Local vault work continues to require no account.

This first step connects an account only. It does not sync vault files,
checkpoints, policy revisions or reviews. The screen reports that limit explicitly.

The connection uses state and S256 PKCE, a fixed callback and HTTPS API origin,
single-use authorization codes, and a narrow 30-day device credential. The token
is stored in Keychain with synchronization disabled and device-only accessibility.
No general API key or browser cookie is stored in the app. Requests refuse
redirects. **Check Connection** verifies the current server status; **Disconnect**
revokes remotely before deleting the Keychain entry. Failed disconnects retain the
credential for retry. Expired connections can be disconnected and created again.

Server counterpart: Planisphere API branch `codex/mac-console-connection-2026-10-10`,
starting from approved console repair `e17f222`, with migration `0040_mac_connections`.
It must be released before the production-origin Mac candidate can connect.

Local verification: 75 XCTest and 13 Swift Testing checks passed, including callback
state/destination validation, PKCE test vector, rejected redirects and failed
disconnect behavior. Release packaging and strict ad-hoc signature verification
passed. The connection sheet was inspected in a separate app identity with an
empty disposable history directory. The running 0.6.1 app was not replaced.

Pending release acceptance: the real email/browser callback, Keychain persistence
after relaunch, remote revocation and disconnected/offline behavior against the
released server. This is a tested local candidate, not proof of production pairing
or notarized distribution. See [release preparation](release.md). The empty-vault
startup incident remains a separate unresolved cause.
