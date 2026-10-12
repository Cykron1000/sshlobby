# Translating sshlobby

All texts sshlobby shows live in `lang/*.txt`. You translate by adding lines to these files.
No code changes are needed. sshlobby ships with German (`de`) and English (`en`).

## How the language files work

Each file contains blocks. A block starts with a key in square brackets, followed by one line
per language in the form `<code> = <text>`:

```ini
# lang/strings.txt
[settings.language.auto]
de = automatisch (Systemsprache: %s)
en = automatic (system language: %s)
```

- `<code>` is a two-letter lowercase language code (`de`, `en`, `fr`, `es`, ...).
- English is the base. Every key has an `en` line. If your language has no line for a key,
  sshlobby shows the English text.
- Lines starting with `#` and empty lines are ignored. Spaces before and after the text are
  removed.
- Keys use lowercase letters, digits, `.` and `_`. Do not rename or add keys when you only
  translate: the code refers to them.
- All `lang/*.txt` files are read together. Each key exists in exactly one file.

The header of `lang/strings.txt` repeats these rules.

## Placeholders and special characters

| Write | Meaning |
|---|---|
| `%s` | a text inserted by sshlobby (a name, a path, a language) |
| `%d` | a number |
| `%%` | a literal percent sign |
| `\n` | a line break |

Keep the same placeholders in the same order as in the `en` line. sshlobby fills them in order,
so you cannot reorder them. If your language needs a different word order, rephrase the
sentence so the values still appear in the English order.

```ini
# correct: same placeholders, same order as en
[example.disk_usage]
en = Disk %s is %d%% full
de = Datenträger %s ist zu %d%% voll

# wrong: %d before %s swaps the values
[example.disk_usage]
en = Disk %s is %d%% full
de = Zu %d%% voll: %s
```

Use `%%` exactly where the `en` line has it. The test treats `%%` like a placeholder, so an
extra or a missing `%%` counts as a mismatch.

## Add a language

1. Pick the two-letter code of your language, for example `fr`.
2. Open every file in `lang/` and add a line `fr = ...` below the `en` line of each block you
   translate. Start with `[lang.name]`: its text is the name of the language as shown in the
   settings menu (for example `fr = Français`).
3. Run the language tests (see below).
4. Select the language and look through the screens.

Untranslated blocks show English, so a partial translation works. The settings menu lists every
language code that appears anywhere in `lang/*.txt`.

The tests in `tests/test_i18n.sh` currently require `en` and `de` for every key and compare the
placeholders of `de` and `en`. For a new language, check the placeholders yourself against the
`en` line, or extend the test.

## Improve a translation

Search the text you want to change in `lang/`, edit the line of your language and keep the
placeholders. A text you see in the UI may come from a key with placeholders, so search for
a fixed part of it.

```bash
# Terminal, in the repository root
grep -rn 'system language' lang/
```

## Select the language

sshlobby picks the language in this order:

1. `SSHLOBBY_LANG` in the environment
2. `LANGUAGE=<code>` in `~/.config/sshlobby/config`
3. the system locale (`LC_ALL`, `LC_MESSAGES`, `LANG`): `de*` selects German, anything else English

You can also set it in the settings menu (key `e` in the main menu, then the language entry).
The entry "automatic" removes the saved value and follows the system locale again.

```bash
# Terminal: try a language for one run
SSHLOBBY_LANG=fr sshlobby
```

```ini
# ~/.config/sshlobby/config: keep it
LANGUAGE=fr
```

An invalid code (not two lowercase letters) falls back to English.

## Run the tests

```bash
# Terminal, in the repository root
bash tests/run.sh i18n
```

The test checks that every key has an `en` and a `de` line with the same placeholders, that no
key appears twice, that every key used in the code exists in `lang/`, the fallback to English
and the language selection. The other tests run with `SSHLOBBY_LANG=de` and match German
texts, so if you change a German text, run the full suite as well:

```bash
# Terminal, in the repository root
bash tests/run.sh
```

## Technical details

Loading and lookup (`i18n_detect`, `i18n_load`, `TX`, `t`, `tf`) are described in
[ARCHITECTURE.md](ARCHITECTURE.md#languages-i18n).
