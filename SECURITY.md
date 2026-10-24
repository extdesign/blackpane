# Security policy

## Supported versions

Only the latest release gets fixes. Please check that the problem is still there in the
[latest release](https://github.com/extdesign/blackpane/releases/latest) or on `master`.

## Reporting a vulnerability

Please **don't** open a public issue. Report it privately instead:
[Report a vulnerability](https://github.com/extdesign/blackpane/security/advisories/new)
(GitHub → Security → Advisories). Only the maintainer sees the report.

Include the blackpane version (`blackpane version`), the macOS version, what you did and
what happened. You'll get an answer within a few days; a confirmed issue is fixed in a
new release and credited in the advisory unless you ask otherwise.

## What blackpane can and can't do

To help judge whether something is a vulnerability:

- It runs as your user, from your login session, with no root privileges and no network
  access.
- It needs **Input Monitoring**, and uses it only to listen to modifier keys, mouse
  buttons and scrolling; it never reads or stores what you type, and the event tap only
  listens — it can't change or inject events.
- It writes only to `~/Library/Logs/blackpane.log`, `~/Library/Application
  Support/blackpane/` and one file in your temporary folder.
- It turns the built-in display off and on with a private macOS API
  (`CGSConfigureDisplayEnabled`).
