#!/bin/sh
# Web server: answers with its own name and MAC, so the responding machine is visible.
mkdir -p /www
echo "$(hostname) $(cat /sys/class/net/eth1/address)" > /www/index.html
httpd -p 80 -h /www
