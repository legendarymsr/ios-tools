Box-side tests (no kernel VHCI, no iOS VM needed).
  gcc -shared -fPIC -o shim.so shim.c -ldl      # hands the VHCI attach fd to the test
  gcc -O2 -pthread -I.. -o vb ../bridge.c
  mkdir -p sys/vhci; printf 'hub port sta spd dev sockfd local_busid\nhs  0000 004 000 00000000 000000 0-0\n' > sys/vhci/status; touch sys/vhci/attach sys/vhci/detach
  python3 stress.py 1 &   # or mock2.py (enumeration needs 2nd bus reset)
  ATTACH_SOCK=/tmp/vt/att.sock LD_PRELOAD=./shim.so ./vb -s /tmp/vt/usb.sock -V ./sys/vhci -q
Paths in the scripts assume /tmp/vt.
