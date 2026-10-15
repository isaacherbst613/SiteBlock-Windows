# SiteBlock for Windows

Blocks websites in every browser on a Windows PC, with no browser extension. A blocked site stays blocked until you unblock it, and unblocking needs a password plus a waiting period (30 minutes by default), so you can't undo it on impulse.

## Credit

This is a Windows adaptation of **[SiteBlock by nokal123](https://github.com/nokal123/SiteBlock)**, which does the same thing on macOS. The design comes from that project: hosts file plus browser policies, the password and waiting-period unblock, the waiting period that can't be shortened on impulse, the 48-hour password reset and uninstall, and the lockout after wrong passwords. The code here is a new PowerShell implementation, not a copy of the original Swift code.

## How it works

- **Hosts file:** blocked sites (plus their `www.` and `m.` versions) are pointed at `0.0.0.0` in `C:\Windows\System32\drivers\etc\hosts`. This applies to every browser and app.
- **Browser policies:** blocked sites go into the block lists that Chrome, Edge, Brave and Firefox enforce themselves. These cover every subdomain and can block part of a site, such as `youtube.com/shorts`. Secure DNS (DNS-over-HTTPS) is turned off in those browsers so they can't skip the hosts file.
- **Background task:** a scheduled task running as SYSTEM re-applies both every 2 seconds, undoing hand edits, and carries out unblocks when their wait ends. If it is stopped, Windows starts it again within a minute.

## Install

Double-click **`Install SiteBlock.cmd`** and approve the administrator prompt. The SiteBlock window opens when it finishes, and a **SiteBlock** shortcut is added to the Start menu. The first time you block a site, you choose your SiteBlock password. It can't be shown again, so store it somewhere safe.

## Use

**Window:** type a site or paste a link and press **Block**. **Block common sites...** blocks a checklist of popular social media sites at once. Select a site and press **Unblock...** to start its waiting period; **Keep blocked** cancels a pending unblock.

**Command line** (administrator terminal):

```
siteblock add youtube.com            # first use asks you to choose a password
siteblock add youtube.com/shorts     # add -WholeSite to block the whole site
siteblock unblock youtube.com
siteblock cancel youtube.com
siteblock delay 2h                   # longer applies now; shorter only after the current wait
siteblock status | passwd | recover [cancel] | uninstall [cancel]
```

**Forgotten password:** `siteblock recover` (or **Forgot...**) clears it after 48 hours. Sites stay blocked meanwhile.

**Uninstall:** `siteblock uninstall` (or **Uninstall...**) needs the password and then waits 48 hours, or your waiting period if that is longer. Sites stay blocked until then.

## Limits

- An administrator can always defeat it, for example by stopping the task or editing its saved settings. Countdowns use the system clock, so changing the date skips a wait. For the strongest protection, use a standard (non-administrator) account day to day and let someone else hold the administrator password.
- The hosts file has no wildcards, so other browsers and apps only get the site plus its `www.` and `m.` versions. Blocking part of a site works only in Chrome, Edge, Brave and Firefox.
- A VPN or a proxy that looks up sites remotely gets around the hosts file.
- The adult content filter from the macOS version is not included.

## Development

`test.ps1` checks site-name handling, hosts file rewriting and the password lockout:

```
powershell -ExecutionPolicy Bypass -File test.ps1
```
