.PHONY: verify sync

verify:
	./scripts/verify-consumption.sh

sync:
	@test -n "$(TAG)" || (echo "TAG=v<ver>+rewrap.<n> required — e.g. make sync TAG=v0.7.3+rewrap.1" >&2; exit 1)
	./scripts/sync-litertlm-swift.sh $(TAG)
	$(MAKE) verify
