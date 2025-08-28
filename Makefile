# Default shell
SHELL := /bin/bash

# Colors for output
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m # No Color

# Project configuration
PROJECT_NAME := curve-v1-stableswap
FOUNDRY_PROFILE := default

# Test configuration
TEST_DIR := test
UNIT_TEST_DIR := $(TEST_DIR)/unit
INTEGRATION_TEST_DIR := $(TEST_DIR)/integration
INVARIANT_TEST_DIR := $(TEST_DIR)/invariant

# Contract addresses (will be set after deployment)
ANVIL_RPC_URL := http://127.0.0.1:8545
SEPOLIA_RPC_URL := https://eth-sepolia.g.alchemy.com/v2/$(ALCHEMY_API_KEY)
MAINNET_RPC_URL := https://eth-mainnet.g.alchemy.com/v2/$(ALCHEMY_API_KEY)

# Gas configuration
GAS_LIMIT := 30000000
GAS_PRICE := 20000000000 # 20 gwei

# =============================================================================
# HELP COMMAND
# =============================================================================

.PHONY: help
help: ## Display this help message
	@echo -e "$(GREEN)$(PROJECT_NAME) - Available Commands$(NC)"
	@echo "=============================================="
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# =============================================================================
# SETUP & INSTALLATION
# =============================================================================

.PHONY: install
install: ## Install dependencies
	@echo -e "$(YELLOW)Installing Foundry dependencies...$(NC)"
	forge install
	@echo -e "$(GREEN)Dependencies installed successfully!$(NC)"

.PHONY: update
update: ## Update dependencies
	@echo -e "$(YELLOW)Updating Foundry dependencies...$(NC)"
	forge update
	@echo -e "$(GREEN)Dependencies updated successfully!$(NC)"

.PHONY: build
build: ## Compile contracts
	@echo -e "$(YELLOW)Compiling contracts...$(NC)"
	forge build
	@echo -e "$(GREEN)Contracts compiled successfully!$(NC)"

.PHONY: clean
clean: ## Clean build artifacts
	@echo -e "$(YELLOW)Cleaning build artifacts...$(NC)"
	forge clean
	@echo -e "$(GREEN)Build artifacts cleaned!$(NC)"

.PHONY: fmt
fmt: ## Format code
	@echo -e "$(YELLOW)Formatting code...$(NC)"
	forge fmt
	@echo -e "$(GREEN)Code formatted successfully!$(NC)"

# =============================================================================
# TESTING COMMANDS
# =============================================================================

.PHONY: test
test: ## Run all tests
	@echo -e "$(YELLOW)Running all tests...$(NC)"
	forge test -vv
	@echo -e "$(GREEN)All tests completed!$(NC)"

.PHONY: test-unit
test-unit: ## Run unit tests only
	@echo -e "$(YELLOW)Running unit tests...$(NC)"
	forge test --match-path "$(UNIT_TEST_DIR)/*.sol" -vv
	@echo -e "$(GREEN)Unit tests completed!$(NC)"

.PHONY: test-integration
test-integration: ## Run integration tests only
	@echo -e "$(YELLOW)Running integration tests...$(NC)"
	forge test --match-path "$(INTEGRATION_TEST_DIR)/*.sol" -vv
	@echo -e "$(GREEN)Integration tests completed!$(NC)"

.PHONY: test-invariant
test-invariant: ## Run invariant/fuzz tests
	@echo -e "$(YELLOW)Running invariant tests...$(NC)"
	forge test --match-path "$(INVARIANT_TEST_DIR)/*.sol" -vv
	@echo -e "$(GREEN)Invariant tests completed!$(NC)"

.PHONY: test-verbose
test-verbose: ## Run tests with maximum verbosity
	@echo -e "$(YELLOW)Running tests with maximum verbosity...$(NC)"
	forge test -vvvv

.PHONY: test-gas
test-gas: ## Run tests with gas reporting
	@echo -e "$(YELLOW)Running tests with gas reporting...$(NC)"
	forge test --gas-report

.PHONY: test-coverage
test-coverage: ## Generate test coverage report
	@echo -e "$(YELLOW)Generating coverage report...$(NC)"
	forge coverage --report lcov
	@echo -e "$(GREEN)Coverage report generated!$(NC)"

.PHONY: test-specific
test-specific: ## Run specific test (usage: make test-specific TEST=TestName)
	@echo -e "$(YELLOW)Running test: $(TEST)$(NC)"
	forge test --match-test $(TEST) -vv

.PHONY: test-contract
test-contract: ## Run tests for specific contract (usage: make test-contract CONTRACT=ContractName)
	@echo -e "$(YELLOW)Running tests for contract: $(CONTRACT)$(NC)"
	forge test --match-contract $(CONTRACT) -vv

# =============================================================================
# LOCAL DEVELOPMENT
# =============================================================================

.PHONY: anvil
anvil: ## Start local Anvil node
	@echo -e "$(YELLOW)Starting Anvil local node...$(NC)"
	anvil --host 0.0.0.0 --port 8545 --accounts 10 --balance 10000

