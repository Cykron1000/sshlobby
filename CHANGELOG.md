# Changelog

All notable changes to sshlobby. Versions follow [semantic versioning](https://semver.org/).

## 3.0.0 (2026-10-12)

First public release.

- The project is now called sshlobby: command `sshlobby`, settings in `~/.config/sshlobby/`, environment
  variables `SSHLOBBY_*`. `install.sh` migrates an installation of the internal predecessor: it copies the
  settings, replaces the old login hook in place and removes the old program files.
- English and German interface. All texts live in `lang/*.txt`; the language comes from the settings menu,
  `SSHLOBBY_LANG` or the system locale. Missing translations fall back to English. See `docs/TRANSLATING.md`.
- Documentation in English, README with screenshots, `CLAUDE.md` with installation steps for coding agents.
- Test fixtures and example descriptions use neutral sample data.

## 2.2.0 (2026-10-12)

- Settings menu (key `e`, `sshlobby --settings`): mode, display name, descriptions, start on SSH login,
  what `q` does, line mode, colors, ASCII symbols, number of recent entries, SSH targets, CVE monitor.
- Reset options with a backup first (`~/.config/sshlobby/backups/`, newest 10 kept) and restore from the menu.
  `sshlobby --reset` resets everything and runs the first-start setup.
- New config keys `AUTOSTART`, `Q_ACTION`, `UI`, `COLOR`, `SYMBOLS`, `RECENT_MAX`, `HERMES_SCAN_CTS`.
- The login hook sets `SSHLOBBY_LOGIN=1`, so `AUTOSTART=no` only affects login starts.
- Updates tool: a finished run in the tmux session is no longer reported as still running.

## 2.1.0 (2026-10-12)

- Hermes agent instances tool: finds instances on the host (systemd, Docker) and inside Incus containers,
  groups gateway and web UI per data folder, shows status, logs, cron jobs, profiles and a masked `config.yaml`.
- Updates tool: refresh package lists, install security updates or all updates, reboot after typing the
  hostname. Runs in a tmux session, so a dropped SSH connection does not stop it.
- Recently used tools appear under "Recent" in the main menu.

## 2.0.0 (2026-10-12)

- Arrow-key interface with header, breadcrumb, key hints, filter (`/`), pager and fallbacks for
  `NO_COLOR`, ASCII terminals and narrow windows. Line mode with the same numbers when there is no terminal.
- Three modes: `docker` (containers on the host, grouped by Compose project), `incus` (Incus containers) and
  `layered` (Incus containers with Docker inside). First-start setup detects the mode.
- Server tools: server check, systemd services, ports, container resources, storage, security check, updates,
  timers and cron, network and access, container hygiene.
- Config file parsed safely (never sourced), descriptions file, favorites and history.

## 1.x

Internal versions: numbered menu for Incus containers with Docker inside.
