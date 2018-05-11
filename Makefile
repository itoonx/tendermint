GOTOOLS = \
	github.com/golang/dep/cmd/dep \
	gopkg.in/alecthomas/gometalinter.v2
PACKAGES=$(shell go list ./... | grep -v '/vendor/')
BUILD_TAGS?=tendermint
BUILD_FLAGS=-asmflags "-trimpath" -gcflags "-trimpath=$(GOPATH)/src" -ldflags "-X github.com/tendermint/tendermint/version.GitCommit=`git rev-parse --short=8 HEAD`"
BUILD_PREFIX=CGO_ENABLED=1
DOCKER_NIX_IMAGE=tendermint/tendermint:nix

all: check build test install

check: check_tools ensure_deps


########################################
### Build

build:
	echo "Building at GOPATH ${GOPATH}"
	$(BUILD_PREFIX) go build $(BUILD_FLAGS) -tags '$(BUILD_TAGS)' -o build/tendermint ./cmd/tendermint/

build_nix: check_nix check_openssl
	@echo "Building from default.nix / deps.nix. If you want to update dependencies you MUST run 'make dep2nix' first"
	nix-build -E 'with import <nixpkgs> { };  callPackage ./default.nix {}'
	rm -rf build && mkdir build && cp result-bin/bin/* build && unlink result-bin
	openssl sha256 build/tendermint

build_nix_docker: check_docker check_openssl
	time docker build -t $(DOCKER_NIX_IMAGE) -f DOCKER/Dockerfile.nix .
	scripts/cp-from-docker.sh $(DOCKER_NIX_IMAGE)
	openssl sha256 build/tendermint

build_race:
	$(BUILD_PREFIX) go build -race $(BUILD_FLAGS) -tags '$(BUILD_TAGS)' -o build/tendermint ./cmd/tendermint

install:
	$(BUILD_PREFIX) go install $(BUILD_FLAGS) -tags '$(BUILD_TAGS)' ./cmd/tendermint

########################################
### Distribution

# dist builds binaries for all platforms and packages them for distribution
dist:
	@BUILD_TAGS='$(BUILD_TAGS)' sh -c "'$(CURDIR)/scripts/dist.sh'"

########################################
### Tools & dependencies

check_tools:
	@# https://stackoverflow.com/a/25668869
	@echo "Found tools: $(foreach tool,$(notdir $(GOTOOLS)),\
        $(if $(shell which $(tool)),$(tool),$(error "No $(tool) in PATH")))"

check_dep2nix: check_nix
	@echo $(if $(shell which dep2nix),Found dep2nix,$(error "No dep2nix in PATH, install it with 'make get_dep2nix'"))

check_nix:
	@echo $(if $(shell which nix-build),Found nix-build,$(error "No nix-build in PATH"))
	@echo $(if $(shell which nix-env),Found nix-env,$(error "No nix-env in PATH"))

check_docker:
	@echo $(if $(shell which docker),Found docker,$(error "No docker in PATH"))

check_openssl:
	@echo $(if $(shell which openssl),Found openssl,$(error "No openssl in PATH"))

dep2nix: check_dep2nix
	@echo "Converting Gopkg.lock to deps.nix (if this fails with HTTP errors, just retry)..."
	dep2nix save

get_dep2nix: check_nix
	cd $$(mktemp -d) && git clone https://github.com/nixcloud/dep2nix.git && cd dep2nix && nix-env -f default.nix -i dep2nix

get_tools:
	@echo "--> Installing tools"
	go get -u -v $(GOTOOLS)
	@gometalinter.v2 --install

update_tools:
	@echo "--> Updating tools"
	@go get -u $(GOTOOLS)

#Run this from CI
get_vendor_deps:
	@rm -rf vendor/
	@echo "--> Running dep"
	@dep ensure -vendor-only

#Run this locally.
ensure_deps:
	@rm -rf vendor/
	@echo "--> Running dep"
	@dep ensure

draw_deps:
	@# requires brew install graphviz or apt-get install graphviz
	go get github.com/RobotsAndPencils/goviz
	@goviz -i github.com/tendermint/tendermint/cmd/tendermint -d 3 | dot -Tpng -o dependency-graph.png

get_deps_bin_size:
	@# Copy of build recipe with additional flags to perform binary size analysis
	$(eval $(shell go build -work -a $(BUILD_FLAGS) -tags '$(BUILD_TAGS)' -o build/tendermint ./cmd/tendermint/ 2>&1))
	@find $(WORK) -type f -name "*.a" | xargs -I{} du -hxs "{}" | sort -rh | sed -e s:${WORK}/::g > deps_bin_size.log
	@echo "Results can be found here: $(CURDIR)/deps_bin_size.log"

########################################
### Testing

## required to be run first by most tests
build_docker_test_image:
	docker build -t tester -f ./test/docker/Dockerfile .

### coverage, app, persistence, and libs tests
test_cover:
	# run the go unit tests with coverage
	bash test/test_cover.sh

test_apps:
	# run the app tests using bash
	# requires `abci-cli` and `tendermint` binaries installed
	bash test/app/test.sh

test_persistence:
	# run the persistence tests using bash
	# requires `abci-cli` installed
	docker run --name run_persistence -t tester bash test/persist/test_failure_indices.sh

	# TODO undockerize
	# bash test/persist/test_failure_indices.sh

test_p2p:
	docker rm -f rsyslog || true
	rm -rf test/logs || true
	mkdir test/logs
	cd test/
	docker run -d -v "logs:/var/log/" -p 127.0.0.1:5514:514/udp --name rsyslog voxxit/rsyslog
	cd ..
	# requires 'tester' the image from above
	bash test/p2p/test.sh tester

need_abci:
	bash scripts/install_abci_apps.sh

test_integrations:
	make build_docker_test_image
	make get_tools
	make get_vendor_deps
	make install
	make need_abci
	make test_cover
	make test_apps
	make test_persistence
	make test_p2p

test_release:
	@go test -tags release $(PACKAGES)

test100:
	@for i in {1..100}; do make test; done

vagrant_test:
	vagrant up
	vagrant ssh -c 'make test_integrations'

### go tests
test:
	@echo "--> Running go test"
	@go test $(PACKAGES)

test_race:
	@echo "--> Running go test --race"
	@go test -v -race $(PACKAGES)


########################################
### Formatting, linting, and vetting

fmt:
	@go fmt ./...

metalinter:
	@echo "--> Running linter"
	@gometalinter.v2 --vendor --deadline=600s --disable-all  \
		--enable=deadcode \
		--enable=gosimple \
	 	--enable=misspell \
		--enable=safesql \
		./...
		#--enable=gas \
		#--enable=maligned \
		#--enable=dupl \
		#--enable=errcheck \
		#--enable=goconst \
		#--enable=gocyclo \
		#--enable=goimports \
		#--enable=golint \ <== comments on anything exported
		#--enable=gotype \
	 	#--enable=ineffassign \
	   	#--enable=interfacer \
	   	#--enable=megacheck \
	   	#--enable=staticcheck \
	   	#--enable=structcheck \
	   	#--enable=unconvert \
	   	#--enable=unparam \
		#--enable=unused \
	   	#--enable=varcheck \
		#--enable=vet \
		#--enable=vetshadow \

metalinter_all:
	@echo "--> Running linter (all)"
	gometalinter.v2 --vendor --deadline=600s --enable-all --disable=lll ./...

###########################################################
### Docker image

build-docker:
	cp build/tendermint DOCKER/tendermint
	docker build --label=tendermint --tag="tendermint/tendermint" DOCKER
	rm -rf DOCKER/tendermint

###########################################################
### Local testnet using docker

# Build linux binary on other platforms
build-linux:
	GOOS=linux GOARCH=amd64 $(MAKE) build

# Run a 4-node testnet locally
localnet-start:
	@if ! [ -f build/node0/config/genesis.json ]; then docker run --rm -v $(CURDIR)/build:/tendermint:Z tendermint/localnode testnet --v 4 --o . --populate-persistent-peers --starting-ip-address 192.167.10.2 ; fi
	docker-compose up

# Stop testnet
localnet-stop:
	docker-compose down

###########################################################
### Remote full-nodes (sentry) using terraform and ansible

# Server management
sentry-start:
	@if [ -z "$(DO_API_TOKEN)" ]; then echo "DO_API_TOKEN environment variable not set." ; false ; fi
	@if ! [ -f $(HOME)/.ssh/id_rsa.pub ]; then ssh-keygen ; fi
	cd networks/remote/terraform && terraform init && terraform apply -var DO_API_TOKEN="$(DO_API_TOKEN)" -var SSH_KEY_FILE="$(HOME)/.ssh/id_rsa.pub"
	@if ! [ -f $(CURDIR)/build/node0/config/genesis.json ]; then docker run --rm -v $(CURDIR)/build:/tendermint:Z tendermint/localnode testnet --v 0 --n 4 --o . ; fi
	cd networks/remote/ansible && ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i inventory/digital_ocean.py -l sentrynet install.yml
	@echo "Next step: Add your validator setup in the genesis.json and config.tml files and run \"make server-config\". (Public key of validator, chain ID, peer IP and node ID.)"

# Configuration management
sentry-config:
	cd networks/remote/ansible && ansible-playbook -i inventory/digital_ocean.py -l sentrynet config.yml -e BINARY=$(CURDIR)/build/tendermint -e CONFIGDIR=$(CURDIR)/build

sentry-stop:
	@if [ -z "$(DO_API_TOKEN)" ]; then echo "DO_API_TOKEN environment variable not set." ; false ; fi
	cd networks/remote/terraform && terraform destroy -var DO_API_TOKEN="$(DO_API_TOKEN)" -var SSH_KEY_FILE="$(HOME)/.ssh/id_rsa.pub"

# To avoid unintended conflicts with file names, always add to .PHONY
# unless there is a reason not to.
# https://www.gnu.org/software/make/manual/html_node/Phony-Targets.html
.PHONY: check build build_race dist install check_tools get_tools update_tools get_vendor_deps draw_deps test_cover test_apps test_persistence test_p2p test test_race test_integrations test_release test100 vagrant_test fmt build-linux localnet-start localnet-stop build-docker sentry-start sentry-config sentry-stop

