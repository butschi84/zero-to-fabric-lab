#!/usr/bin/env python3
"""Configs for phase 8 (two sites + DCI + branch), from one plan.

Site A keeps the fabric numbering of phases 1-6 (loopbacks 10.255.0.x, spine
AS 65000, overlay AS 65500); site B mirrors it one "page" up (loopbacks
10.255.1.x, spine AS 65010, leaf AS 651NN+10, overlay AS 65510); the branch
is page 2 (br1 = 10.255.2.11, AS 65120, overlay AS 65520). Tenants, VLANs,
VNIs and route targets are the SAME everywhere (gen_configs.py), so a VNI
means the same segment in every site.

DCI variant B: the border gateways (two per site) exchange EVPN routes over
eBGP across the WAN and leave the next hop unchanged; VXLAN runs end to end
leaf to leaf (no re-origination). The branch router br1 (SR Linux, because
FRR has no kernel VRF on Docker Desktop) is a VTEP of its own: its VRFs corp
and guest ride as L3VNIs 50001/50002 over IPsec. IPsec is strongSwan in
Linux containers (ipsec-br in the branch, ipsec-a / ipsec-b as concentrators
in the two sites), route-based (VTI); FRR on them carries only the underlay
(loopbacks). Two independent WAN paths: wan1 (ISP 1, branch <-> site A,
primary) and wan2 (ISP 2, branch <-> site B, backup).

usage: python3 tools/gen_p8.py   -> phases/p8-multisite/configs/
"""
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gen_configs as g

OUT = g.ROOT / "phases" / "p8-multisite" / "configs"

# per site: spine, leaf, gateways (name, node id, underlay AS, spine port, WAN address)
SITES = {
    "a": dict(spine=("spine-a", 1, 65000), leaf=("leaf-a1", 11, 65101),
              gws=[("gw-a", 21, 65201, "ethernet-1/7", "10.253.0.1"), ("gw-a2", 22, 65202, "ethernet-1/8", "10.253.0.3")],
              lo="10.255.0", p2p="10.254.1", overlay=65500, hub=("ipsec-a", 65321)),
    "b": dict(spine=("spine-b", 1, 65010), leaf=("leaf-b1", 11, 65111),
              gws=[("gw-b", 21, 65211, "ethernet-1/7", "10.253.0.2"), ("gw-b2", 22, 65212, "ethernet-1/8", "10.253.0.4")],
              lo="10.255.1", p2p="10.254.11", overlay=65510, hub=("ipsec-b", 65322)),
}
BRANCH = dict(name="br1", nid=11, asn=65120, lo="10.255.2.11", overlay=65520,
              cpe=("ipsec-br", 65320), uplink="10.254.21")
# corp 01 stretched, 02 only A, 03 only B; guest 01 only A (reached from the branch's guest VRF)
NETS = {"a": [("corp", 1), ("corp", 2), ("guest", 1)], "b": [("corp", 1), ("corp", 3)]}
PORTS = {"a": [("ethernet-1/1", 101, "a-c1"), ("ethernet-1/2", 102, "a-c2"), ("ethernet-1/3", 201, "a-g1"), ("ethernet-1/4", 102, "srv-a")],
         "b": [("ethernet-1/1", 101, "b-c1"), ("ethernet-1/2", 103, "b-c3"), ("ethernet-1/3", 103, "srv-b")]}
# anycast service (P8-18): the same VIP from a web server in each site, BGP to its leaf in VRF corp
SERVERS = {"a": ("srv-a", "10.1.2.20", 65411, "10.1.2.1"), "b": ("srv-b", "10.1.3.20", 65412, "10.1.3.1")}
VIP = "10.9.100.10"
# branch LANs: routed sub-interfaces straight in the IP-VRFs (no L2 leaves the branch)
BR_NETS = [("ethernet-1/1", "corp", "10.1.10.1/24", "br-c1"), ("ethernet-1/2", "guest", "10.2.10.1/24", "br-g1")]
WAN1, WAN2 = ("198.51.100", 29), ("203.0.113", 29)      # documentation ranges = two ISPs
VTI = {"a": "10.252.1", "b": "10.252.2"}               # /30 inside each tunnel: hub .1, branch .2
PSK = "zero-to-fabric-lab-only"                        # lab secret, never reuse

