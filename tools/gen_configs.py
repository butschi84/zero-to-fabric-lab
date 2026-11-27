#!/usr/bin/env python3
"""Generate the SR Linux startup configs (flat CLI) for every lab phase.

One fabric plan (addressing, ASNs, ports) feeds all phases, so a value never
drifts between phases. Each phase switches features on; the output lands in
phases/<phase>/configs/<node>.cli and is committed, so a phase deploys without
running this script.  Usage:  python3 tools/gen_configs.py [phase ...]
"""
import pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# ---------------------------------------------------------------- fabric plan
# Tenant numbering (shared with the article series): VLAN = 100*tenant + net
# (corp 1, guest 2, mgmt 3, shared 9), L2VNI = 10000 + VLAN, L3VNI = 50000 +
# tenant, RT = 65000:<VNI>, RD = <loopback>:<VLAN or tenant>, subnet
# 10.<tenant>.<net>.0/24 with the gateway on .1. Underlay: loopbacks
# 10.255.0.<id>/32, spine-leaf links 10.254.<spine>.<n>/31.
SPINE_AS, OVERLAY_AS = 65000, 65500
SPINES = {"spine1": 1, "spine2": 2}
LEAFS = {f"leaf{n}": n for n in range(1, 7)}          # rack A: 1-2, B: 3-4, C: 5-6
BORDERS = {"border1": 7, "border2": 8}                # spine port index
UPLINKS = {"spine1": "ethernet-1/49", "spine2": "ethernet-1/50"}
# Fabric links carry VXLAN (+50 bytes): IP MTU 9000 on a 9232-byte port MTU,
# so a full 1500-byte host packet fits. Phase 2 measures the 1500 case too.
FABRIC_IP_MTU = 9000


def leaf_as(name):
    return 65100 + LEAFS[name] if name in LEAFS else 65200 + (BORDERS[name] - 6)


def node_id(name):
    """spine1-2 -> 1-2, leaf1-6 -> 11-16, border1-2 -> 21-22."""
    if name in SPINES:
        return SPINES[name]
    if name in LEAFS:
        return 10 + LEAFS[name]
    return 20 + BORDERS[name] - 6


def loopback(name):
    return f"10.255.0.{node_id(name)}"


def port_index(name):
    return LEAFS.get(name) or BORDERS[name]


def p2p(spine, leaf):
    """/31 per spine-leaf link: spine gets the even address, leaf the odd."""
    s, i = SPINES[spine], port_index(leaf)
    base = 2 * (i - 1)
    return f"10.254.{s}.{base}", f"10.254.{s}.{base + 1}"


# ---------------------------------------------------------------- helpers
def iface(lines, name, desc, addr=None, mtu=None, ip_mtu=None):
    lines += [f"set / interface {name} admin-state enable",
              f'set / interface {name} description "{desc}"']
    if mtu:
        lines.append(f"set / interface {name} mtu {mtu}")
    if addr:
        lines += [f"set / interface {name} subinterface 0 ipv4 admin-state enable",
                  f"set / interface {name} subinterface 0 ipv4 address {addr}",
                  *([f"set / interface {name} subinterface 0 ip-mtu {ip_mtu}"] if ip_mtu else []),
                  f"set / network-instance default interface {name}.0"]


def system(lines, name):
    lines += [f"set / system name host-name {name}",
              "set / interface system0 admin-state enable",
              "set / interface system0 subinterface 0 ipv4 admin-state enable",
              f"set / interface system0 subinterface 0 ipv4 address {loopback(name)}/32",
              "set / network-instance default type default",
              "set / network-instance default interface system0.0"]


def underlay_policy(lines, f=()):
    lines += ["set / routing-policy prefix-set loopbacks prefix 10.255.0.0/24 mask-length-range 32..32",
              "set / routing-policy prefix-set client-nets prefix 10.10.0.0/16 mask-length-range 24..24",
              "set / routing-policy policy underlay statement 10 match prefix-set loopbacks",
              "set / routing-policy policy underlay statement 10 action policy-result accept",
              "set / routing-policy policy underlay statement 20 match prefix-set client-nets",
              "set / routing-policy policy underlay statement 20 action policy-result accept"]
    if "bgplab" in f:   # phase 1 test prefix from leaf1 (P1-11)
        lines += ["set / routing-policy prefix-set doc-198 prefix 198.51.100.0/24 mask-length-range exact",
                  "set / routing-policy policy underlay statement 30 match prefix-set doc-198",
                  "set / routing-policy policy underlay statement 30 action policy-result accept"]


def origin_community(lines, name):
    """Leafs tag what they originate with <leaf-AS>:<rack> (shown in phase 1)."""
    rack = (LEAFS[name] + 1) // 2 if name in LEAFS else 9
    lines += [f"set / routing-policy community-set origin member [ {leaf_as(name)}:{rack} ]",
              "set / routing-policy policy underlay-out statement 10 match prefix-set loopbacks",
              "set / routing-policy policy underlay-out statement 10 action policy-result accept",
              "set / routing-policy policy underlay-out statement 10 action bgp communities add origin",
              "set / routing-policy policy underlay-out statement 20 match prefix-set client-nets",
              "set / routing-policy policy underlay-out statement 20 action policy-result accept",
              "set / routing-policy policy underlay-out statement 20 action bgp communities add origin"]


