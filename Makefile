-include .env

DEPLOYER_ACCOUNT_ARG := --account $(DEPLOYER_ACCOUNT)
GIT_COMMIT_VALUE := $(if $(GIT_COMMIT),$(GIT_COMMIT),$(shell git rev-parse --short HEAD))

.PHONY: all build build-scripts test gas-snapshots gas-check coverage clean fmt lint slither require-deployer-address require-deployer-account deploy-local deploy-sepolia deploy-sepolia-dry validate-deployment-sepolia deploy-mainnet deploy-mainnet-dry validate-deployment-mainnet

# =============================================================================
# Build & Test
# =============================================================================

all: clean build test

build:
	@echo "Building contracts..."
	@forge build --skip test --skip script --skip medusa

build-scripts:
	@echo "Building deployment scripts..."
	@forge build --skip test --skip medusa

test:
	@echo "Running tests..."
	@forge test -vvv

gas-snapshots:
	@echo "Updating protocol operation gas snapshots..."
	@forge test --match-path "test/gas/*.gas.t.sol" --isolate --gas-snapshot-emit true --gas-snapshot-check false

gas-check:
	@echo "Checking protocol operation gas snapshots..."
	@FOUNDRY_PROFILE=gas forge test --match-path "test/gas/*.gas.t.sol"

coverage:
	@echo "Running coverage..."
	@forge coverage --ir-minimum --no-match-coverage "^(script|test)/" --skip script

clean:
	@echo "Cleaning..."
	@forge clean
	@rm -rf cache out

fmt:
	@forge fmt

lint:
	@forge lint

slither:
	@slither src --filter-paths "lib/|test/|script/"

# =============================================================================
# Local Development
# =============================================================================

anvil:
	@echo "Starting local Anvil node..."
	@anvil --chain-id 31337

require-deployer-address:
	@test -n "$(DEPLOYER_ADDRESS)" || (echo "DEPLOYER_ADDRESS is required"; exit 1)

require-deployer-account: require-deployer-address
	@test -n "$(DEPLOYER_ACCOUNT)" || (echo "DEPLOYER_ACCOUNT is required"; exit 1)

deploy-local: require-deployer-address
	@echo "Deploying to local Anvil..."
	@forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

# =============================================================================
# Base Sepolia (Testnet)
# Usage: make deploy-sepolia [VERIFY=--verify]
# =============================================================================

deploy-sepolia: require-deployer-account
	@echo ""
	@echo "========================================"
	@echo "  Deploying to Base Sepolia (testnet)"
	@echo "========================================"
	@echo ""
	@SAVE_DEPLOYMENT_CATALOG=true GIT_COMMIT=$(GIT_COMMIT_VALUE) forge script script/Deploy.s.sol \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--slow \
		$(DEPLOYER_ACCOUNT_ARG) \
		$(VERIFY) \
		-vvvv

deploy-sepolia-dry: require-deployer-address
	@echo "Simulating deployment to Base Sepolia..."
	@forge script script/Deploy.s.sol \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		$(if $(DEPLOYER_ACCOUNT),$(DEPLOYER_ACCOUNT_ARG),) \
		-vvvv

validate-deployment-sepolia:
	@echo "Validating Base Sepolia deployment..."
	@forge script script/ValidateDeployment.s.sol \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		-vvvv

# =============================================================================
# Base Mainnet
# =============================================================================

deploy-mainnet: require-deployer-account
	@echo ""
	@echo "========================================"
	@echo "  !!! MAINNET DEPLOYMENT !!!"
	@echo "========================================"
	@echo ""
	@echo "Are you sure? This will deploy to MAINNET."
	@echo "Press Ctrl+C to cancel, or Enter to continue..."
	@read _
	@SAVE_DEPLOYMENT_CATALOG=true GIT_COMMIT=$(GIT_COMMIT_VALUE) forge script script/Deploy.s.sol \
		--rpc-url $(BASE_MAINNET_RPC_URL) \
		--account $(DEPLOYER_ACCOUNT) \
		--broadcast \
		--verify \
		--slow \
		-vvvv

deploy-mainnet-dry: require-deployer-account
	@echo "Simulating deployment to Base Mainnet..."
	@forge script script/Deploy.s.sol \
		--rpc-url $(BASE_MAINNET_RPC_URL) \
		--account $(DEPLOYER_ACCOUNT) \
		-vvvv

validate-deployment-mainnet:
	@echo "Validating Base Mainnet deployment..."
	@forge script script/ValidateDeployment.s.sol \
		--rpc-url $(BASE_MAINNET_RPC_URL) \
		-vvvv