IDS = {}
for sk, s in SITES.items():
    IDS[s["spine"][0]] = (sk, s["spine"][1], s["spine"][2])
    IDS[s["leaf"][0]] = (sk, s["leaf"][1], s["leaf"][2])
    for name, nid, asn, *_ in s["gws"]:
        IDS[name] = (sk, nid, asn)
IDS[BRANCH["name"]] = ("br", BRANCH["nid"], BRANCH["asn"])
PAGE = {"a": 0, "b": 100, "br": 200}
# tenant_fabric()/ip_vrf() derive lo1 addresses from node_id(): 10.<t>.255.<id>
g.node_id = lambda n: IDS[n][1] + PAGE[IDS[n][0]]
lo = lambda n: BRANCH["lo"] if n == BRANCH["name"] else f"{SITES[IDS[n][0]]['lo']}.{IDS[n][1]}"
BGP = "set / network-instance default protocols bgp"


def base(L, n, links):
    asn = IDS[n][2]
    L += [f"set / system name host-name {n}", "set / interface system0 admin-state enable",
          "set / interface system0 subinterface 0 ipv4 admin-state enable",
          f"set / interface system0 subinterface 0 ipv4 address {lo(n)}/32",
          "set / network-instance default type default", "set / network-instance default interface system0.0",
          "set / routing-policy prefix-set loopbacks prefix 10.255.0.0/16 mask-length-range 32..32",
          "set / routing-policy policy underlay statement 10 match prefix-set loopbacks",
          "set / routing-policy policy underlay statement 10 action policy-result accept",
          f"{BGP} autonomous-system {asn}", f"{BGP} router-id {lo(n)}",
          f"{BGP} afi-safi ipv4-unicast admin-state enable",
          f"{BGP} afi-safi ipv4-unicast multipath allow-multiple-as true",
          f"{BGP} afi-safi ipv4-unicast multipath maximum-paths 8",
          f"{BGP} group underlay export-policy [ underlay ]", f"{BGP} group underlay import-policy [ underlay ]",
          f"{BGP} group underlay failure-detection enable-bfd true", f"{BGP} group underlay failure-detection fast-failover true"]
    for port, me, peer, pas, desc in links:
        L += [f"set / interface {port} admin-state enable", f'set / interface {port} description "{desc}"',
              f"set / interface {port} subinterface 0 ipv4 admin-state enable",
              f"set / interface {port} subinterface 0 ipv4 address {me}",
              f"set / interface {port} subinterface 0 ip-mtu {1500 if 'WAN' in desc else 9000}",
              f"set / network-instance default interface {port}.0",
              f"{BGP} neighbor {peer} peer-group underlay", f"{BGP} neighbor {peer} peer-as {pas}",
              f'{BGP} neighbor {peer} description "{desc}"']
        g.bfd(L, port)


def overlay(L, n, sk, peers, rr=False):
    s = SITES[sk]
    L += [f"{BGP} group overlay peer-as {s['overlay']}", f"{BGP} group overlay local-as as-number {s['overlay']}",
          f"{BGP} group overlay local-as prepend-global-as false", f"{BGP} group overlay afi-safi evpn admin-state enable",
          f"{BGP} group overlay afi-safi ipv4-unicast admin-state disable", f"{BGP} group overlay transport local-address {lo(n)}"]
    if rr:
        L += [f"{BGP} group overlay route-reflector client true", f"{BGP} group overlay route-reflector cluster-id {lo(n)}"]
    L += [f"{BGP} neighbor {lo(p)} peer-group overlay" for p in peers]


