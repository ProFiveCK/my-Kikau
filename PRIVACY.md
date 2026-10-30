# Privacy

myKikau runs on your Mac and keeps what it learns there. This document says what it reads, what it stores, and the only cases in which it contacts another computer.

## What it reads

- File names, sizes and dates in the locations it scans: caches, logs, temporary files, the Trash, installed applications and their support files, the folders you choose for duplicate and large-file search, and the startup items of your account. With Full Disk Access it can also see other apps' caches and leftovers; without it, those locations are skipped and reported as unchecked.
- System readings: CPU, memory, disk, network throughput, battery, thermal and GPU figures, read from the operating system without running other programs on a timer.
- On the Network screen (an advanced tool, off by default): interface addresses, DNS servers and, if you allow Location access when asked, the current Wi‑Fi network's name. Location is used for nothing else.

It never opens the contents of your documents, mail, messages, keychains or browser profiles, and never removes them.

## What it stores

- **Settings** in your account's preferences (`com.profiveck.myKikau`).
- **The operation log** at `~/Library/Logs/myKikau/operations.log`: one line for every item myKikau moved, removed, restored, simulated or failed to act on, with its path, size and time. It stays on this Mac, powers History and Put Back, and can be switched off in Settings unless an administrator has required it. Each entry is also written to the macOS unified log (subsystem `com.profiveck.myKikau`, category `audit`) with the path marked private, so an organisation's log collector can gather it.
- **Diagnostics**, only when you choose Save Diagnostics: a text file of settings and counts with no file names or paths from your disk, for you to send if you ask for help.

## What leaves your Mac

Nothing, unless you or your organisation ask for it:

| Connection | When | How to prevent it |
|---|---|---|
| `projectfive.co.ck`: the update feed and update downloads | Once a day in the background, and when you choose Check for Updates… | Settings → Advanced → turn off automatic checks; organisations set `DisableAutomaticUpdates`, which stops every update request |
| `itunes.apple.com`, and each installed app's own update feed | Only when you click Check for Updates on the Applications screen. The request carries the app's bundle identifier and version. | Organisations set `DisableNetworkLookups` |
| `api.ipify.org` | Only when you click Check Public IP on the Network screen | Organisations set `DisableNetworkLookups` or disable the Network screen |

There is no telemetry, no analytics, no crash reporting and no account. The update feed request carries no system profile.

## Managed Macs

An organisation can set policy through a configuration profile. The app shows "Set by your organisation" beside every setting a profile controls, lists the policy in force under Settings → Advanced, and names the organisation and its support contact when the profile provides them. Policy can restrict what myKikau does; it cannot make it collect or send anything beyond what is described here.

## Contact

Project Five · <https://www.projectfive.co.ck/apps/>