def bgp_base(lines, name, asn, export="underlay"):
    b = "set / network-instance default protocols bgp"
    lines += [f"{b} autonomous-system {asn}",
              f"{b} router-id {loopback(name)}",
              f"{b} afi-safi ipv4-unicast admin-state enable",
              f"{b} afi-safi ipv4-unicast multipath allow-multiple-as true",
              f"{b} afi-safi ipv4-unicast multipath maximum-paths 8",
              f"{b} group underlay export-policy [ {export} ]",
              f"{b} group underlay import-policy [ underlay ]",
              f"{b} group underlay failure-detection enable-bfd true",
              f"{b} group underlay failure-detection fast-failover true"]


def bfd(lines, ifname):
    # 1 s is the smallest interval the virtual SR Linux accepts (it overrides
    # anything lower); hardware goes much lower. Detection = 3 x 1 s.
    lines += [f"set / bfd subinterface {ifname}.0 admin-state enable",
              f"set / bfd subinterface {ifname}.0 desired-minimum-transmit-interval 1000000",
              f"set / bfd subinterface {ifname}.0 required-minimum-receive 1000000",
              f"set / bfd subinterface {ifname}.0 detection-multiplier 3"]


def overlay(lines, name, peers, rr=False):
    b = "set / network-instance default protocols bgp"
    lines += [f"{b} group overlay peer-as {OVERLAY_AS}",
              f"{b} group overlay local-as as-number {OVERLAY_AS}",
              f"{b} group overlay local-as prepend-global-as false",
              f"{b} group overlay afi-safi evpn admin-state enable",
              f"{b} group overlay afi-safi ipv4-unicast admin-state disable",
              f"{b} group overlay transport local-address {loopback(name)}"]
    if rr:
        lines += [f"{b} group overlay route-reflector client true",
                  f"{b} group overlay route-reflector cluster-id {loopback(name)}"]
    for p in peers:
        lines.append(f"{b} neighbor {loopback(p)} peer-group overlay")


# ---------------------------------------------------------------- tenants (phase 3a+)
# Tenant number t: L3VNI 50000+t, IP-VRF RT 65000:<L3VNI>, IP-VRF EVI t (so the
# auto RD is <loopback>:t). Network n of tenant t: VLAN 100t+n, L2VNI
# 10000+VLAN, MAC-VRF EVI = VLAN (auto RD <loopback>:VLAN), subnet
# 10.t.n.0/24, anycast gateway 10.t.n.1 with the same virtual MAC on every
# leaf (VRRP-style 00:00:5e:00:01:01, virtual-router-id 1). Each leaf also
# gets a unique address per tenant, 10.t.255.<node id>/32 on lo1.t (used as
# DHCP relay giaddr, phase 3a).
TENANTS = {"corp": 1, "guest": 2, "mgmt": 3, "shared": 9,
           # phase 5: hosting customers, all with the same 10.0.0.0/24
           "cust-a": 11, "cust-b": 12, "cust-c": 13}
# SR Linux reserves the network-instance name "mgmt" for its own management
# port, so tenant mgmt's IP-VRF is called "mgmt-net" on the switches.
VRF_NAME = {"mgmt": "mgmt-net"}


def vrf(tenant):
    return VRF_NAME.get(tenant, tenant)


def vlan_of(tenant, net):
    return 100 * TENANTS[tenant] + net