def ebgp_evpn(L, n, group, local_as, peers):
    """Multihop eBGP-EVPN between loopbacks, next hop unchanged (DCI, branch).
    peers: [(name, peer_as)]"""
    L += [f"{BGP} group {group} local-as as-number {local_as}", f"{BGP} group {group} local-as prepend-global-as false",
          f"{BGP} group {group} afi-safi evpn admin-state enable", f"{BGP} group {group} afi-safi ipv4-unicast admin-state disable",
          f"{BGP} group {group} transport local-address {lo(n)}", f"{BGP} group {group} multihop admin-state enable",
          f"{BGP} group {group} multihop maximum-hops 6", f"{BGP} group {group} next-hop-self false",
          # eBGP sends and accepts nothing without a policy (ebgp-default-policy)
          "set / routing-policy policy accept-all default-action policy-result accept",
          f"{BGP} group {group} export-policy [ accept-all ]", f"{BGP} group {group} import-policy [ accept-all ]"]
    for p, pas in peers:
        L += [f"{BGP} neighbor {lo(p)} peer-group {group}", f"{BGP} neighbor {lo(p)} peer-as {pas}",
              f'{BGP} neighbor {lo(p)} description "{group} to {p}"']


def server_bgp(L, leaf, srv):
    """eBGP from VRF corp to the local web server: accept only /32s of the
    anycast range, send nothing (as phase 4)."""
    name, ip, asn, _ = srv
    bg = "set / network-instance corp protocols bgp"
    L += ["set / routing-policy prefix-set anycast-vips prefix 10.9.100.0/24 mask-length-range 32..32",
          "set / routing-policy policy from-servers statement 10 match prefix-set anycast-vips",
          "set / routing-policy policy from-servers statement 10 action policy-result accept",
          "set / routing-policy policy from-servers default-action policy-result reject",
          "set / routing-policy policy to-servers default-action policy-result reject",
          f"{bg} autonomous-system {IDS[leaf][2]}", f"{bg} router-id {lo(leaf)}",
          f"{bg} afi-safi ipv4-unicast admin-state enable",
          f"{bg} preference ebgp 100",
          f"{bg} group servers import-policy [ from-servers ]", f"{bg} group servers export-policy [ to-servers ]",
          f"{bg} neighbor {ip} peer-group servers", f"{bg} neighbor {ip} peer-as {asn}", f'{bg} neighbor {ip} description "{name}"']


def gw_vrfs(L, gw):
    # SR Linux passes on only EVPN routes it imports itself (a route no local
    # VRF imports stays "Rejected_Route" even with keep-all-routes), so each
    # gateway carries the IP-VRFs corp and guest (no interfaces) and the
    # MAC-VRF of the stretched network 01 (no ports, no IRB). No MAC-VRF for a
    # site-local network: it would make the gateway a VTEP of it and pull its
    # broadcasts over the WAN.
    L.append(f"{BGP} afi-safi evpn evpn keep-all-routes true")
    vlan = g.vlan_of("corp", 1)
    g.l2vni(L, gw, [], vlan=vlan, vni=10000 + vlan, evi=vlan)
    g.ip_vrf(L, gw, "corp", [])
    g.ip_vrf(L, gw, "guest", [])


