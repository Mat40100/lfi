# Helpers for the Ghost stack. Run `make help` for a list of targets.

COMPOSE := docker compose

.PHONY: help dev prod analytics-init facebook-token social-check social-test down logs ps

help: ## Show available targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-15s %s\n", $$1, $$2}'

dev: .env ## Start the stack for local testing (http://localhost), incl. analytics bootstrap
	$(COMPOSE) up -d --build
	./scripts/analytics-init.sh

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
	./scripts/analytics-init.sh

analytics-init: .env ## (Re)deploy Ghost's Tinybird pipes and write the TINYBIRD_* tokens into .env
	./scripts/analytics-init.sh

facebook-token: .env ## Interactive: turn a short-lived Meta user token into FACEBOOK_PAGE_ID + a permanent Page token (docs/social-facebook.md)
	$(COMPOSE) run --rm -e FB_APP_ID -e FB_APP_SECRET -e FB_USER_TOKEN social-publisher token

social-check: .env ## Verify the Facebook Page token in .env (and the webhook URL/secret to enter in Ghost Admin)
	$(COMPOSE) run --rm social-publisher check
	@echo; echo 'Ghost Admin → Settings → Integrations → custom integration → Add webhook (one per event):'
	@echo '  Events:     "Post published"  and  "Published post updated"'
	@echo '  Target URL: http://social-publisher.lfi.internal:8080/webhooks/ghost'
	@grep -E '^SOCIAL_WEBHOOK_SECRET=.+' .env | sed 's/^SOCIAL_WEBHOOK_SECRET=/  Secret:     /' \
		|| echo '  Secret:     (SOCIAL_WEBHOOK_SECRET missing in .env — add one: openssl rand -hex 32)'

social-test: ## Run the publisher's tests (node --test in a throwaway container, no network)
	docker run --rm -v "$(CURDIR)/social-publisher:/app:ro" -w /app node:22-alpine node --test

down: ## Stop the stack
	$(COMPOSE) down

logs: ## Tail Ghost logs (analytics: docker compose logs -f traffic-analytics tinybird-local)
	$(COMPOSE) logs -f ghost

ps: ## Show service status
	$(COMPOSE) ps

.env:
	@echo 'error: .env missing — run `cp .env.example .env` and set passwords'; exit 1
