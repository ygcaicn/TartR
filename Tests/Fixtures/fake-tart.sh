#!/bin/zsh
zmodload zsh/system
state_dir=/tmp/tartr-fake-state
mkdir -p "$state_dir"

is_running() {
  local pid_file="$state_dir/$1.pid"
  [[ -f "$pid_file" ]] || return 1
  local vm_pid=$(<"$pid_file")
  kill -0 "$vm_pid" 2>/dev/null
}

case "$1" in
  --version)
    print '2.32.1-ui-test'
    ;;
  list)
    local first=true
    print -n '['
    for name in ${=FAKE_TART_VMS:-gitea-runner-worker}; do
      $first || print -n ','
      first=false
      if is_running "$name"; then
        print -n "{\"Source\":\"local\",\"Name\":\"$name\",\"Disk\":50,\"Size\":10,\"Accessed\":\"2026-07-20T00:00:00Z\",\"Running\":true,\"State\":\"Running\"}"
      else
        print -n "{\"Source\":\"local\",\"Name\":\"$name\",\"Disk\":50,\"Size\":10,\"Accessed\":\"2026-07-20T00:00:00Z\",\"Running\":false,\"State\":\"Stopped\"}"
      fi
    done
    print ']'
    ;;
  run)
    name="${@[-1]}"
    if is_running "$name"; then
      print -u2 "virtual machine $name is already running"
      exit 1
    fi
    print -r -- "$sysparams[pid]" > "$state_dir/$name.pid"
    print -r -- "args: $*" >> /tmp/tart-runner-worker-app-test.log
    trap '/bin/rm -f "$state_dir/$name.pid"; print -r -- "terminated: $name" >> /tmp/tart-runner-worker-app-test.log; exit 0' TERM INT
    print -r -- "started: $name" >> /tmp/tart-runner-worker-app-test.log
    while true; do sleep 0.2; done
    ;;
  stop)
    name="$2"
    if is_running "$name"; then
      vm_pid=$(<"$state_dir/$name.pid")
      kill -TERM "$vm_pid"
      exit 0
    fi
    print -u2 "virtual machine $name is not running"
    exit 1
    ;;
  *)
    print -u2 "unsupported fake tart command: $*"
    exit 2
    ;;
esac
