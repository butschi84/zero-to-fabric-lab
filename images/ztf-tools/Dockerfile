# Small Linux host image for clients, servers and capture helpers.
# Multi-arch base (amd64 + arm64); everything comes from the Alpine repos.
FROM alpine:3.22
RUN apk add --no-cache \
      bash iproute2 iputils iputils-tracepath traceroute mtr \
      tcpdump tshark iperf3 curl jq bind-tools iptables \
      dhcpcd busybox-extras ethtool python3 kea-dhcp4 dnsmasq \
 && rm -rf /var/cache/apk/*
CMD ["sleep", "infinity"]
