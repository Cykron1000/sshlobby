# CLAUDE.md

Instructions for Claude Code and other coding agents working with sshlobby: installing it on a server,
changing it, and testing it.

sshlobby is a Bash TUI that starts when you log in over SSH. It lists Docker Compose projects, Incus
containers or Incus containers with Docker inside, and offers server tools (services, ports, updates and
more). It changes nothing on its own: every action that restarts, stops or installs something asks first.

## Install sshlobby on a server

Do these steps in order. Ask the user before step 4 if the server is not yours to change.

### 1. Check the requirements

```sh
# On the target server. Every line should print a path or a version.
bash --version | head -n1        # 4.3 or newer
command -v jq tput awk           # required
command -v docker incus          # at least one of them
command -v tmux systemctl journalctl ss   # optional: updates in tmux, services, logs, ports
```

On Debian or Ubuntu, missing required tools come from `apt-get install jq ncurses-bin` (awk is preinstalled;
mawk and gawk both work).
sshlobby is built for root logins. The install script must run as root.

### 2. Get the code

```sh
git clone https://github.com/Nikolai-Slsr/sshlobby.git
cd sshlobby
```

### 3. Back up the shell startup file

`install.sh` adds a block to `~/.bashrc` of the user who runs it. Keep a copy so you can show the user
exactly what changed:

```sh
cp -p ~/.bashrc ~/.bashrc.before-sshlobby
```

### 4. Install

```sh
sudo ./install.sh
```

What it does:

- copies the program to `/usr/local/lib/sshlobby/` and links `/usr/local/bin/sshlobby`
- adds this block to `~/.bashrc` (or replaces an older version of it in place):

  ```bash
  # >>> sshlobby >>>
  if [ -n "$PS1" ] && [ -t 0 ] && [ -t 1 ] && [ -z "$SSHLOBBY_SKIP" ] && [ "$SSH_TTY" ] && [[ $- == *i* ]] && ! [[ "${SSH_ORIGINAL_COMMAND:-}" ]]; then
    SSHLOBBY_SKIP=1 SSHLOBBY_LOGIN=1 sshlobby; [ $? -eq 20 ] && exit
  fi
  # <<< sshlobby <<<
  ```

The script is idempotent. Running it again updates the program and leaves an up-to-date hook alone.
Paths can be overridden for testing: `BIN_DST`, `LIB_DST`, `BASHRC`, `CONF_DST`.

### 5. Configure without the interactive setup (optional)

On the first interactive start, sshlobby asks for the mode and a display name. To skip that, write the
config before the user logs in:

```sh
mkdir -p ~/.config/sshlobby
cat > ~/.config/sshlobby/config <<'EOF'
MODE=docker          # docker | incus | layered
HOST_LABEL=web-01    # name shown in the header
EOF
```

All keys are listed in the README under "Configuration". The file is parsed, never sourced, so unknown
keys and invalid values are ignored.

### 6. Verify

```sh
sshlobby --version               # prints the version
sshlobby --list                  # overview without the menu
diff ~/.bashrc.before-sshlobby ~/.bashrc   # only the sshlobby block was added
```

Then check the login from a second machine:

- `ssh -t <server>` shows the dashboard, `q` logs out, `s` opens a normal shell.
- `ssh <server> uptime`, `scp` and `sftp` work as before. The hook only runs for interactive SSH sessions.

### 7. Tell the user how to get past the dashboard

- `s` in the main menu opens the normal shell.
- Only `q` (exit code 20) logs out. A crash or Ctrl-C ends in the normal shell, so nobody gets locked out.
- `SSHLOBBY_SKIP=1` in the environment skips the dashboard. In the settings, "Start on SSH login" turns
  the automatic start off.

### Update and uninstall

```sh
cd sshlobby && git pull && sudo ./install.sh   # update
sudo ./uninstall.sh                            # remove program and hook, keep settings
sudo ./uninstall.sh --purge                    # also delete ~/.config/sshlobby
```

## Rules for agents on a live server

- Do not run actions from the dashboard (restart, stop, updates, reboot) unless the user asked for them.
- Never kill the tmux session `sshlobby-apt`: it may hold a running package upgrade.
- Edit `~/.bashrc` only through `install.sh` and `uninstall.sh`. They only touch the marked block.
- Settings live in `~/.config/sshlobby/`. The settings menu makes a backup before every reset.

## Work on the code

```
sshlobby.sh          entry point: loads lib/core.sh, the language, then the other modules
lib/core.sh          config, paths, favorites, history, language loading (TX, t, tf)
lib/ui.sh            screen drawing, menus, keys, pager, line mode
lib/screens.sh       main menu, project, container and Incus container screens
lib/backend_*.sh     Docker and Incus access
lib/tools*.sh        server tools, registered with tool_register
lib/settings.sh      settings menu, reset, backups
lib/setup.sh         first-start setup and mode detection
lang/*.txt           all interface texts (English and German)
tests/               test runner, stubs for docker, incus, systemctl and friends, fixtures
docs/                ARCHITECTURE.md, UI.md, TOOLS.md, TRANSLATING.md
```

### Run the tests

```sh
bash tests/run.sh             # all tests, several minutes (the TUI tests need tmux)
bash tests/run.sh settings    # only tests whose name contains "settings"
shellcheck -S style sshlobby.sh install.sh uninstall.sh lib/*.sh tests/*.sh tests/stubs/*
```

The tests never call the real `docker`, `incus`, `systemctl`, `apt-get` or `ssh`: `PATH` contains only the
stubs in `tests/stubs/` and a few linked system tools. Install tests redirect every path into a temporary
folder and refuse to run if a path in the script cannot be redirected.

The tests check the German texts (`SSHLOBBY_LANG=de` in `tests/run.sh`). English output is covered by the
`i18n` tests.

### Change or add interface text

Never put visible text directly into the code. Add a key to a file in `lang/` with an `en` and a `de` line
and use it with `"${TX[key]}"`, `tf var key args` or `t key args`. The format is described at the top of
`lang/strings.txt` and in `docs/TRANSLATING.md`. `bash tests/run.sh i18n` checks that every key used in the
code exists and has both languages with the same placeholders.

### Release checklist

1. Bump `VERSION` in `sshlobby.sh` and the version checks in `tests/test_cli.sh`, `tests/test_core.sh`,
   `tests/test_ui.sh` and `tests/test_install.sh`.
2. Add the version to `CHANGELOG.md`.
3. Full test run and shellcheck without findings.
4. Update the screenshots if the interface changed: `bash tools/dev/screenshots.sh`.
