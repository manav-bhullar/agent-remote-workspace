# Agent Remote Workspace: safety net
# Heavy commands typed inside the shared folder run on the server, never on this Mac,
# even if an AI agent forgets the rules in AGENTS.md.
#
# Install: copy to ~/.scripts/rw-guard.zsh and add to ~/.zshenv:
#   [[ -f ~/.scripts/rw-guard.zsh ]] && source ~/.scripts/rw-guard.zsh
# Bypass once:  RW_LOCAL=1 npm ...        Preview only:  RW_DRYRUN=1 npm ...

RW_MOUNT="/Volumes/Codes"     # the share as the Mac sees it
RW_SERVER_DIR="Codes"         # the same folder on the server, relative to its home folder
RW_HOST="my-server"           # host alias from ~/.ssh/config

_rw_forward() {
  local cmd=$1; shift
  if [[ -z $RW_LOCAL && ( $PWD == $RW_MOUNT || $PWD == $RW_MOUNT/* ) ]]; then
    local rdir="$RW_SERVER_DIR${PWD#$RW_MOUNT}"
    local remote="cd ${(qq)rdir} && ${(qq)cmd}"
    (( $# )) && remote+=" ${(j: :)${(qq)@}}"
    print -u2 "[remote-workspace] running on server: $cmd $*"
    if [[ -n $RW_DRYRUN ]]; then print -r -- "ssh $RW_HOST $remote"; return 0; fi
    if [[ -t 0 && -t 1 ]]; then
      /usr/bin/ssh -q -t "$RW_HOST" "$remote"
    else
      /usr/bin/ssh -q -T "$RW_HOST" "$remote"
    fi
  else
    command "$cmd" "$@"
  fi
}

for _rw_c in npm npx node pnpm yarn bun python python3 pip pip3 uv pytest cargo go make docker git; do
  eval "function $_rw_c { _rw_forward $_rw_c \"\$@\" }"
done
unset _rw_c
