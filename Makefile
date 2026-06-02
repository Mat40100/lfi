# Helpers for the Ghost stack. Run `make help` for a list of targets.

COMPOSE := docker compose

.PHONY: help dev prod down logs ps

help: ## Show available targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

dev: .env ## Start the stack for local testing (http://localhost)
	$(COMPOSE) up -d --build

prod: .env ## Launch the production stack (GHOST_URL must point at the server's public IP or domain)
	@grep -Eq '^GHOST_URL=https?://' .env \
		|| { echo 'error: set GHOST_URL in .env'; exit 1; }
	@! grep -Eq '^GHOST_URL=https?://(localhost|127\.0\.0\.1)' .env \
		|| { echo 'error: GHOST_URL still points at localhost — set http://<public-ip> or https://<domain> in .env'; exit 1; }
	@if grep -Eq '^GHOST_URL=https://' .env; then \
		grep -Eq '^CADDY_SITE_ADDRESS=[^:[:space:]]' .env \
			|| { echo 'error: HTTPS requires CADDY_SITE_ADDRESS=<your-domain> in .env'; exit 1; }; \
	fi
	$(COMPOSE) up -d --build

down: ## Stop the stack
	$(COMPOSE) down

logs: ## Tail Ghost logs
	$(COMPOSE) logs -f ghost

ps: ## Show service status
	$(COMPOSE) ps

.env:
	@echo 'error: .env missing — run `cp .env.example .env` and set passwords'; exit 1
