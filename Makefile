.PHONY: build
build:
	@docker-compose build

.PHONY: run
run:
	@docker-compose up -d

.PHONY: down
down:
	@docker-compose down

.PHONY: ps
ps:
	@docker-compose ps