def srl_configs():
    for sk, s in SITES.items():
        other = SITES["b" if sk == "a" else "a"]
        sp, lf, P = s["spine"][0], s["leaf"][0], s["p2p"]
        gws = [x[0] for x in s["gws"]]
        # spine: e1-1 leaf (.0/.1), e1-7 / e1-8 gateways (.12/.13, .14/.15)
        L = []
        links = [("ethernet-1/1", f"{P}.0/31", f"{P}.1", IDS[lf][2], f"to {lf}")]
        for i, (gw, _, gas, port, _) in enumerate(s["gws"]):
            links.append((port, f"{P}.{12 + 2 * i}/31", f"{P}.{13 + 2 * i}", gas, f"to {gw}"))
        base(L, sp, links)
        overlay(L, sp, sk, [lf] + gws, rr=True)
        (OUT / f"{sp}.cli").write_text("\n".join(L) + "\n")
        # leaf
        L = []
        base(L, lf, [("ethernet-1/49", f"{P}.1/31", f"{P}.0", IDS[sp][2], f"to {sp}")])
        overlay(L, lf, sk, [sp])
        g.tenant_fabric(L, lf, dict(nets=[(t, n, [lf]) for t, n in NETS[sk]], ports={lf: PORTS[sk]}))
        server_bgp(L, lf, SERVERS[sk])
        (OUT / f"{lf}.cli").write_text("\n".join(L) + "\n")
        # gateways: underlay to the spine, over the WAN to both gateways of the
        # other site, to the site's IPsec concentrator; overlay to the RR;
        # DCI eBGP-EVPN to the other site's gateways; branch eBGP-EVPN to br1
        hub, hub_as = s["hub"]
        for i, (gw, _, _, _, wan_ip) in enumerate(s["gws"]):
            L = []
            links = [("ethernet-1/49", f"{P}.{13 + 2 * i}/31", f"{P}.{12 + 2 * i}", IDS[sp][2], f"to {sp}")]
            for ogw, _, oas, _, owan in other["gws"]:
                links.append(("ethernet-1/1", None, owan, oas, f"WAN to {ogw}"))
            links.append(("ethernet-1/2", f"{P}.{21 + 2 * i}/31", f"{P}.{20 + 2 * i}", hub_as, f"to {hub}"))
            # one WAN port, several peers on it: address only once
            L2, seen = [], set()
            base(L2, gw, [])
            L += L2
            for port, me, peer, pas, desc in links:
                if port not in seen:
                    seen.add(port)
                    addr = me or f"{wan_ip}/29"
                    L += [f"set / interface {port} admin-state enable",
                          f'set / interface {port} description "{"WAN (DCI)" if "WAN" in desc else desc}"',
                          f"set / interface {port} subinterface 0 ipv4 admin-state enable",
                          f"set / interface {port} subinterface 0 ipv4 address {addr}",
                          f"set / interface {port} subinterface 0 ip-mtu {1500 if 'WAN' in desc else 9000}",
                          f"set / network-instance default interface {port}.0"]
                    # BFD on every link, also towards the FRR concentrator: a stopped SR Linux
                    # node keeps its links up (the netns lives in a sidecar container),
                    # so without BFD the peer only notices when the hold timer expires
                    g.bfd(L, port)
                L += [f"{BGP} neighbor {peer} peer-group underlay", f"{BGP} neighbor {peer} peer-as {pas}",
                      f'{BGP} neighbor {peer} description "{desc}"']
            overlay(L, gw, sk, [sp])
            ebgp_evpn(L, gw, "dci", s["overlay"], [(o[0], other["overlay"]) for o in other["gws"]])
            ebgp_evpn(L, gw, "branch", s["overlay"], [(BRANCH["name"], BRANCH["overlay"])])
            gw_vrfs(L, gw)
            (OUT / f"{gw}.cli").write_text("\n".join(L) + "\n")
    # branch router: underlay to its IPsec box, eBGP-EVPN to all four gateways,
    # VRFs corp and guest with the branch LANs as routed sub-interfaces
    br, U = BRANCH["name"], BRANCH["uplink"]
    L = []
    base(L, br, [("ethernet-1/49", f"{U}.1/31", f"{U}.0", BRANCH["cpe"][1], f"to {BRANCH['cpe'][0]}")])
    ebgp_evpn(L, br, "hubs", BRANCH["overlay"], [(gw[0], s["overlay"]) for s in SITES.values() for gw in s["gws"]])
    for port, t, addr, host in BR_NETS:
        L += [f"set / interface {port} admin-state enable", f'set / interface {port} description "to {host}"',
              f"set / interface {port} subinterface 0 admin-state enable",
              f"set / interface {port} subinterface 0 ipv4 admin-state enable",
              f"set / interface {port} subinterface 0 ipv4 address {addr}"]
    for t in ("corp", "guest"):
        g.ip_vrf(L, br, t, [f"{p}.0" for p, tt, _, _ in BR_NETS if tt == t])
    (OUT / f"{br}.cli").write_text("\n".join(L) + "\n")