def tenant_fabric(L, name, ph):
    """Bridged access ports, one MAC-VRF + IRB per network, one IP-VRF per
    tenant with an L3VNI (symmetric IRB), all for the networks of this leaf."""
    nets = [(e[0], e[1]) for e in ph["nets"] if name in e[2]]
    subnet = {(e[0], e[1]): e[3] for e in ph["nets"] if len(e) > 3}   # override, e.g. "10.0.0"
    for port, vlan, peer in ph["ports"].get(name, []):
        L += [f"set / interface {port} admin-state enable",
              f'set / interface {port} description "to {peer}"',
              f"set / interface {port} subinterface 0 type bridged",
              f"set / interface {port} subinterface 0 admin-state enable",
              f"set / network-instance mac-vrf-{vlan} interface {port}.0"]
    for t, n in nets:
        vlan = vlan_of(t, n); vni = 10000 + vlan
        ni, irb = f"mac-vrf-{vlan}", f"irb0 subinterface {vlan}"
        L += [f"set / tunnel-interface vxlan1 vxlan-interface {vlan} type bridged",
              f"set / tunnel-interface vxlan1 vxlan-interface {vlan} ingress vni {vni}",
              f"set / interface irb0 admin-state enable",
              f"set / interface {irb} admin-state enable",
              f"set / interface {irb} ipv4 admin-state enable",
              f"set / interface {irb} ipv4 address {subnet.get((t, n), f'10.{TENANTS[t]}.{n}')}.1/24 anycast-gw true",
              f"set / interface {irb} ipv4 address {subnet.get((t, n), f'10.{TENANTS[t]}.{n}')}.1/24 primary",
              f"set / interface {irb} anycast-gw virtual-router-id 1",
              f"set / interface {irb} ipv4 arp learn-unsolicited true",
              f"set / interface {irb} ipv4 arp host-route populate dynamic",
              f"set / interface {irb} ipv4 arp evpn advertise dynamic",
              f"set / network-instance {ni} type mac-vrf",
              f"set / network-instance {ni} admin-state enable",
              f"set / network-instance {ni} interface irb0.{vlan}",
              f"set / network-instance {ni} vxlan-interface vxlan1.{vlan}",
              f"set / network-instance {ni} protocols bgp-evpn bgp-instance 1 admin-state enable",
              f"set / network-instance {ni} protocols bgp-evpn bgp-instance 1 vxlan-interface vxlan1.{vlan}",
              f"set / network-instance {ni} protocols bgp-evpn bgp-instance 1 evi {vlan}",
              f"set / network-instance {ni} protocols bgp-vpn bgp-instance 1 route-target export-rt target:{SPINE_AS}:{vni}",
              f"set / network-instance {ni} protocols bgp-vpn bgp-instance 1 route-target import-rt target:{SPINE_AS}:{vni}"]
        relay = ph.get("dhcp_relay", {}).get(vlan)
        if relay:
            # giaddr = this leaf's unique 10.t.255.<id>, not the anycast gateway
            # (identical on every leaf, so the reply would go to any leaf).
            # SR Linux 24.10 offers suboptions circuit-id and remote-id only, no
            # link-selection (RFC 3527); the server maps the giaddr to the pool.
            d = f"set / interface {irb} ipv4 dhcp-relay"
            L += [f"{d} admin-state enable", f"{d} server [ {relay} ]",
                  f"{d} gi-address 10.{TENANTS[t]}.255.{node_id(name)}",
                  f"{d} use-gi-addr-as-src-ip-addr true",
                  f"{d} network-instance {vrf(t)}", f"{d} option [ circuit-id remote-id ]"]
    for t in sorted({t for t, _ in nets} | set(ph.get("vrf_only", {}).get(name, [])), key=TENANTS.get):
        ip_vrf(L, name, t, [f"irb0.{vlan_of(t, n)}" for tt, n in nets if tt == t])


def ip_vrf(L, name, tenant, ifaces):
    tid = TENANTS[tenant]; l3 = 50000 + tid; t = vrf(tenant)
    L += [f"set / tunnel-interface vxlan1 vxlan-interface {l3} type routed",
          f"set / tunnel-interface vxlan1 vxlan-interface {l3} ingress vni {l3}",
          "set / interface lo1 admin-state enable",
          f"set / interface lo1 subinterface {tid} admin-state enable",
          f"set / interface lo1 subinterface {tid} ipv4 admin-state enable",
          f"set / interface lo1 subinterface {tid} ipv4 address 10.{tid}.255.{node_id(name)}/32",
          f"set / network-instance {t} type ip-vrf",
          f"set / network-instance {t} admin-state enable",
          f'set / network-instance {t} description "tenant {tenant}, L3VNI {l3}"',
          f"set / network-instance {t} interface lo1.{tid}",
          *[f"set / network-instance {t} interface {i}" for i in ifaces],
          f"set / network-instance {t} vxlan-interface vxlan1.{l3}",
          f"set / network-instance {t} protocols bgp-evpn bgp-instance 1 admin-state enable",
          f"set / network-instance {t} protocols bgp-evpn bgp-instance 1 vxlan-interface vxlan1.{l3}",
          f"set / network-instance {t} protocols bgp-evpn bgp-instance 1 evi {tid}",
          f"set / network-instance {t} protocols bgp-evpn bgp-instance 1 ecmp 8",
          f"set / network-instance {t} protocols bgp-vpn bgp-instance 1 route-target export-rt target:{SPINE_AS}:{l3}",
          f"set / network-instance {t} protocols bgp-vpn bgp-instance 1 route-target import-rt target:{SPINE_AS}:{l3}"]


