#!/bin/zsh
if [[ "$1" == "--version" ]]; then
  print "2.32.1"
  exit 0
fi
if [[ "$2" != "--help" ]]; then exit 2; fi
case "$1" in
  list) print -- "--source --format" ;;
  run) print -- "--no-graphics --no-audio --no-clipboard --suspendable" ;;
  stop) print -- "--timeout" ;;
  ip) print -- "--wait" ;;
  get) print -- "--format" ;;
  prune) print -- "--entries --older-than --space-budget" ;;
  set) print -- "--cpu --memory --display --disk-size" ;;
  create) print -- "--from-ipsw --linux --disk-size" ;;
  clone|rename|delete|push|import|export|suspend|exec) print "$1 help" ;;
  *) exit 2 ;;
esac
