# Flex

A fixed-rate lending protocol inspired by Liquity V2 — borrowers set their own rates, and liquidity is managed through collateral redemptions: lenders or new borrowers can redeem existing borrowers’ collateral (paying slippage and fees), starting with those at the lowest rates.

## Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/johnnyonline/Flex.git
   cd Flex
   ```

2. **Set up virtual environment**
   ```bash
   uv venv
   source .venv/bin/activate  # On Windows: .venv\Scripts\activate
   deactivate  # To deactivate the venv
   ```

3. **Install dependencies**
   ```bash
   # Install all dependencies
   uv sync
   ```

   > Note: This project uses [uv](https://github.com/astral-sh/uv) for faster dependency installation. If you don't have uv installed, you can install it with `pip install uv` or follow the [installation instructions](https://github.com/astral-sh/uv#installation).

4. **Environment setup**
   ```bash
   cp .env.example .env
   # Edit .env with your API keys and configuration
   ```

## Usage

Build:
```shell
forge b
```

Test:
```shell
forge t
```

Deploy:
```shell
forge script script/Deploy.s.sol:Deploy --verify --slow --legacy --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast
```

## Code Style

Format and lint code with ruff:
```bash
# Format Vyper code
mamushi . --line-length 120

# Format Solidity code
forge fmt .
```