def border_fw(L, name, ph):
    """Border leaf: one tagged sub-interface per tenant VRF to the firewall
    (VLAN = tenant number, /31 10.250.<border>.<2t>), eBGP from the VRF to the
    firewall (AS 65300). The VRF takes only 0.0.0.0/0 from the firewall and
    sends it the tenant prefixes (10.0.0.0/8, /16../32); the default reaches
    the fabric as a Type-5 route with the border as next hop."""
    port, fw_as = ph["fw_link"][name], 65300
    b = BORDERS[name] - 6
    L += [f"set / interface {port} admin-state enable",
          f'set / interface {port} description "to firewall"',
          f"set / interface {port} vlan-tagging true",
          "set / routing-policy prefix-set default-route prefix 0.0.0.0/0 mask-length-range exact",
          "set / routing-policy prefix-set tenant-nets prefix 10.0.0.0/8 mask-length-range 16..32",
          "set / routing-policy policy from-fw statement 10 match prefix-set default-route",
          "set / routing-policy policy from-fw statement 10 action policy-result accept",
          "set / routing-policy policy from-fw default-action policy-result reject",
          "set / routing-policy policy to-fw statement 10 match prefix-set tenant-nets",
          "set / routing-policy policy to-fw statement 10 action policy-result accept",
          "set / routing-policy policy to-fw default-action policy-result reject"]
    for t in ph["vrf_only"][name]:
        tid, v = TENANTS[t], vrf(t)
        me, fw = f"10.250.{b}.{2 * tid}", f"10.250.{b}.{2 * tid + 1}"
        bg = f"set / network-instance {v} protocols bgp"
        L += [f"set / interface {port} subinterface {tid} type routed",
              f"set / interface {port} subinterface {tid} admin-state enable",
              f'set / interface {port} subinterface {tid} description "{t} to firewall"',
              f"set / interface {port} subinterface {tid} vlan encap single-tagged vlan-id {tid}",
              f"set / interface {port} subinterface {tid} ipv4 admin-state enable",
              f"set / interface {port} subinterface {tid} ipv4 address {me}/31",
              f"set / network-instance {v} interface {port}.{tid}",
              f"{bg} autonomous-system {leaf_as(name)}",
              f"{bg} router-id {loopback(name)}",
              f"{bg} afi-safi ipv4-unicast admin-state enable",
              # prefer the firewall's default over the other border's Type-5
              # copy (both 170 by default), so both borders advertise it: ECMP
              f"{bg} preference ebgp 100",
              f"{bg} group fw peer-as {fw_as}",
              f"{bg} group fw export-policy [ to-fw ]",
              f"{bg} group fw import-policy [ from-fw ]",
              f"{bg} neighbor {fw} peer-group fw",
              f'{bg} neighbor {fw} description "firewall {t}"']


def leak(L, name, ph):
    """Route leaking inside the fabric (shared services, variant A), done
    locally on the leaf: the leaf carries both VRFs (the source VRF without
    ports, it only imports its own RT) and copies the listed prefixes from one
    VRF into the other with inter-instance policies. Leaked routes are not
    re-advertised into EVPN. (SR Linux 24.10.7 rejected importing a foreign
    RT into an IP-VRF with a bgp-vpn import-policy, see the phase 3b README.)"""
    for src, dst, prefix in ph.get("leak", {}).get(name, []):
        s_, d_ = vrf(src), vrf(dst)
        pol = f"leak-{s_}-to-{d_}"
        L += [f"set / routing-policy prefix-set {pol} prefix {prefix}",
              f"set / routing-policy policy {pol} statement 10 match prefix-set {pol}",
              f"set / routing-policy policy {pol} statement 10 action policy-result accept",
              f"set / routing-policy policy {pol} default-action policy-result reject",
              f"set / network-instance {s_} inter-instance-policies apply-policy export-policy {pol}",
              f"set / network-instance {d_} inter-instance-policies apply-policy import-policy {pol}"]


def server_bgp(L, name, ph):
    """eBGP from a tenant VRF to servers on the leaf (anycast VIP, phase 4):
    the leaf accepts only /32s from 10.9.100.0/24, sends nothing, and keeps
    all equal paths (servers have different AS numbers)."""
    t, peers = ph["server_bgp"][name]
    v, bg = vrf(t), f"set / network-instance {vrf(t)} protocols bgp"
    L += ["set / routing-policy prefix-set anycast-vips prefix 10.9.100.0/24 mask-length-range 32..32",
          "set / routing-policy policy from-servers statement 10 match prefix-set anycast-vips",
          "set / routing-policy policy from-servers statement 10 action policy-result accept",
          "set / routing-policy policy from-servers default-action policy-result reject",
          "set / routing-policy policy to-servers default-action policy-result reject",
          f"{bg} autonomous-system {leaf_as(name)}",
          f"{bg} router-id {loopback(name)}",
          f"{bg} afi-safi ipv4-unicast admin-state enable",
          f"{bg} afi-safi ipv4-unicast multipath allow-multiple-as true",
          f"{bg} afi-safi ipv4-unicast multipath maximum-paths 8",
          # local servers beat another leaf's Type-5 copy of the same VIP
          # (both 170 by default), so every server leaf advertises it
          f"{bg} preference ebgp 100",
          f"{bg} group servers import-policy [ from-servers ]",
          f"{bg} group servers export-policy [ to-servers ]"]
    for ip, asn, host in peers:
        L += [f"{bg} neighbor {ip} peer-group servers", f"{bg} neighbor {ip} peer-as {asn}",
              f'{bg} neighbor {ip} description "{host}"']


