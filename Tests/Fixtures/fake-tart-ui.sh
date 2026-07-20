#!/bin/zsh
case "$1" in
  list)
    print '[{"Source":"local","Name":"tahoe-base","Disk":50,"Size":12,"Running":false,"State":"Stopped"},{"Source":"local","Name":"sequoia-xcode","Disk":80,"Size":34,"Running":false,"State":"Stopped"}]'
    ;;
  *)
    print -u2 "UI test only"
    exit 2
    ;;
esac
