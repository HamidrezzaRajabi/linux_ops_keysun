INV ?= inventories/lab
PB  ?= playbooks/site.yml
LIMIT ?=

.PHONY: lint syntax check diff apply idempotence
lint:
	yamllint .
	ansible-lint
syntax:
	ansible-playbook -i $(INV) $(PB) --syntax-check
check:
	ansible-playbook -i $(INV) $(PB) --check --diff $(if $(LIMIT),--limit $(LIMIT))
apply:
	ansible-playbook -i $(INV) $(PB) $(if $(LIMIT),--limit $(LIMIT))
# Second run must report changed=0 for every host.
idempotence:
	./scripts/idempotence-check.sh $(INV) $(PB) $(LIMIT)