def esi(L, name, ph):
    """EVPN multihoming (phase 6): a LACP LAG to a dual-homed server, the same
    ESI, LACP system id and key on both leafs (the server sees one partner),
    all-active, so both leafs forward and remote leafs balance (aliasing)."""
    lag, members, es_id, sysmac = ph["esi"][name]
    L += [f"set / interface {lag} admin-state enable",
          f"set / interface {lag} lag lag-type lacp",
          f"set / interface {lag} lag lacp interval FAST",
          f"set / interface {lag} lag lacp lacp-mode ACTIVE",
          f"set / interface {lag} lag lacp admin-key 11",
          f"set / interface {lag} lag lacp system-id-mac {sysmac}",
          f"set / interface {lag} lag lacp system-priority 1"]
    for m in members:
        L += [f"set / interface {m} admin-state enable", f'set / interface {m} description "to srv-mh (LAG member)"',
              f"set / interface {m} ethernet aggregate-id {lag}"]
    es = "set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment es1"
    L += [f"{es} admin-state enable", f"{es} esi {es_id}", f"{es} multi-homing-mode all-active", f"{es} interface {lag}",
          "set / system network-instance protocols bgp-vpn bgp-instance 1"]
    for e in ph["nets"]:
        if name in e[2]:
            L.append(f"set / network-instance mac-vrf-{vlan_of(e[0], e[1])} protocols bgp-evpn bgp-instance 1 ecmp 2")


def fw_static(L, name, ph):
    """Border with static routing to the firewall (phase 5): one tagged
    sub-interface per VRF (VLAN = tenant number, 10.250.1.<2t>/31)."""
    port, tenants = ph["fw_static"][name]
    L += [f"set / interface {port} admin-state enable", f'set / interface {port} description "to firewall"',
          f"set / interface {port} vlan-tagging true"]
    for t in tenants:
        tid = TENANTS[t]
        L += [f"set / interface {port} subinterface {tid} type routed",
              f"set / interface {port} subinterface {tid} admin-state enable",
              f"set / interface {port} subinterface {tid} vlan encap single-tagged vlan-id {tid}",
              f"set / interface {port} subinterface {tid} ipv4 admin-state enable",
              f"set / interface {port} subinterface {tid} ipv4 address 10.250.1.{2 * tid}/31",
              f"set / network-instance {vrf(t)} interface {port}.{tid}"]


def ce_bgp(L, name, ph):
    """Customer edge router on a routed port in the customer VRF, eBGP. The
    leaf accepts the customer's own networks (192.168.0.0/16, /24 or longer)
    up to a prefix limit and sends the customer its fabric subnets."""
    t, port, me, peer, asn, maxp = ph["ce_bgp"][name]
    v, bg = vrf(t), f"set / network-instance {vrf(t)} protocols bgp"
    L += [f"set / interface {port} admin-state enable", f'set / interface {port} description "to CE of {t}"',
          f"set / interface {port} subinterface 0 ipv4 admin-state enable",
          f"set / interface {port} subinterface 0 ipv4 address {me}/31",
          f"set / network-instance {v} interface {port}.0",
          "set / routing-policy prefix-set customer-nets prefix 192.168.0.0/16 mask-length-range 24..32",
          "set / routing-policy prefix-set fabric-nets prefix 10.0.0.0/8 mask-length-range 24..24",
          "set / routing-policy policy from-ce statement 10 match prefix-set customer-nets",
          "set / routing-policy policy from-ce statement 10 action policy-result accept",
          "set / routing-policy policy from-ce default-action policy-result reject",
          "set / routing-policy policy to-ce statement 10 match prefix-set fabric-nets",
          "set / routing-policy policy to-ce statement 10 action policy-result accept",
          "set / routing-policy policy to-ce default-action policy-result reject",
          f"{bg} autonomous-system {leaf_as(name)}", f"{bg} router-id {loopback(name)}",
          f"{bg} afi-safi ipv4-unicast admin-state enable",
          f"{bg} preference ebgp 100",
          f"{bg} group ce import-policy [ from-ce ]", f"{bg} group ce export-policy [ to-ce ]",
          f"{bg} neighbor {peer} peer-group ce", f"{bg} neighbor {peer} peer-as {asn}",
          f'{bg} neighbor {peer} description "CE {t}"',
          f"{bg} neighbor {peer} afi-safi ipv4-unicast ipv4-unicast prefix-limit-received max-received-routes {maxp}",
          f"{bg} neighbor {peer} afi-safi ipv4-unicast ipv4-unicast prefix-limit-received warning-threshold-pct 80"]