.PHONY: deploy-local
deploy-local: ## Deploy to local Anvil network
	@echo -e "$(YELLOW)Deploying to local network...$(NC)"
	forge script script/DeployCurvePool.s.sol:DeployCurvePool \
		--rpc-url $(ANVIL_RPC_URL) \
		--broadcast \
		--gas-limit $(GAS_LIMIT) \
		-vv
	@echo -e "$(GREEN)Deployment to local network completed!$(NC)"

.PHONY: deploy-local-verify
deploy-local-verify: ## Deploy to local network and setup initial liquidity
	@echo -e "$(YELLOW)Deploying and setting up local environment...$(NC)"
	forge script script/DeployCurvePool.s.sol:DeployCurvePool \
		--rpc-url $(ANVIL_RPC_URL) \
		--broadcast \
		--gas-limit $(GAS_LIMIT) \
		--sig "deployAndSetup(uint256)" 1000000000000000000000000 \
		-vv
	@echo -e "$(GREEN)Local environment setup completed!$(NC)"

# =============================================================================
# TESTNET DEPLOYMENT
# =============================================================================

.PHONY: deploy-sepolia
deploy-sepolia: ## Deploy to Sepolia testnet
	@echo -e "$(YELLOW)Deploying to Sepolia testnet...$(NC)"
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo -e "$(RED)Error: PRIVATE_KEY environment variable not set$(NC)"; \
		exit 1; \
	fi
	forge script script/DeployCurvePool.s.sol:DeployCurvePool \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--verify \
		--gas-limit $(GAS_LIMIT) \
		-vv
	@echo -e "$(GREEN)Deployment to Sepolia completed!$(NC)"

.PHONY: deploy-sepolia-setup
deploy-sepolia-setup: ## Deploy to Sepolia with initial liquidity
	@echo -e "$(YELLOW)Deploying to Sepolia with setup...$(NC)"
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo -e "$(RED)Error: PRIVATE_KEY environment variable not set$(NC)"; \
		exit 1; \
	fi
	forge script script/DeployCurvePool.s.sol:DeployCurvePool \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--verify \
		--gas-limit $(GAS_LIMIT) \
		--sig "deployAndSetup(uint256)" 1000000000000000000000000 \
		-vv
	@echo -e "$(GREEN)Sepolia setup completed!$(NC)"

# =============================================================================
# MAINNET DEPLOYMENT
# =============================================================================

