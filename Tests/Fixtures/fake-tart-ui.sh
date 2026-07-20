#!/bin/zsh
case "$1" in
  --version)
    print '2.32.1-ui-test'
    ;;
  list)
    if [[ -n "${FAKE_TART_LIST_DELAY:-}" ]]; then sleep "$FAKE_TART_LIST_DELAY"; fi
    print '[{"Source":"local","Name":"tahoe-base","Disk":50,"Size":12,"Running":false,"State":"Stopped"},{"Source":"local","Name":"sequoia-xcode","Disk":80,"Size":34,"Running":false,"State":"Stopped"}]'
    ;;
  get)
    print '{"OS":"darwin","CPU":4,"Memory":8192,"Disk":50,"DiskFormat":"raw","Size":"12.000","Display":"1920x1080","Running":false,"State":"Stopped"}'
    ;;
  clone|push|prune|set|rename|delete|create|suspend|stop|import|export)
    print "starting $1"
    sleep 2
    print "50% complete"
    sleep 2
    print "finished $1"
    ;;
  ip)
    print '192.0.2.10'
    ;;
  *)
    print -u2 "UI test only"
    exit 2
    ;;
esac