# ---------------------------------------------------------------- phases
# Each phase lists its nodes and features.  Clients hang off ethernet-1/1+.
PHASES = {
    "p0-mini": dict(leafs=["leaf1", "leaf2"], borders=[], features={"static"}),
    "p1-underlay": dict(leafs=["leaf1", "leaf2"], borders=[], features={"bgp", "bgplab"}),
    "p2-l2vni": dict(leafs=["leaf1", "leaf2", "leaf3"], borders=[], features={"bgp", "evpn", "l2vni"}),
    # Phase 3a: VRFs corp/guest/mgmt, symmetric IRB, anycast gateway, DHCP relay.
    "p3a-vrf": dict(
        leafs=["leaf1", "leaf2", "leaf3"], borders=[], features={"bgp", "evpn", "l3"},
        nets=[("corp", 1, ["leaf1", "leaf2", "leaf3"]), ("corp", 2, ["leaf3"]),
              ("guest", 1, ["leaf1", "leaf2"]), ("mgmt", 1, ["leaf2"])],
        ports={"leaf1": [("ethernet-1/1", 101, "corp1"), ("ethernet-1/2", 201, "guest1"), ("ethernet-1/3", 101, "dhcp1")],
               "leaf2": [("ethernet-1/1", 101, "corp2"), ("ethernet-1/2", 201, "guest2"), ("ethernet-1/3", 101, "dhcp2"),
                         ("ethernet-1/4", 301, "mgmt2")],
               "leaf3": [("ethernet-1/1", 102, "srv3"), ("ethernet-1/2", 102, "dhcpsrv")]},
        dhcp_relay={101: "10.1.2.10"}),
    # Phase 3b: two border leafs, firewall, WAN, Type-5 default, shared services.
    "p3b-border": dict(
        leafs=["leaf1", "leaf3"], borders=["border1", "border2"], features={"bgp", "evpn", "l3"},
        nets=[("corp", 1, ["leaf1"]), ("guest", 1, ["leaf1"]), ("mgmt", 1, ["leaf3"]), ("shared", 1, ["leaf3"])],
        ports={"leaf1": [("ethernet-1/1", 101, "corp1"), ("ethernet-1/2", 201, "guest1")],
               "leaf3": [("ethernet-1/1", 901, "svc-dns"), ("ethernet-1/2", 301, "mgmt3")]},
        vrf_only={"border1": ["corp", "guest", "mgmt", "shared"], "border2": ["corp", "guest", "mgmt", "shared"],
                  "leaf1": ["shared"], "leaf3": ["corp"]},
        fw_link={"border1": "ethernet-1/1", "border2": "ethernet-1/1"},
        # variant A: corp <-> shared leaked in the fabric, only the service and
        # corp prefixes (never the default routes). guest uses variant B (firewall).
        leak={"leaf1": [("shared", "corp", "10.9.1.0/24 mask-length-range 24..32")],
              "leaf3": [("corp", "shared", "10.1.0.0/16 mask-length-range 24..32")]}),
    # Phase 4: load balancing. Service rack = VLAN 901 (shared) on leaf2+leaf3:
    # three web servers announce an anycast VIP by BGP, two HAProxy+keepalived
    # balancers share a VRRP VIP. Clients in corp on leaf1 (shared leaked in).
    "p4-lb": dict(
        leafs=["leaf1", "leaf2", "leaf3"], borders=[], features={"bgp", "evpn", "l3"},
        nets=[("corp", 1, ["leaf1"]), ("shared", 1, ["leaf2", "leaf3"])],
        ports={"leaf1": [("ethernet-1/1", 101, "corp1"), ("ethernet-1/2", 101, "corp2")],
               "leaf2": [("ethernet-1/1", 901, "srv1"), ("ethernet-1/2", 901, "lb1")],
               "leaf3": [("ethernet-1/1", 901, "srv2"), ("ethernet-1/2", 901, "srv3"), ("ethernet-1/3", 901, "lb2")]},
        vrf_only={"leaf1": ["shared"], "leaf2": ["corp"], "leaf3": ["corp"]},
        leak={"leaf1": [("shared", "corp", "10.9.0.0/16 mask-length-range 24..32")],
              "leaf2": [("corp", "shared", "10.1.0.0/16 mask-length-range 24..32")],
              "leaf3": [("corp", "shared", "10.1.0.0/16 mask-length-range 24..32")]},
        server_bgp={"leaf2": ("shared", [("10.9.1.11", 65411, "srv1")]),
                    "leaf3": ("shared", [("10.9.1.12", 65412, "srv2"), ("10.9.1.13", 65413, "srv3")])}),
    # Phase 5: hosting customers. cust-a and cust-b both use 10.0.0.0/24; a CE
    # router for cust-a (eBGP, prefix limit); shared DNS reached through the
    # border and a firewall that maps each customer to its own NAT range.
    # cust-c is onboarded at run time by tools/onboard.py (P5-06).
    "p5-customers": dict(
        leafs=["leaf1", "leaf2"], borders=["border1"], features={"bgp", "evpn", "l3"},
        nets=[("cust-a", 1, ["leaf1", "leaf2"], "10.0.0"), ("cust-b", 1, ["leaf1", "leaf2"], "10.0.0"),
              ("shared", 1, ["leaf2"])],
        ports={"leaf1": [("ethernet-1/1", 1101, "a-vm1"), ("ethernet-1/2", 1201, "b-vm1")],
               "leaf2": [("ethernet-1/1", 1101, "a-vm2"), ("ethernet-1/2", 1201, "b-vm2"), ("ethernet-1/4", 901, "svc-dns")]},
        vrf_only={"border1": ["cust-a", "cust-b", "shared"]},
        fw_static={"border1": ("ethernet-1/1", ["cust-a", "cust-b", "shared"])},
        vrf_static={"border1": [("cust-a", "10.9.1.53/32", "10.250.1.23"), ("cust-b", "10.9.1.53/32", "10.250.1.25"),
                                ("shared", "100.64.0.0/16", "10.250.1.19")]},
        ce_bgp={"leaf2": ("cust-a", "ethernet-1/3", "10.11.254.0", "10.11.254.1", 64611, 5)}),
    # Phase 6: operations. srv-mh is dual-homed (LACP) to leaf1+leaf2 with one
    # ESI (all-active); cl3 on leaf3 measures every failure.
    "p6-multihoming": dict(
        leafs=["leaf1", "leaf2", "leaf3"], borders=[], features={"bgp", "evpn", "l3"},
        nets=[("corp", 1, ["leaf1", "leaf2", "leaf3"])],
        ports={"leaf1": [("lag1", 101, "srv-mh")], "leaf2": [("lag1", 101, "srv-mh")],
               "leaf3": [("ethernet-1/1", 101, "cl3")]},
        esi={l: ("lag1", ["ethernet-1/1"], "00:11:22:33:44:55:66:77:88:01", "00:00:00:00:11:11") for l in ("leaf1", "leaf2")}),
}

