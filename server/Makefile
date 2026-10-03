.PHONY: build run test vet sqlc admin h5 web seed clean

build:
	go build -o bin/quizmind ./cmd/quizmind

run: build
	./bin/quizmind -config config.yaml

test:
	go test -race ./...

vet:
	go vet ./...

# Regenerate internal/store from internal/db/migrations and internal/db/queries.
sqlc:
	sqlc generate

# Build the Vue admin (../admin) into web/dist so it is embedded in the binary.
admin:
	cd ../admin && npm ci && npm run build
	find web/dist -mindepth 1 -maxdepth 1 ! -name .gitkeep ! -name m -exec rm -rf {} +
	cp -R ../admin/dist/. web/dist/
	go build -o bin/quizmind ./cmd/quizmind

# Build the phone web app (../h5) into web/dist/m, served at /m/.
h5:
	cd ../h5 && npm ci && npm run build
	rm -rf web/dist/m && mkdir -p web/dist/m
	cp -R ../h5/dist/. web/dist/m/
	go build -o bin/quizmind ./cmd/quizmind

# Both web UIs.
web: admin h5

clean:
	rm -rf bin data

# Load a sample document and hand-written questions (no API key needed).
seed:
	go run ./cmd/devseed -config config.yaml
