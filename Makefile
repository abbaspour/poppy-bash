.DEFAULT_GOAL := help

.PHONY: help identity keys jwks cimd serve tunnel check

help:
	@echo "make identity   # keys + jwks.json + cimd.json"
	@echo "make serve      # serve web/public on localhost (POPPY_WEB_PORT, default 1990)"
	@echo "make tunnel     # expose it through the Cloudflare tunnel (see README)"
	@echo "make check      # shellcheck"

identity: keys jwks cimd

keys:
	./keys/gen-keys.sh

jwks:
	./keys/build-jwks.sh

cimd:
	./web/build-cimd.sh

serve:
	$(MAKE) -C web server

tunnel:
	$(MAKE) -C web tunnel

check:
	shellcheck --shell bash --severity=warning *.sh jwt/*.sh keys/*.sh web/*.sh web/public/cgi-bin/*.sh lib/common.sh
