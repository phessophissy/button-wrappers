# Button Wrappers

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.4-363636.svg)](https://soliditylang.org/)
[![Hardhat](https://img.shields.io/badge/Built%20with-Hardhat-FFDB1C.svg)](https://hardhat.org/)

ERC-20 Token wrappers for the Buttonwood ecosystem. This library provides two primary wrapper contracts:

- **ButtonToken**: Wraps fixed-balance tokens into elastic/rebasing tokens (price-targeted)
- **UnbuttonToken**: Wraps elastic/rebasing tokens into fixed-balance tokens (share-based)

## Table of Contents

- [Overview](#overview)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Contract Architecture](#contract-architecture)
- [Usage Examples](#usage-examples)
- [API Reference](#api-reference)
- [Testing](#testing)
- [Deployments](#deployments)
- [Security](#security)
- [Contributing](#contributing)
- [License](#license)

## Overview

### ButtonToken (Rebasing Wrapper)

ButtonToken wraps fixed-balance ERC-20 tokens and creates elastic balance tokens that rebase based on an oracle price. This is useful for creating stable-unit representations of volatile assets.

**Example**: Wrap 1 ETH when ETH = $2,000 → Receive 2,000 ButtonETH (each worth $1). If ETH goes to $2,500 → Your balance becomes 2,500 ButtonETH.

### UnbuttonToken (Fixed Wrapper)

UnbuttonToken wraps elastic/rebasing tokens (like AMPL, aTokens) into fixed-balance tokens. Your share of the underlying pool remains constant.

**Example**: Deposit 1,000 AMPL → Receive UnbuttonAMPL tokens. Even as AMPL rebases, your UnbuttonAMPL balance stays the same (but represents changing underlying value).

## Installation

### Prerequisites

- Node.js v16.20.2 (use [nvm](https://github.com/nvm-sh/nvm) for version management)
- Yarn package manager

```bash
# Clone the repository
git clone https://github.com/buttonwood-protocol/button-wrappers.git
cd button-wrappers

# Install dependencies
yarn install
```

## Quick Start

### Compile Contracts

```bash
yarn compile
```

### Run Tests

```bash
yarn test
```

### Deploy Locally

```bash
# Start local hardhat node
yarn hardhat node

# In another terminal, deploy
yarn hardhat run scripts/deploy.ts --network localhost
```

## Contract Architecture

```
contracts/
├── ButtonToken.sol           # Rebasing wrapper (fixed → elastic)
├── ButtonTokenFactory.sol    # Factory for deploying ButtonToken instances
├── UnbuttonToken.sol         # Fixed wrapper (elastic → fixed)
├── UnbuttonTokenFactory.sol  # Factory for deploying UnbuttonToken instances
├── ButtonTokenWethRouter.sol # Router for ETH ↔ ButtonWETH
├── ButtonTokenWamplRouter.sol# Router for AMPL ↔ ButtonWAMPL
├── interfaces/               # Contract interfaces
├── oracles/                  # Oracle implementations
├── mocks/                    # Mock contracts for testing
└── utilities/                # Utility contracts
```

## Usage Examples

### Example 1: Wrapping ETH into ButtonWETH

```solidity
// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;

import "./ButtonTokenWethRouter.sol";

contract MyDeFiProtocol {
    ButtonTokenWethRouter public router;
    IButtonToken public buttonWETH;
    
    constructor(address _router, address _buttonWETH) {
        router = ButtonTokenWethRouter(_router);
        buttonWETH = IButtonToken(_buttonWETH);
    }
    
    /// @notice Wrap ETH into ButtonWETH
    /// @dev User sends ETH, receives ButtonWETH tokens
    /// @return amount The amount of ButtonWETH received
    function wrapETH() external payable returns (uint256 amount) {
        // Deposit ETH and receive ButtonWETH
        amount = router.deposit{value: msg.value}(address(buttonWETH));
        
        // Transfer ButtonWETH to the user
        IERC20(address(buttonWETH)).transfer(msg.sender, amount);
    }
    
    /// @notice Unwrap ButtonWETH back to ETH
    /// @param buttonAmount Amount of ButtonWETH to unwrap
    function unwrapToETH(uint256 buttonAmount) external {
        // Transfer ButtonWETH from user to this contract
        IERC20(address(buttonWETH)).transferFrom(msg.sender, address(this), buttonAmount);
        
        // Approve router to spend ButtonWETH
        IERC20(address(buttonWETH)).approve(address(router), buttonAmount);
        
        // Burn ButtonWETH and receive ETH
        router.burn(address(buttonWETH), buttonAmount);
        
        // Transfer ETH to user
        payable(msg.sender).transfer(address(this).balance);
    }
}
```

### Example 2: Depositing into ButtonToken Directly

```solidity
// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;

import "./interfaces/IButtonToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ButtonTokenDepositor {
    IButtonToken public buttonToken;
    IERC20 public underlying;
    
    constructor(address _buttonToken) {
        buttonToken = IButtonToken(_buttonToken);
        underlying = IERC20(buttonToken.underlying());
    }
    
    /// @notice Deposit underlying tokens and receive ButtonTokens
    /// @param amount Amount of underlying tokens to deposit
    /// @return buttonAmount Amount of ButtonTokens received
    function deposit(uint256 amount) external returns (uint256 buttonAmount) {
        // Transfer underlying from user
        underlying.transferFrom(msg.sender, address(this), amount);
        
        // Approve ButtonToken to spend underlying
        underlying.approve(address(buttonToken), amount);
        
        // Deposit underlying and receive ButtonTokens
        // deposit() takes underlying amount, returns button amount
        buttonAmount = buttonToken.deposit(amount);
        
        // Transfer ButtonTokens to user
        IERC20(address(buttonToken)).transfer(msg.sender, buttonAmount);
    }
    
    /// @notice Withdraw underlying tokens by burning ButtonTokens
    /// @param buttonAmount Amount of ButtonTokens to burn
    /// @return underlyingAmount Amount of underlying tokens received
    function withdraw(uint256 buttonAmount) external returns (uint256 underlyingAmount) {
        // Transfer ButtonTokens from user
        IERC20(address(buttonToken)).transferFrom(msg.sender, address(this), buttonAmount);
        
        // Burn ButtonTokens (burn takes button amount, returns underlying)
        underlyingAmount = buttonToken.burn(buttonAmount);
        
        // Transfer underlying to user
        underlying.transfer(msg.sender, underlyingAmount);
    }
    
    /// @notice Mint specific amount of ButtonTokens
    /// @dev mint() calculates required underlying automatically
    /// @param buttonAmount Desired amount of ButtonTokens
    /// @return underlyingUsed Amount of underlying tokens used
    function mintExact(uint256 buttonAmount) external returns (uint256 underlyingUsed) {
        // Calculate required underlying
        underlyingUsed = buttonToken.wrapperToUnderlying(buttonAmount);
        
        // Transfer underlying from user
        underlying.transferFrom(msg.sender, address(this), underlyingUsed);
        
        // Approve and mint
        underlying.approve(address(buttonToken), underlyingUsed);
        buttonToken.mint(buttonAmount);
        
        // Transfer ButtonTokens to user
        IERC20(address(buttonToken)).transfer(msg.sender, buttonAmount);
    }
}
```

### Example 3: Using UnbuttonToken for Rebasing Assets

```solidity
// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;

import "./interfaces/IButtonWrapper.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UnbuttonVault {
    IButtonWrapper public unbuttonToken;
    IERC20 public rebasingToken; // e.g., AMPL, aUSDC
    
    constructor(address _unbuttonToken) {
        unbuttonToken = IButtonWrapper(_unbuttonToken);
        rebasingToken = IERC20(unbuttonToken.underlying());
    }
    
    /// @notice Deposit rebasing tokens for fixed-balance representation
    /// @param amount Amount of rebasing tokens to deposit
    /// @return shares Amount of unbutton tokens (shares) received
    function depositRebasing(uint256 amount) external returns (uint256 shares) {
        // Transfer rebasing tokens from user
        rebasingToken.transferFrom(msg.sender, address(this), amount);
        
        // Approve UnbuttonToken
        rebasingToken.approve(address(unbuttonToken), amount);
        
        // Deposit and receive shares
        shares = unbuttonToken.deposit(amount);
        
        // Transfer shares to user
        IERC20(address(unbuttonToken)).transfer(msg.sender, shares);
    }
    
    /// @notice Withdraw all underlying rebasing tokens
    /// @return amount Amount of rebasing tokens received
    function withdrawAll() external returns (uint256 amount) {
        uint256 shares = IERC20(address(unbuttonToken)).balanceOf(msg.sender);
        
        // Transfer shares from user
        IERC20(address(unbuttonToken)).transferFrom(msg.sender, address(this), shares);
        
        // Burn all shares and receive underlying
        amount = unbuttonToken.burnAll();
        
        // Transfer underlying to user
        rebasingToken.transfer(msg.sender, amount);
    }
    
    /// @notice Get underlying value of shares
    /// @param shares Amount of unbutton shares
    /// @return underlyingValue Current underlying token value
    function getUnderlyingValue(uint256 shares) external view returns (uint256 underlyingValue) {
        return unbuttonToken.wrapperToUnderlying(shares);
    }
}
```

### Example 4: Creating a New ButtonToken via Factory

```solidity
// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;

import "./ButtonTokenFactory.sol";
import "./interfaces/IButtonToken.sol";

contract ButtonTokenCreator {
    ButtonTokenFactory public factory;
    
    constructor(address _factory) {
        factory = ButtonTokenFactory(_factory);
    }
    
    /// @notice Create a new ButtonToken for any ERC-20 with a price oracle
    /// @param underlying Address of the underlying ERC-20 token
    /// @param name Name for the new ButtonToken (e.g., "Button USDC")
    /// @param symbol Symbol for the new ButtonToken (e.g., "bUSDC")
    /// @param oracle Address of the price oracle (must implement IOracle)
    /// @return buttonToken Address of the newly created ButtonToken
    function createButtonToken(
        address underlying,
        string memory name,
        string memory symbol,
        address oracle
    ) external returns (address buttonToken) {
        buttonToken = factory.create(underlying, name, symbol, oracle);
        
        // Transfer ownership to caller
        IButtonToken(buttonToken).transferOwnership(msg.sender);
    }
}
```

### Example 5: TypeScript Integration

```typescript
import { ethers } from 'ethers';

// Connect to ButtonToken
const buttonTokenAddress = '0x8f471e1896d16481678db553f86283eab1561b02'; // bWETH mainnet
const buttonTokenABI = [
  'function deposit(uint256 uAmount) returns (uint256)',
  'function withdraw(uint256 uAmount) returns (uint256)',
  'function burn(uint256 amount) returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function balanceOfUnderlying(address) view returns (uint256)',
  'function underlyingToWrapper(uint256) view returns (uint256)',
  'function wrapperToUnderlying(uint256) view returns (uint256)',
  'function underlying() view returns (address)',
];

async function interactWithButtonToken(provider: ethers.providers.Provider, signer: ethers.Signer) {
  const buttonToken = new ethers.Contract(buttonTokenAddress, buttonTokenABI, signer);
  
  const userAddress = await signer.getAddress();
  
  // Get underlying token address
  const underlyingAddress = await buttonToken.underlying();
  console.log('Underlying token:', underlyingAddress);
  
  // Check current balances
  const buttonBalance = await buttonToken.balanceOf(userAddress);
  const underlyingBalance = await buttonToken.balanceOfUnderlying(userAddress);
  console.log('Button balance:', ethers.utils.formatEther(buttonBalance));
  console.log('Underlying balance:', ethers.utils.formatEther(underlyingBalance));
  
  // Convert between amounts
  const underlyingAmount = ethers.utils.parseEther('1');
  const expectedButtonAmount = await buttonToken.underlyingToWrapper(underlyingAmount);
  console.log('1 underlying =', ethers.utils.formatEther(expectedButtonAmount), 'button tokens');
  
  // Deposit example (requires prior approval)
  // const underlying = new ethers.Contract(underlyingAddress, ['function approve(address,uint256)'], signer);
  // await underlying.approve(buttonTokenAddress, underlyingAmount);
  // const receivedAmount = await buttonToken.deposit(underlyingAmount);
}

// Using with ethers v6
async function depositWithPermit(buttonToken: ethers.Contract, amount: bigint) {
  // If using a permit-enabled wrapper, you can use permit for gasless approvals
  const tx = await buttonToken.deposit(amount);
  const receipt = await tx.wait();
  console.log('Deposit successful:', receipt.hash);
}
```

## API Reference

### ButtonToken

| Function | Description | Returns |
|----------|-------------|---------|
| `deposit(uAmount)` | Deposit underlying tokens | Amount of ButtonTokens minted |
| `depositFor(to, uAmount)` | Deposit for another address | Amount of ButtonTokens minted |
| `withdraw(uAmount)` | Withdraw underlying tokens | Amount of ButtonTokens burned |
| `withdrawTo(to, uAmount)` | Withdraw to another address | Amount of ButtonTokens burned |
| `withdrawAll()` | Withdraw all underlying | Amount of underlying received |
| `mint(amount)` | Mint exact ButtonToken amount | Amount of underlying deposited |
| `burn(amount)` | Burn exact ButtonToken amount | Amount of underlying received |
| `transferAll(to)` | Transfer entire balance | Success boolean |
| `rebase()` | Trigger manual rebase | - |

### UnbuttonToken

| Function | Description | Returns |
|----------|-------------|---------|
| `deposit(uAmount)` | Deposit underlying (rebasing) | Amount of shares minted |
| `depositFor(to, uAmount)` | Deposit for another address | Amount of shares minted |
| `withdraw(uAmount)` | Withdraw underlying tokens | Amount of shares burned |
| `withdrawTo(to, uAmount)` | Withdraw to another address | Amount of shares burned |
| `withdrawAll()` | Withdraw all underlying | Amount of underlying received |
| `mint(amount)` | Mint exact share amount | Amount of underlying deposited |
| `burn(amount)` | Burn exact share amount | Amount of underlying received |

### View Functions (Both)

| Function | Description |
|----------|-------------|
| `underlying()` | Address of underlying token |
| `totalUnderlying()` | Total underlying tokens held |
| `balanceOfUnderlying(address)` | User's underlying token balance |
| `underlyingToWrapper(uAmount)` | Convert underlying → wrapper amount |
| `wrapperToUnderlying(amount)` | Convert wrapper → underlying amount |

## Testing

```bash
# Run all unit tests
yarn test

# Run tests with gas reporting
yarn profile

# Run tests with coverage
yarn coverage

# Run specific test file
yarn hardhat test test/unit/ButtonToken.ts
```

## Deployments

### Mainnet (Ethereum)

| Contract | Address |
|----------|---------|
| ButtonTokenFactory | `0x84D0F1Cd873122F2A87673e079ea69cd80b51960` |
| UnbuttonTokenFactory | `0x75ff649d6119fab43dea5e5e9e02586f27fc8b8f` |

**ButtonToken Instances:**
- bWETH: `0x8f471e1896d16481678db553f86283eab1561b02`
- bWBTC: `0x8e8212386d580d8dd731a2b1a36a43935250304e`

**UnbuttonToken Instances:**
- ubAAMPL: `0xF03387d8d0FF326ab586A58E0ab4121d106147DF`

### Avalanche

| Contract | Address |
|----------|---------|
| ButtonTokenFactory | `0x83f6392Aab030043420D184a025e0Cd63f508798` |

**ButtonToken Instances:**
- bWETH: `0x227d7A0e2586A5bFdA7f32aDF066d20D1bfDfDfb`
- bWAVAX: `0x9f61aE42c01698aC35AedeF651B0FE5E407bC6A0`
- bWBTC: `0x9bFE32D18e66ffAF6dcB0306AE7D24F768469f91`

For the latest deployments, see: https://docs.prl.one/buttonwood/developers/deployed-contracts

## Security

### Audits

Please refer to the [security documentation](./bug-bounty.md) for audit reports.

### Bug Bounty

We offer a bug bounty program. See [bug-bounty.md](./bug-bounty.md) for details.

### Known Limitations

- **Fee-on-Transfer Tokens**: ButtonToken does NOT support fee-on-transfer (FoT) tokens. These are incompatible with the accounting in `deposit/mint` functions.
- **Numeric Overflow**: UnbuttonToken has a maximum underlying capacity based on `sqrt(MAX_UINT256/INITIAL_RATE)`.

## Contributing

We welcome contributions! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Ensure code is lint-free and has 100% test coverage
4. Commit your changes (`git commit -m 'Add amazing feature'`)
5. Push to the branch (`git push origin feature/amazing-feature`)
6. Open a Pull Request

```bash
# Lint code
yarn lint

# Format code
yarn format

# Check coverage
yarn coverage
```

## License

[GNU General Public License v3.0](./LICENSE)

---

Built with ❤️ by the Buttonwood Protocol team
