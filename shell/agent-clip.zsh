# ac [id]: put the newest queued command for this project (or clip #id) on the prompt, ready to run.
ac() {
  local cmd
  cmd=$(agent-clip pull "$@") || return
  print -z -- "$cmd"
}
