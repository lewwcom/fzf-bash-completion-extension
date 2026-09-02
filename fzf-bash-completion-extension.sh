# Extends vanilla fzf's bash integration (eval "$(fzf --bash)") so that a
# plain <TAB> press (no ** trigger) pops an fzf fuzzy picker whenever the
# real completer for a command returns more than one possible completions.
#
# Source this at the very END of ~/.bashrc, after:
#   - eval "$(fzf --bash)"
#   - all other completion scripts (kubectl, docker, etc.)

__fzf_sweep_registered_completions() {
  local l f cmd d_line e_line i_line
  local -a cmds=()

  d_line=$(complete -p -D 2> /dev/null)
  e_line=$(complete -p -E 2> /dev/null)
  i_line=$(complete -p -I 2> /dev/null)
  while read -r l; do
    # `-D/-E/-I` compspecs have no command name at all.
    [[ -n $d_line && $l == "$d_line" ]] && continue
    [[ -n $e_line && $l == "$e_line" ]] && continue
    [[ -n $i_line && $l == "$i_line" ]] && continue

    if [[ $l =~ ^(.*\ -F)\ *([^ ]*).*\ ([^ ]*)$ ]]; then
      f="${BASH_REMATCH[2]}"
      [[ $f == _fzf_* || $f == __fzf_* ]] && continue

      cmds+=("${BASH_REMATCH[3]}")
    fi
  done < <(complete -p 2> /dev/null)

  [[ ${#cmds[@]} -gt 0 ]] && _fzf_setup_completion path "${cmds[@]}"
}

__fzf_sweep_registered_completions
unset -f __fzf_sweep_registered_completions

if ! declare -F __fzf_orig_handle_dynamic_completion > /dev/null; then
  eval "$(
     declare -f _fzf_handle_dynamic_completion |
     sed '1s/^_fzf_handle_dynamic_completion/__fzf_orig_handle_dynamic_completion/'
  )"
fi

_fzf_handle_dynamic_completion() {
  local cmd="$1" ret
  local __fzf_co_filenames=''

  # Shadow compopt to capture filenames option
  compopt() {
    case " $* " in
      *' -o filenames '*) __fzf_co_filenames=1 ;;
      *' +o filenames '*) __fzf_co_filenames='' ;;
    esac
    builtin compopt "$@" 2> /dev/null
  }

  __fzf_orig_handle_dynamic_completion "$@"
  ret=$?
  unset -f compopt

  # ret==124: lazy loader just ran, bash will retry completion cycle
  [[ $ret -eq 124 ]] && return 124
  [[ ${#COMPREPLY[@]} -le 1 ]] && return $ret

  local cur picked
  cur="${COMP_WORDS[COMP_CWORD]}"

  # Some completers embed a description alongside the value in COMPREPLY when
  # COMP_TYPE is `complete` mode, which is recommended when you using this
  # script since we are trying to replace bash completion.
  #
  # We assume that the description is separated from suggestion by tab(s) or 2+
  # spaces (best effort, not strict convention). Only attempted when the
  # candidates aren't filenames: a real path can legitimately contain our
  # delimiter of choice.
  local -a extra_opts=()
  if [[ -z $__fzf_co_filenames ]]; then
    extra_opts+=(--delimiter='\t+| {2,}' --with-nth=1 --accept-nth=1)
    # Override the preview when description is present
    local __fzf_desc_re=$'\t+| {2,}'
    [[ "${COMPREPLY[*]}" =~ $__fzf_desc_re ]] &&
        extra_opts+=(--preview 'printf "%s\n" {2..}')
  fi

  picked=$(
    printf '%s\n' "${COMPREPLY[@]}" |
      FZF_DEFAULT_OPTS=$(__fzf_defaults "--reverse" "${FZF_COMPLETION_OPTS-}") \
      FZF_DEFAULT_OPTS_FILE='' \
        __fzf_comprun "$cmd" -q "$cur" "${extra_opts[@]}"
  )

  [[ -n $picked ]] && COMPREPLY=("$picked") || COMPREPLY=("$cur")

  # fzf took over the screen, redraw.
  # See: declare -f __fzf_generic_path_completion
  bind '"\e[0n": redraw-current-line' 2> /dev/null
  builtin printf '\e[5n'
  return 0
}

