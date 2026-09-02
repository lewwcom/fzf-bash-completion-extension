# `fzf-bash-completion-extension`

fzf's bash integration only invokes fzf's fuzzy picker for a curated set of
completions (files, directories, process names, etc.) when the `**` trigger is
typed. Without `**`, bash falls back to the command's own compspec, which
generates the command's own possible completions (e.g. `kubectl` subcommands,
git branches, docker container names) - and bash/Readline displays those
normally, as a plain list.

This script shows those same possible completions in fzf's fuzzy picker
instead of bash/Readline's plain list.

## Getting started

### Prerequisite

- [fzf](https://github.com/junegunn/fzf), with its bash integration loaded
  (`eval "$(fzf --bash)"` in your `.bashrc`) (tested with fzf 0.74.3)
- `<TAB>` bound to the Readline command `complete` (bash's default) instead of
  `menu-complete`

> [!note]
>
> Some completion functions (e.g. `kubectl`'s, and most cobra-generated CLIs')
> format each possible completion with a description alongside it. Those only
> show up when `<TAB>` is bound to `complete`. `menu-complete` makes such
> functions strip descriptions unconditionally.

### Installation

1. Download the script

   ```bash
   wget -O fzf-bash-completion-extension.sh https://raw.githubusercontent.com/lewwcom/fzf-bash-completion-extension/refs/heads/master/fzf-bash-completion-extension.sh

   # or
   curl -O https://raw.githubusercontent.com/lewwcom/fzf-bash-completion-extension/refs/heads/master/fzf-bash-completion-extension.sh

   # or
   git clone https://github.com/lewwcom/fzf-bash-completion-extension.git
   ```

2. Add it to your `.bashrc`, **after** `eval "$(fzf --bash)"` and any other
   completion setup commands (`kubectl`, `docker`, etc.) - coverage depends on
   those already being registered by the time this script runs

   ```bash
   # .bashrc
   source /path/to/script/fzf-bash-completion-extension.sh
   ```

### Usage

Type your command of choice then hit `<TAB>`.

## How it works

Before going further, you should understand how fzf's own bash integration
drives fuzzy completion - see [fzf](https://github.com/junegunn/fzf) for the
authoritative explanation, or for a quick review, see the collapsed section
below.

<details>
<summary>How fzf's bash integration drives fuzzy completion</summary>

fzf's bash integration (`completion.bash`) hooks into bash's programmable
completion system via `complete -F`, rather than intercepting `<TAB>` directly.
The pseudocode below is specific to **fzf 0.74.3**'s `completion.bash` -
internal function names and mechanics can change between fzf versions. It
outlines the bash integration's baseline workflow, excluding any logic unrelated
to this extension.

For a command whose real compspec the bash integration has already captured:

```python
# User types: `somecommand <TAB>`
# bash's compspec lookup found: `complete -F _fzf_path_completion somecommand`
COMPREPLY = _fzf_path_completion(cmd, partial_word)

def _fzf_path_completion(cmd, partial_word):
    return __fzf_generic_path_completion(cmd, partial_word)

TRIGGER = "**"
def __fzf_generic_path_completion(cmd, partial_word):
    if partial_word.endswith(TRIGGER):
        ... # fzf's own generic path/dir finder - not relevant to this trace
    else:
        return _fzf_handle_dynamic_completion(cmd, partial_word)

def _fzf_handle_dynamic_completion(cmd, partial_word):
    orig_func = __fzf_orig_completion_get_orig_func(cmd) # succeeds: captured earlier
    if orig_func:
        # no `**` trigger -> fzf's picker never invoked here;
        # bash just shows `COMPREPLY` plainly
        return orig_func(cmd, partial_word) # the real possible completions
```

For a command that's never been completed before (no compspec registered for
it anywhere), bash's own compspec lookup falls all the way through to `-D`
(default compspec), which will find and load the compspec for the command if
any:

```python
# User types: `somecomand <TAB>`
# bash's compspec lookup: exact name -> basename -> `-D` default; nothing
# registered for "somecommand" specifically, so this falls to `-D`
ret, COMPREPLY = __fzf_default_completion(cmd, partial_word)

def __fzf_default_completion(cmd, partial_word):
    ret, COMPREPLY = __fzf_generic_path_completion(cmd, partial_word)
    if ret == 124:
        # the lazy-load engine registered a real compspec for `somecommand`
        # (see below) - re-register it wrapped in the bash integration's
        # own function too, so it stays fzf-aware going forward
        _fzf_setup_completion("path", cmd)

        # Exit status is `124` means "compspec changed, retry" - bash redoes the
        # ENTIRE lookup from scratch; this time it finds `_fzf_path_completion`
        # registered for `somecommand`
        return 124, ""
    return ret, COMPREPLY

TRIGGER = "**"
def __fzf_generic_path_completion(cmd, partial_word):
    if partial_word.endswith(TRIGGER):
        ...
    else:
        return _fzf_handle_dynamic_completion(cmd, partial_word)

def _fzf_handle_dynamic_completion(cmd, partial_word):
    orig_func = __fzf_orig_completion_get_orig_func(cmd) # fails: nothing captured yet
    if orig_func:
        return orig_func(cmd, partial_word)

    if LAZY_LOAD_ENGINE:
        orig_complete = bash(f"complete -p {cmd}") # empty - nothing registered yet

        LAZY_LOAD_ENGINE(cmd, partial_word)  # e.g.` _comp_load(...)`
        # engine looks for a file named "somecommand[.bash]" in a known
        # completions directory and sources it if found. That file itself runs:
        #
        #   bash("complete -F _real_somecommand somecommand")
        #
        # registering the command's real compspec for the first time.

        if bash(f"complete -p {cmd}") != orig_complete:
            ... # handle edge cases
            return 124   # "compspec changed, retry"
```

In neither trace above does fzf's picker actually appear, unless the `**`
trigger is present in what you typed - that's the whole limitation this script
addresses.
</details>

The solution has two parts: make sure every command with a compspec is
actually routed through fzf's bash integration's own completion functions in
the first place, then extend what `_fzf_handle_dynamic_completion` does
once a `<TAB>` press reaches it.

### Part 1: coverage

Grouping by how their compspecs end up wired into fzf's bash integration, there
are three categories of command:

- **Commands listed in `FZF_COMPLETION_(DIR|PATH|VAR)_COMMANDS`** - the bash
  integration's own setup loop re-registers them directly, up front, with
  `_fzf_(dir|path|var)_completion` as the function, when `completion.bash` is
  sourced.
- **Commands with no compspec registered at all until first Tab-completed
  (lazily loaded)**. Bash falls through to `-D`, which the bash integration has
  replaced with `__fzf_default_completion` (itself standing in for
  bash-completion's own `-D` dispatcher, `_comp_complete_load`). The command's
  real compspec gets registered on demand, then re-registered with
  `_fzf_path_completion` as the function (see
  `declare -f __fzf_default_completion`).
- **Commands with a compspec already registered - their own (e.g. kubectl's,
  docker's) - but not one of the curated `FZF_COMPLETION_*_COMMANDS` names.**
  These are covered by this script's sweep: at source time, it scans every
  currently-registered `-F` compspec, skips anything the bash integration
  already wrapped, and re-registers the rest with `_fzf_path_completion` too -
  the same generic fallback kind the lazy-load path above already uses.

### Part 2: extending `_fzf_handle_dynamic_completion`

`_fzf_handle_dynamic_completion` is the point where a command's real completion
function is called directly and then bash shows its plain list of possible
completions. This script renames the original function to
`__fzf_orig_handle_dynamic_completion`, and defines a new
`_fzf_handle_dynamic_completion` that calls the original function unchanged,
then - only when it returns normally (not the `124` retry signal) with 2 or more
possible completions in `COMPREPLY` - pipes them through fzf's picker and
collapses the pick to one completion.

Some completers (e.g. `kubectl`'s) embed a description alongside each candidate,
separated by a tab or 2+ spaces. When candidates aren't filenames, this script
splits on that separator, shows only the value in the picker's list, and inserts
only the value on accept. If a description is actually present, the preview pane
shows it instead of your default preview (defined in `_fzf_comprun`). This is a
best-effort heuristic, since there is no strict convention for a description
separator.

## Contributing

Pull requests are welcome. 

## Related projects

There are different approaches for bash completion, you might want to check out:

- [microsoft/inshellisense](https://github.com/microsoft/inshellisense):
  `inshellisense` acts as middle layer between your terminal emulator and shell,
  it captures output of shell and adds visual completions layer on top of that.
- [lincheney/fzf-tab-completion](https://github.com/lincheney/fzf-tab-completion):
  `fzf-tab-completion` binds directly to `<TAB>` via `bind -x`, bypassing Bash's
  programmable completion compspec lookup and invocation entirely — so it
  reimplements Bash's word-splitting, compspec-resolution, compopt-handling
  mechanisms itself.
- [HalFrgrd/flyline](https://github.com/HalFrgrd/flyline): Flyline is a
  replacement of GNU Readline - the library that handles your keystrokes, that
  provides an enhanced line editing experience.

## License

[MIT](./LICENSE)