ROUTED_CLIENT_NET = {"leaf1": "10.10.1.1/24", "leaf2": "10.10.2.1/24"}


def spine_cfg(name, ph):
    L, f = [], ph["features"]
    system(L, name)
    downs = ph["leafs"] + ph["borders"]
    for leaf in downs:
        mine, peer = p2p(name, leaf)
        port = f"ethernet-1/{port_index(leaf)}"
        iface(L, port, f"to {leaf} {UPLINKS[name].replace('ethernet-', 'e')}", f"{mine}/31",
              ip_mtu=FABRIC_IP_MTU if "evpn" in f else None)
        if "bgp" in f:
            bfd(L, port)
    if "static" in f and name == "spine1":
        for leaf in downs:
            _, peer = p2p(name, leaf)
            net = ROUTED_CLIENT_NET[leaf].rsplit(".", 1)[0] + ".0/24"
            L += [f"set / network-instance default next-hop-groups group via-{leaf} nexthop 1 ip-address {peer}",
                  f"set / network-instance default static-routes route {net} next-hop-group via-{leaf}"]
    if "bgp" in f:
        underlay_policy(L, f)
        bgp_base(L, name, SPINE_AS)
        for leaf in downs:
            _, peer = p2p(name, leaf)
            L += [f"set / network-instance default protocols bgp neighbor {peer} peer-group underlay",
                  f"set / network-instance default protocols bgp neighbor {peer} peer-as {leaf_as(leaf)}",
                  f'set / network-instance default protocols bgp neighbor {peer} description "{leaf}"']
    if "evpn" in f:
        overlay(L, name, downs, rr=True)
    L += ph.get("extra", {}).get(name, [])
    return L


def leaf_cfg(name, ph):
    L, f = [], ph["features"]
    system(L, name)
    for spine in SPINES:
        mine, peer = p2p(spine, name)
        port = UPLINKS[spine]
        iface(L, port, f"to {spine} e1-{port_index(name)}", f"{peer}/31",
              ip_mtu=FABRIC_IP_MTU if "evpn" in f else None)
        if "bgp" in f:
            bfd(L, port)
    client = "client" + str(LEAFS.get(name, 0))
    if "l3" in f:
        tenant_fabric(L, name, ph)
        if name in ph.get("fw_link", {}):
            border_fw(L, name, ph)
        leak(L, name, ph)
        if name in ph.get("server_bgp", {}):
            server_bgp(L, name, ph)
        if name in ph.get("esi", {}):
            esi(L, name, ph)
        if name in ph.get("fw_static", {}):
            fw_static(L, name, ph)
        if name in ph.get("ce_bgp", {}):
            ce_bgp(L, name, ph)
        for v, prefix, nh in ph.get("vrf_static", {}).get(name, []):
            g = f"via-{nh.replace('.', '-')}"
            L += [f"set / network-instance {vrf(v)} next-hop-groups group {g} nexthop 1 ip-address {nh}",
                  f"set / network-instance {vrf(v)} static-routes route {prefix} next-hop-group {g}"]
    elif "l2vni" in f:
        ports = [("ethernet-1/1", client)]
        if name in ("leaf1", "leaf2"):
            ports.append(("ethernet-1/2", "mobile host"))
        for port, peer in ports:
            L += [f"set / interface {port} admin-state enable",
                  f'set / interface {port} description "to {peer}"',
                  f"set / interface {port} subinterface 0 type bridged",
                  f"set / interface {port} subinterface 0 admin-state enable"]
        l2vni(L, name, [f"{p}.0" for p, _ in ports])
    else:
        iface(L, "ethernet-1/1", f"to {client}", ROUTED_CLIENT_NET[name])
    if "static" in f:
        other = [l for l in ph["leafs"] if l != name][0]
        mine, _ = p2p("spine1", name)
        net = ROUTED_CLIENT_NET[other].rsplit(".", 1)[0] + ".0/24"
        L += [f"set / network-instance default next-hop-groups group via-spine1 nexthop 1 ip-address {mine}",
              f"set / network-instance default static-routes route {net} next-hop-group via-spine1"]
    if "bgp" in f:
        underlay_policy(L, f)
        origin_community(L, name)
        bgp_base(L, name, leaf_as(name), export="underlay-out")
        L.append(f"set / network-instance default protocols bgp group underlay peer-as {SPINE_AS}")
        for spine in SPINES:
            mine, _ = p2p(spine, name)
            L += [f"set / network-instance default protocols bgp neighbor {mine} peer-group underlay",
                  f'set / network-instance default protocols bgp neighbor {mine} description "{spine}"']
    if "evpn" in f:
        overlay(L, name, SPINES)
    if "bgplab" in f and name == "leaf1":
        bgp_lab(L)
    L += ph.get("extra", {}).get(name, [])
    return L


