# FRR plus the Linux tools the lab's router roles need: firewall (iptables),
# load balancer (HAProxy + keepalived), web server (busybox httpd), IPsec
# (strongSwan), WAN impairment checks. Multi-arch base, Alpine packages only.
FROM quay.io/frrouting/frr:10.7.1
RUN apk add --no-cache \
      bash iproute2 iptables tcpdump curl busybox-extras \
      haproxy keepalived strongswan iperf3 \
 && rm -rf /var/cache/apk/*
