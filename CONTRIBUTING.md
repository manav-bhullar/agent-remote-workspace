# Contributing

Thanks for helping! This project is small on purpose: plain shell, one Swift file, one AppleScript. Please keep it that way.

## Good contributions

- **Real-world failure cases** — a situation where the share didn't come back, with the relevant lines from `~/Library/Logs/RemoteWorkspace.log` and `journalctl --user -u mac-wakeup`.
- **Other clients** — a Linux or Windows equivalent of the Mac side.
- **Other editors / agents** — notes or rule files that make them run commands remotely.
- **Docs** — anything that confused you during setup.

## Guidelines

- Every network probe must be time-boxed; never let a script wait on a hung filesystem.
- Events may be missed: changes should keep the reconciler safe to run any number of times.
- Don't add background loops on the Mac. Prefer launchd triggers.
- Check scripts with `bash -n` and, if you have it, `shellcheck`.
- Describe how you tested (which machines, what you broke on purpose).

## Reporting a bug

Open an issue with your macOS and server versions, what you expected, what happened, and the log lines around it.
