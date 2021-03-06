hugo_version ?= $(shell grep HUGO_VERSION ./.env | cut -d '=' -f2)
hugo_image := peaceiris/hugo:v${hugo_version}
hugo := docker run --rm -v $(PWD):/workspace -w /workspace $(hugo_image)

.PHONY: build
build:
	@$(hugo) -D

.PHONY: run
run:
	@docker-compose up -d

.PHONY: down
down:
	@docker-compose down
