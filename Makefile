.PHONY: test test-up test-down

test-up:
	docker compose -f docker-compose.tests.yaml up -d --wait

test-down:
	docker compose -f docker-compose.tests.yaml down -v

test: test-up
	dart test
	$(MAKE) test-down