.PHONY: deploy-mainnet
deploy-mainnet: ## Deploy to Ethereum mainnet
	@echo -e "$(RED)WARNING: Deploying to MAINNET!$(NC)"
	@echo -e "$(YELLOW)Are you sure? This will cost real ETH. Press Ctrl+C to cancel or Enter to continue...$(NC)"
	@read
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo -e "$(RED)Error: PRIVATE_KEY environment variable not set$(NC)"; \
		exit 1; \
	fi
	forge script script/DeployCurvePool.s.sol:DeployCurvePool \
		--rpc-url $(MAINNET_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--verify \
		--gas-limit $(GAS_LIMIT) \
		-vv
	@echo -e "$(GREEN)Mainnet deployment completed!$(NC)"

# =============================================================================
# VERIFICATION
# =============================================================================

.PHONY: verify
verify: ## Verify contracts on Etherscan (usage: make verify NETWORK=sepolia ADDRESS=0x...)
	@echo -e "$(YELLOW)Verifying contract on $(NETWORK)...$(NC)"
	@if [ -z "$(ADDRESS)" ]; then \
		echo -e "$(RED)Error: ADDRESS not provided$(NC)"; \
		exit 1; \
	fi
	forge verify-contract $(ADDRESS) src/CurveV1Pool.sol:CurveV1Pool \
		--chain $(NETWORK) \
		--etherscan-api-key $(ETHERSCAN_API_KEY)

# =============================================================================
# ANALYSIS & SECURITY
# =============================================================================

.PHONY: analyze
analyze: ## Run static analysis with Slither
	@echo -e "$(YELLOW)Running static analysis...$(NC)"
	@if ! command -v slither &> /dev/null; then \
		echo -e "$(RED)Slither not installed. Install with: pip install slither-analyzer$(NC)"; \
		exit 1; \
	fi
	slither .
	@echo -e "$(GREEN)Static analysis completed!$(NC)"

.PHONY: mythril
mythril: ## Run security analysis with Mythril
	@echo -e "$(YELLOW)Running Mythril security analysis...$(NC)"
	@if ! command -v myth &> /dev/null; then \
		echo -e "$(RED)Mythril not installed. Install with: pip install mythril$(NC)"; \
		exit 1; \
	fi
	myth analyze src/CurveV1Pool.sol --solc-json mythril.json

.PHONY: size
size: ## Check contract sizes
	@echo -e "$(YELLOW)Checking contract sizes...$(NC)"
	forge build --sizes
	@echo -e "$(GREEN)Contract size check completed!$(NC)"

# =============================================================================
# DOCUMENTATION
# =============================================================================

.PHONY: doc
doc: ## Generate documentation
	@echo -e "$(YELLOW)Generating documentation...$(NC)"
	forge doc
	@echo -e "$(GREEN)Documentation generated!$(NC)"

.PHONY: doc-serve
doc-serve: ## Serve documentation locally
	@echo -e "$(YELLOW)Serving documentation at http://localhost:3000$(NC)"
	forge doc --serve --port 3000

# =============================================================================
# UTILITIES
# =============================================================================

.PHONY: snapshot
snapshot: ## Create gas snapshot
	@echo -e "$(YELLOW)Creating gas snapshot...$(NC)"
	forge snapshot
	@echo -e "$(GREEN)Gas snapshot created!$(NC)"

.PHONY: storage-layout
storage-layout: ## Show storage layout
	@echo -e "$(YELLOW)Analyzing storage layout...$(NC)"
	forge inspect CurveV1Pool storage-layout --pretty

.PHONY: abi
abi: ## Extract contract ABI
	@echo -e "$(YELLOW)Extracting contract ABI...$(NC)"
	forge inspect CurveV1Pool abi > CurveV1Pool.abi.json
	forge inspect CurveLPToken abi > CurveLPToken.abi.json
	@echo -e "$(GREEN)ABIs extracted to *.abi.json files!$(NC)"

.PHONY: fund-local
fund-local: ## Fund local test account with tokens (usage: make fund-local ACCOUNT=0x...)
	@echo -e "$(YELLOW)Funding account $(ACCOUNT) on local network...$(NC)"
	@if [ -z "$(ACCOUNT)" ]; then \
		echo -e "$(RED)Error: ACCOUNT not provided$(NC)"; \
		exit 1; \
	fi
	forge script script/DeployCurvePool.s.sol:DeployCurvePool \
		--rpc-url $(ANVIL_RPC_URL) \
		--broadcast \
		--sig "fundAccountWithTokens(address,uint256)" $(ACCOUNT) 1000000000000000000000000

.PHONY: pool-status
pool-status: ## Check pool status (usage: make pool-status POOL=0x... [NETWORK=anvil])
	@echo -e "$(YELLOW)Checking pool status...$(NC)"
	@if [ -z "$(POOL)" ]; then \
		echo -e "$(RED)Error: POOL address not provided$(NC)"; \
		exit 1; \
	fi
	@RPC_URL=$(ANVIL_RPC_URL); \
	if [ "$(NETWORK)" = "sepolia" ]; then RPC_URL=$(SEPOLIA_RPC_URL); fi; \
	forge script script/DeployCurvePool.s.sol:DeployCurvePool \
		--rpc-url $$RPC_URL \
		--sig "printPoolStatus(address)" $(POOL)

# =============================================================================
# ENVIRONMENT SETUP
# =============================================================================

.PHONY: setup-env
setup-env: ## Setup environment file template
	@echo -e "$(YELLOW)Creating .env template...$(NC)"
	@if [ ! -f .env ]; then \
		echo "# Environment Variables for Curve V1 Pool" > .env; \
		echo "PRIVATE_KEY=your_private_key_here" >> .env; \
		echo "ETHERSCAN_API_KEY=your_etherscan_api_key_here" >> .env; \
		echo "ALCHEMY_API_KEY=your_alchemy_api_key_here" >> .env; \
		echo "" >> .env; \
		echo "# Optional: Custom RPC URLs" >> .env; \
		echo "# SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/your_key" >> .env; \
		echo "# MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/your_key" >> .env; \
		echo -e "$(GREEN).env file created! Please fill in your keys.$(NC)"; \
	else \
		echo -e "$(YELLOW).env file already exists!$(NC)"; \
	fi

.PHONY: check-env
check-env: ## Check if environment variables are set
	@echo -e "$(YELLOW)Checking environment variables...$(NC)"
	@echo -n "PRIVATE_KEY: "; if [ -n "$(PRIVATE_KEY)" ]; then echo -e "$(GREEN)✓ Set$(NC)"; else echo -e "$(RED)✗ Not set$(NC)"; fi
	@echo -n "ETHERSCAN_API_KEY: "; if [ -n "$(ETHERSCAN_API_KEY)" ]; then echo -e "$(GREEN)✓ Set$(NC)"; else echo -e "$(RED)✗ Not set$(NC)"; fi
	@echo -n "ALCHEMY_API_KEY: "; if [ -n "$(ALCHEMY_API_KEY)" ]; then echo -e "$(GREEN)✓ Set$(NC)"; else echo -e "$(RED)✗ Not set$(NC)"; fi

# =============================================================================
# CI/CD SHORTCUTS
# =============================================================================

.PHONY: ci-test
ci-test: ## Run CI test suite
	@echo -e "$(YELLOW)Running CI test suite...$(NC)"
	forge test --gas-report
	forge coverage --report lcov

.PHONY: ci-lint
ci-lint: ## Run CI linting
	@echo -e "$(YELLOW)Running CI linting...$(NC)"
	forge fmt --check

.PHONY: ci-build
ci-build: ## Run CI build
	@echo -e "$(YELLOW)Running CI build...$(NC)"
	forge build

# =============================================================================
# DEFAULT TARGET
# =============================================================================

.DEFAULT_GOAL := help