TEST_PEERS = {"ext1": (64501, 1, 100), "ext2": (64502, 2, 200), "ext3": (64503, 3, 200)}


def bgp_lab(L):
    """Phase 1 BGP deep-dive add-ons on leaf1, kept apart from the underlay:
    three FRR test peers (ethernet-1/3..5) that all send 203.0.113.0/24, and
    the test prefix 198.51.100.0/24 tagged with communities."""
    b = "set / network-instance default protocols bgp"
    L += ["set / routing-policy prefix-set doc-203 prefix 203.0.113.0/24 mask-length-range exact",
          "set / routing-policy policy reject-all default-action policy-result reject"]
    for peer, (asn, i, lp) in TEST_PEERS.items():
        port = f"ethernet-1/{2 + i}"
        L += [f"set / interface {port} admin-state enable",
              f'set / interface {port} description "to test peer {peer}"',
              f"set / interface {port} subinterface 0 ipv4 admin-state enable",
              f"set / interface {port} subinterface 0 ipv4 address 10.253.{i}.0/31",
              f"set / network-instance default interface {port}.0",
              f"set / routing-policy policy from-{peer} statement 10 match prefix-set doc-203",
              f"set / routing-policy policy from-{peer} statement 10 action policy-result accept",
              f"set / routing-policy policy from-{peer} statement 10 action bgp local-preference set {lp}",
              f"set / routing-policy policy from-{peer} default-action policy-result reject",
              f"{b} neighbor 10.253.{i}.1 peer-group testpeers",
              f"{b} neighbor 10.253.{i}.1 peer-as {asn}",
              f'{b} neighbor 10.253.{i}.1 description "test peer {peer}"',
              f"{b} neighbor 10.253.{i}.1 import-policy [ from-{peer} ]"]
    L += [f"{b} group testpeers export-policy [ reject-all ]",
          "set / interface lo0 admin-state enable",
          "set / interface lo0 subinterface 1 ipv4 admin-state enable",
          "set / interface lo0 subinterface 1 ipv4 address 198.51.100.1/24",
          "set / network-instance default interface lo0.1",
          "set / routing-policy prefix-set doc-198 prefix 198.51.100.0/24 mask-length-range exact",
          "set / routing-policy community-set test-tags member [ 64500:100 64500:1:100 ]",
          "set / routing-policy policy underlay-out statement 30 match prefix-set doc-198",
          "set / routing-policy policy underlay-out statement 30 action policy-result accept",
          "set / routing-policy policy underlay-out statement 30 action bgp communities add test-tags"]


def l2vni(L, name, ifaces, vlan=101, vni=10101, evi=101):
    ni = f"mac-vrf-{vlan}"
    L += [f"set / tunnel-interface vxlan1 vxlan-interface {vlan} type bridged",
          f"set / tunnel-interface vxlan1 vxlan-interface {vlan} ingress vni {vni}",
          f"set / tunnel-interface vxlan1 vxlan-interface {vlan} egress source-ip use-system-ipv4-address",
          f"set / network-instance {ni} type mac-vrf",
          f"set / network-instance {ni} admin-state enable"]
    L += [f"set / network-instance {ni} interface {i}" for i in ifaces]
    L += [f"set / network-instance {ni} vxlan-interface vxlan1.{vlan}",
          # ARP suppression: answer ARP locally from EVPN-learned IP/MAC pairs.
          # Unknown targets are still flooded (default); turning that off
          # black-holes hosts whose IP the fabric has not learned yet.
          f"set / network-instance {ni} bridge-table proxy-arp admin-state enable",
          f"set / network-instance {ni} bridge-table proxy-arp dynamic-learning admin-state enable",
          f"set / network-instance {ni} protocols bgp-evpn bgp-instance 1 admin-state enable",
          f"set / network-instance {ni} protocols bgp-evpn bgp-instance 1 vxlan-interface vxlan1.{vlan}",
          f"set / network-instance {ni} protocols bgp-evpn bgp-instance 1 evi {evi}",
          f"set / network-instance {ni} protocols bgp-vpn bgp-instance 1 route-target export-rt target:{SPINE_AS}:{vni}",
          f"set / network-instance {ni} protocols bgp-vpn bgp-instance 1 route-target import-rt target:{SPINE_AS}:{vni}"]


def main(phases):
    for p in phases:
        ph = PHASES[p]
        out = ROOT / "phases" / p / "configs"
        out.mkdir(parents=True, exist_ok=True)
        for s in SPINES:
            (out / f"{s}.cli").write_text("\n".join(spine_cfg(s, ph)) + "\n")
        for l in ph["leafs"] + ph["borders"]:
            (out / f"{l}.cli").write_text("\n".join(leaf_cfg(l, ph)) + "\n")
        print(f"{p}: {len(SPINES) + len(ph['leafs']) + len(ph['borders'])} configs")


if __name__ == "__main__":
    main(sys.argv[1:] or list(PHASES))
