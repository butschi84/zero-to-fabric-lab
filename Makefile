# Zero to Fabric lab. Every phase is its own containerlab topology.
#   make tools                      build the small Linux host image (once)
#   make deploy   PHASE=p1-underlay
#   make evidence PHASE=p1-underlay  regenerate evidence/<phase>/
#   make destroy  PHASE=p1-underlay
#   make configs                    regenerate all SR Linux startup configs
#   make load / make load-stop      phase 9 background traffic
#   make fault F=link|mac|mtu|sitecut|onchange|wan|all   phase 9 fault scenarios
PHASE ?= p0-mini
CLAB  := $(CURDIR)/scripts/clab.sh

.PHONY: tools deploy destroy evidence configs inspect graph list fault load load-stop
tools:
	docker build -q -t ztf-tools:1 images/ztf-tools
	docker build -q -t ztf-frr:1 images/ztf-frr

deploy: tools
	cd phases/$(PHASE) && $(CLAB) deploy -t topology.clab.yml
	@if [ -x phases/$(PHASE)/obs/up.sh ]; then phases/$(PHASE)/obs/up.sh; fi

destroy:
	@if [ -x phases/$(PHASE)/obs/down.sh ]; then phases/$(PHASE)/obs/down.sh; fi
	cd phases/$(PHASE) && $(CLAB) destroy -t topology.clab.yml --cleanup

inspect:
	cd phases/$(PHASE) && $(CLAB) inspect -t topology.clab.yml

graph:
	cd phases/$(PHASE) && $(CLAB) graph -t topology.clab.yml

evidence:
	bash phases/$(PHASE)/evidence.sh

# phase 9 background traffic: make load (start) / make load-stop
load:
	bash phases/p9-observability/load.sh start
load-stop:
	bash phases/p9-observability/load.sh stop

# phase 9 fault scenarios: make fault F=link|mac|mtu|sitecut|onchange|wan|all
F ?= all
fault:
	bash phases/p9-observability/faults.sh $(F)

configs:
	python3 tools/gen_configs.py

list:
	@ls phases