FRR_HEAD = """frr defaults datacenter
hostname {h}
log stdout informational
ip prefix-list LOOPS seq 10 permit 10.255.0.0/16 ge 32
ip prefix-list BRANCH seq 10 permit 10.255.2.0/24 ge 32
"""
BFD = """bfd
 profile lan
  detect-multiplier 3
  receive-interval 1000
  transmit-interval 1000
 exit
 profile tunnel
  detect-multiplier 3
  receive-interval 300
  transmit-interval 300
 exit
exit
"""


def frr_configs():
    d = OUT / "frr"; d.mkdir(exist_ok=True)
    cpe, cpe_as = BRANCH["cpe"]; U = BRANCH["uplink"]
    # branch IPsec box: WAN 1 (site A) primary, WAN 2 (site B) backup. Only the
    # branch's own loopbacks go into the tunnels, so the branch never becomes
    # a transit path between the sites.
    c = FRR_HEAD.format(h=cpe) + f"""route-map FROM-WAN1 permit 10
 match ip address prefix-list LOOPS
 set local-preference 200
route-map FROM-WAN2 permit 10
 match ip address prefix-list LOOPS
route-map TO-WAN1 permit 10
 match ip address prefix-list BRANCH
route-map TO-WAN2 permit 10
 match ip address prefix-list BRANCH
 set as-path prepend {cpe_as} {cpe_as} {cpe_as}
route-map LAN permit 10
 match ip address prefix-list LOOPS
router bgp {cpe_as}
 bgp router-id {U}.0
 no bgp ebgp-requires-policy
 neighbor {U}.1 remote-as {BRANCH['asn']}
 neighbor {U}.1 description br1
 neighbor {U}.1 bfd profile lan
 neighbor {VTI['a']}.1 remote-as {SITES['a']['hub'][1]}
 neighbor {VTI['a']}.1 description ipsec-a over WAN 1 (vti1)
 neighbor {VTI['a']}.1 bfd profile tunnel
 neighbor {VTI['b']}.1 remote-as {SITES['b']['hub'][1]}
 neighbor {VTI['b']}.1 description ipsec-b over WAN 2 (vti2)
 neighbor {VTI['b']}.1 bfd profile tunnel
 address-family ipv4 unicast
  neighbor {U}.1 route-map LAN in
  neighbor {U}.1 route-map LAN out
  neighbor {VTI['a']}.1 route-map FROM-WAN1 in
  neighbor {VTI['a']}.1 route-map TO-WAN1 out
  neighbor {VTI['b']}.1 route-map FROM-WAN2 in
  neighbor {VTI['b']}.1 route-map TO-WAN2 out
 exit-address-family
exit
""" + BFD
    (d / f"{cpe}.conf").write_text(c)
    for sk, s in SITES.items():
        hub, hub_as = s["hub"]; P = s["p2p"]
        nb = "".join(f" neighbor {P}.{21 + 2 * i} remote-as {gas}\n neighbor {P}.{21 + 2 * i} description {gw}\n"
                     f" neighbor {P}.{21 + 2 * i} bfd profile lan\n"
                     for i, (gw, _, gas, _, _) in enumerate(s["gws"]))
        af = "".join(f"  neighbor {P}.{21 + 2 * i} route-map LOOPS in\n  neighbor {P}.{21 + 2 * i} route-map LOOPS out\n"
                     for i in range(len(s["gws"])))
        c = FRR_HEAD.format(h=hub) + f"""route-map LOOPS permit 10
 match ip address prefix-list LOOPS
route-map FROM-BRANCH permit 10
 match ip address prefix-list BRANCH
router bgp {hub_as}
 bgp router-id {P}.20
 no bgp ebgp-requires-policy
{nb} neighbor {VTI[sk]}.2 remote-as {cpe_as}
 neighbor {VTI[sk]}.2 description ipsec-br (branch)
 neighbor {VTI[sk]}.2 bfd profile tunnel
 address-family ipv4 unicast
{af}  neighbor {VTI[sk]}.2 route-map FROM-BRANCH in
  neighbor {VTI[sk]}.2 route-map LOOPS out
 exit-address-family
exit
""" + BFD
        (d / f"{hub}.conf").write_text(c)
    for sk, (name, ip, asn, gwip) in SERVERS.items():
        leaf = SITES[sk]["leaf"]
        # site B is the standby site: its server announces the VIP with a longer AS path
        pre = "" if sk == "a" else f" set as-path prepend {asn} {asn}\n"
        c = f"""! {name}: web server in site {sk.upper()} that announces the anycast VIP {VIP}/32 to its leaf
! (VRF corp, leaf AS {leaf[2]}). Site B's copy is prepended: A serves while it is up.
frr defaults datacenter
hostname {name}
log stdout informational
ip prefix-list VIP seq 10 permit {VIP}/32
route-map ANNOUNCE permit 10
 match ip address prefix-list VIP
{pre}router bgp {asn}
 bgp router-id {ip}
 no bgp ebgp-requires-policy
 neighbor {gwip} remote-as {leaf[2]}
 neighbor {gwip} description leaf anycast gateway
 address-family ipv4 unicast
  network {VIP}/32
  neighbor {gwip} route-map ANNOUNCE out
 exit-address-family
exit
"""
        (d / f"{name}.conf").write_text(c)
    (d / "daemons").write_text("bgpd=yes\nzebra=yes\nstaticd=yes\nbfdd=yes\nvtysh_enable=yes\n"
                               'zebra_options="  -A 127.0.0.1 -s 90000000"\nbgpd_options="   -A 127.0.0.1"\n'
                               'staticd_options="-A 127.0.0.1"\nbfdd_options="   -A 127.0.0.1"\n')
    (d / "vtysh.conf").write_text("service integrated-vtysh-config\n")


