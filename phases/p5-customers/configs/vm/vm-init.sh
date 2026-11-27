#!/bin/sh
# Customer VM: answers HTTP with its name and MAC, so the responder is visible.
mkdir -p /www; echo "$(hostname) $(cat /sys/class/net/eth1/address)" > /www/index.html
httpd -p 80 -h /www
