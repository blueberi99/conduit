# Third-party notices

Conduit is licensed under the GNU Affero General Public License v3.0 or later.
That license covers Conduit's own source code in this repository. It does not
cover separately installed third-party programs.

## WireSock Secure Connect

The Conduit Windows backend requires WireSock Secure Connect for WireGuard
tunneling, per-application traffic filtering, and network-lock functionality.
WireSock is a separate, mostly proprietary product supplied by the WireSock
Foundation. It is not bundled with Conduit's source code or release artifacts.

When WireSock is missing, Conduit's Windows installer can ask Windows Package
Manager (`winget`) to obtain it from the `NTKERNEL.WireSockVPNClient` package.
The installer displays a notice and requires the user to type `ACCEPT` before
passing package-agreement acceptance to winget. That confirmation means the
user has chosen to install WireSock under WireSock's own terms; it does not
change Conduit's AGPL license.

According to the vendor's current terms:

- the free edition is limited to personal, educational, and non-profit use;
- commercial use requires a separate WireSock license; and
- the free edition includes crash-reporting or diagnostic telemetry.

Review the current vendor terms before installing or redistributing software
that depends on WireSock:

- WireSock EULA: <https://www.wiresock.net/license/wiresock_eula>
- WireSock SDK and licensing: <https://www.wiresock.net/wiresock-sdk>

Conduit does not grant rights to WireSock, its drivers, or its libraries. Do
not add WireSock binaries to Conduit source archives or release packages unless
you have obtained separate permission from the WireSock rights holder.