def ipsec_configs():
    """strongSwan (swanctl) per box and an init script that builds the VTIs.
    Route-based IPsec: the SA covers 0.0.0.0/0 <-> 0.0.0.0/0, the mark binds it
    to one VTI, and BGP decides what goes into which tunnel."""
    d = OUT / "ipsec"; d.mkdir(exist_ok=True)
    (d / "strongswan.conf").write_text("""# routes come from BGP over the VTIs, not from charon
charon {
  load_modular = yes
  install_routes = no
  install_virtual_ip = no
  plugins {
    include strongswan.d/charon/*.conf
    # bypass-lan would exempt every connected subnet from IPsec, including
    # the /30 inside the VTI: BGP over the tunnel would never be encrypted
    # and the VTI drops it (tx carrier errors)
    bypass-lan {
      load = no
    }
  }
}
""")
    cpe = BRANCH["cpe"][0]
    ends = {"a": (WAN1, 1), "b": (WAN2, 2)}       # (wan subnet, vti key)
    def conn(name, me, peer, my_id, peer_id, key, initiator):
        return f"""  {name} {{
    version = 2
    local_addrs = {me}
    remote_addrs = {peer}
    proposals = aes256gcm16-prfsha256-ecp256
    dpd_delay = 2s
    # the peer may still be booting when the branch first tries: keep trying
    keyingtries = 0
    local {{
      auth = psk
      id = {my_id}
    }}
    remote {{
      auth = psk
      id = {peer_id}
    }}
    children {{
      {name} {{
        local_ts = 0.0.0.0/0
        remote_ts = 0.0.0.0/0
        mark_in = {key}
        mark_out = {key}
        esp_proposals = aes256gcm16-ecp256
        start_action = {"start" if initiator else "none"}
        dpd_action = restart
        close_action = start
      }}
    }}
  }}
"""
    secrets = lambda ids: "secrets {\n" + "".join(
        f"  ike-{i} {{\n    id-1 = {a}\n    id-2 = {b}\n    secret = \"{PSK}\"\n  }}\n" for i, (a, b) in enumerate(ids)) + "}\n"
    c = "connections {\n"
    for sk, ((net, _), key) in ends.items():
        c += conn(f"wan{key}", f"{net}.2", f"{net}.1", "branch1", f"dc-{sk}", key, True)
    c += "}\n" + secrets([("branch1", "dc-a"), ("branch1", "dc-b")])
    (d / f"{cpe}.swanctl.conf").write_text(c)
    for sk, ((net, _), key) in ends.items():
        hub = SITES[sk]["hub"][0]
        c = "connections {\n" + conn("branch1", f"{net}.1", f"{net}.2", f"dc-{sk}", "branch1", key, False) + "}\n" + secrets([(f"dc-{sk}", "branch1")])
        (d / f"{hub}.swanctl.conf").write_text(c)
    init = """#!/bin/sh
# IPsec box: addresses, one VTI per tunnel (key = strongSwan mark), charon.
# usage: ipsec-init.sh "<if>=<addr> ..." "<vti>:<key>:<local>:<remote>:<addr> ..."
set -e
sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0
ip route del default 2>/dev/null || true
for a in $1; do ip addr add "${a#*=}" dev "${a%%=*}"; done
for t in $2; do
  IFS=: read -r name key local remote addr <<EOF
$t
EOF
  ip link add "$name" type vti local "$local" remote "$remote" key "$key"
  ip addr add "$addr" dev "$name"
  ip link set "$name" up
  sysctl -qw "net.ipv4.conf.$name.disable_policy=1" "net.ipv4.conf.$name.rp_filter=0"
done
ipsec start >/dev/null 2>&1
for _ in $(seq 1 50); do [ -S /var/run/charon.vici ] && break; sleep 0.2; done
swanctl --load-all >/var/log/swanctl-load.log 2>&1
"""
    (d / "ipsec-init.sh").write_text(init)
    (d / "ipsec-init.sh").chmod(0o755)
    # per box: addresses and tunnels (containerlab exec does not keep quoted arguments)
    U = BRANCH["uplink"]
    boxes = {cpe: (f"eth1={U}.0/31 eth2={WAN1[0]}.2/29 eth3={WAN2[0]}.2/29",
                   f"vti1:1:{WAN1[0]}.2:{WAN1[0]}.1:{VTI['a']}.2/30 vti2:2:{WAN2[0]}.2:{WAN2[0]}.1:{VTI['b']}.2/30")}
    for sk, ((net, _), key) in ends.items():
        P = SITES[sk]["p2p"]
        boxes[SITES[sk]["hub"][0]] = (f"eth1={P}.20/31 eth3={P}.22/31 eth2={net}.1/29",
                                      f"vti{key}:{key}:{net}.1:{net}.2:{VTI[sk]}.1/30")
    wans = {cpe: "eth2 eth3", SITES["a"]["hub"][0]: "eth2", SITES["b"]["hub"][0]: "eth2"}
    for box, (addrs, tuns) in boxes.items():
        f = d / f"{box}-init.sh"
        f.write_text(f'#!/bin/sh\n# {box}: WAN ports at 1500 bytes, then addresses, VTIs, strongSwan\n'
                     f'for i in {wans[box]}; do ip link set $i mtu 1500; done\n'
                     f'exec /ipsec-init.sh "{addrs}" "{tuns}"\n')
        f.chmod(0o755)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    srl_configs(); frr_configs(); ipsec_configs()
    print("p8-multisite: SR Linux, FRR and strongSwan configs")


if __name__ == "__main__":
    main()
