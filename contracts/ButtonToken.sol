// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;

import {IOracle} from "./interfaces/IOracle.sol";
import "./interfaces/IButtonToken.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title ButtonToken - Rebasing ERC20 Token Wrapper
 * @author Buttonwood Protocol
 * @notice Wraps fixed-balance ERC-20 tokens into elastic/rebasing tokens based on price oracle
 *
 * @dev The ButtonToken is a rebasing wrapper for fixed balance ERC-20 tokens.
 *      Users deposit the "underlying" (wrapped) tokens and are minted button (wrapper)
 *      tokens with elastic balances which change up or down when the value of the
 *      underlying token changes.
 *
 *      ## How It Works
 *
 *      **Example Scenario:**
 *      1. Manny "wraps" 1 Ether when the price of Ether is $1800
 *      2. Manny receives 1800 ButtonEther tokens in return
 *      3. The overall value of their ButtonEther is the same as their original Ether,
 *         however each unit is now priced at exactly $1
 *      4. The next day, the price of Ether changes to $1900
 *      5. The ButtonEther system detects this price change and rebases
 *      6. Manny's balance is now 1900 ButtonEther tokens, still priced at $1 each
 *
 *      ## Mathematical Model
 *
 *      The ButtonToken math is almost identical to Ampleforth's μFragments.
 *
 *      **For AMPL:**
 *      - Internal account balance: `_gonBalances[account]`
 *      - Internal supply scalar: `gonsPerFragment = TOTAL_GONS / _totalSupply`
 *      - Public balance: `_gonBalances[account] * gonsPerFragment`
 *      - Public total supply: `_totalSupply`
 *
 *      **For ButtonToken (using 'bits'):**
 *      - Underlying token unit price: `p_u = price / 10 ^ (PRICE_DECIMALS)`
 *      - Total underlying tokens: `_totalUnderlying`
 *      - Internal account balance: `_accountBits[account]`
 *      - Internal supply scalar: `_bitsPerToken = TOTAL_BITS / (MAX_UNDERLYING*p_u)`
 *                                               `= BITS_PER_UNDERLYING*(10^PRICE_DECIMALS)/price`
 *                                               `= PRICE_BITS / price`
 *      - User's underlying balance: `_accountBits[account] / BITS_PER_UNDERLYING`
 *      - Public balance: `_accountBits[account] * _bitsPerToken`
 *      - Public total supply: `_totalUnderlying * p_u`
 *
 *      ## Accounting Guarantees
 *
 *      - If address 'A' transfers x button tokens to address 'B':
 *        A's resulting external balance will be decreased by precisely x button tokens,
 *        and B's external balance will be precisely increased by x button tokens.
 *      - If address 'A' deposits y underlying tokens:
 *        A's resulting underlying balance will increase by precisely y.
 *      - If address 'A' withdraws y underlying tokens:
 *        A's resulting underlying balance will decrease by precisely y.
 *
 *      ## Important Notes
 *
 *      - This contract does NOT work with fee-on-transfer (FoT) tokens
 *      - Maximum underlying deposit is capped at MAX_UNDERLYING (1 billion tokens)
 *      - Price oracle must return valid data for the contract to function
 */
contract ButtonToken is IButtonToken, Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    //--------------------------------------------------------------------------
    // Constants
    //--------------------------------------------------------------------------

    /// @dev Maximum value for uint256, used for bit calculations
    uint256 private constant MAX_UINT256 = type(uint256).max;

    /**
     * @notice Maximum units of the underlying token that can be deposited
     * @dev For a underlying token with 18 decimals, MAX_UNDERLYING is 1 billion tokens
     *      This limit prevents overflow in bit calculations
     */
    uint256 public constant MAX_UNDERLYING = 1_000_000_000e18;

    /**
     * @dev TOTAL_BITS is a multiple of MAX_UNDERLYING so that BITS_PER_UNDERLYING is an integer
     *      Uses the highest value that fits in a uint256 for maximum granularity
     */
    uint256 private constant TOTAL_BITS = MAX_UINT256 - (MAX_UINT256 % MAX_UNDERLYING);

    /// @dev Number of BITS per unit of underlying token deposit
    uint256 private constant BITS_PER_UNDERLYING = TOTAL_BITS / MAX_UNDERLYING;

    //--------------------------------------------------------------------------
    // State Variables
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonWrapper
     * @dev The address of the ERC-20 token being wrapped
     */
    address public override underlying;

    /**
     * @inheritdoc IButtonToken
     * @dev Price oracle contract that provides the underlying token's price
     *      Must implement the IOracle interface
     */
    address public override oracle;

    /**
     * @inheritdoc IButtonToken
     * @dev Cached price from the last rebase operation
     *      Updated whenever rebase() is called or on any state-changing operation
     */
    uint256 public override lastPrice;

    /// @dev Rebase counter, incremented each time a successful rebase occurs
    uint256 _epoch;

    /**
     * @inheritdoc IERC20Metadata
     * @dev Human-readable name of the button token (e.g., "Button Wrapped Ether")
     */
    string public override name;

    /**
     * @inheritdoc IERC20Metadata
     * @dev Short symbol of the button token (e.g., "bWETH")
     */
    string public override symbol;

    /**
     * @dev Number of BITS per unit of deposit multiplied by (1 USD equivalent)
     *      Used for price-adjusted bit calculations
     */
    uint256 private priceBits;

    /**
     * @dev Maximum price that can be safely handled without overflow
     *      Calculated as the closest power of two under the true maximum
     *      trueMaxPrice = maximum integer < (sqrt(4*priceBits + 1) - 1) / 2
     */
    uint256 private maxPrice;

    /**
     * @dev Internal balance mapping: bits issued per account
     *      address(0) holds the "unmined" bits (available for new deposits)
     */
    mapping(address => uint256) private _accountBits;

    /// @dev Standard ERC20 allowances mapping
    mapping(address => mapping(address => uint256)) private _allowances;

    //--------------------------------------------------------------------------
    // Modifiers
    //--------------------------------------------------------------------------

    /**
     * @dev Validates that the recipient address is valid
     * @param to The recipient address to validate
     */
    modifier validRecipient(address to) {
        require(to != address(0x0), "ButtonToken: recipient zero address");
        require(to != address(this), "ButtonToken: recipient token address");
        _;
    }

    /**
     * @dev Ensures rebase is called before executing the function
     *      Queries the oracle and rebases if valid price data is available
     */
    modifier onAfterRebase() {
        uint256 price;
        bool valid;
        (price, valid) = _queryPrice();
        if (valid) {
            _rebase(price);
        }
        _;
    }

    //--------------------------------------------------------------------------
    // Initialization
    //--------------------------------------------------------------------------

    /**
     * @notice Initializes the ButtonToken contract
     * @dev Can only be called once due to initializer modifier
     *      Sets up the token with underlying asset, name, symbol, and price oracle
     *
     * @param underlying_ The address of the underlying ERC20 token to wrap
     * @param name_ The human-readable name for the button token
     * @param symbol_ The short symbol for the button token
     * @param oracle_ The address of the price oracle contract
     *
     * Requirements:
     * - underlying_ must not be the zero address
     * - oracle_ must return valid price data
     *
     * Effects:
     * - Sets msg.sender as the owner
     * - Initializes all TOTAL_BITS to address(0) for future minting
     * - Performs initial rebase with oracle price
     *
     * @custom:example
     * ```solidity
     * buttonToken.initialize(
     *     0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,  // WETH
     *     "Button Wrapped Ether",
     *     "bWETH",
     *     0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419   // ETH/USD Chainlink
     * );
     * ```
     */
    function initialize(
        address underlying_,
        string memory name_,
        string memory symbol_,
        address oracle_
    ) public override initializer {
        require(underlying_ != address(0), "ButtonToken: invalid underlying reference");

        // Initializing ownership to `msg.sender`
        __Ownable_init();
        underlying = underlying_;
        name = name_;
        symbol = symbol_;

        // MAX_UNDERLYING worth bits are 'pre-mined' to `address(0x)`
        // at the time of construction.
        //
        // During mint, bits are transferred from `address(0x)`
        // and during burn, bits are transferred back to `address(0x)`.
        //
        // No more than MAX_UNDERLYING can be deposited into the ButtonToken contract.
        _accountBits[address(0)] = TOTAL_BITS;

        updateOracle(oracle_);
    }

    //--------------------------------------------------------------------------
    // Owner Functions
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonToken
     * @notice Updates the price oracle used for rebasing
     * @dev Only callable by the contract owner
     *
     * @param oracle_ The address of the new oracle contract
     *
     * Requirements:
     * - Caller must be the owner
     * - New oracle must return valid price data
     *
     * Effects:
     * - Updates the oracle address
     * - Recalculates priceBits and maxPrice based on oracle's price decimals
     * - Emits OracleUpdated event
     * - Triggers a rebase with the new oracle's price
     *
     * @custom:security Only owner can call this function
     * @custom:emits OracleUpdated(oracle_)
     */
    function updateOracle(address oracle_) public override onlyOwner {
        uint256 price;
        bool valid;

        oracle = oracle_;
        (price, valid) = _queryPrice();
        require(valid, "ButtonToken: unable to fetch data from oracle");

        uint256 priceDecimals = IOracle(oracle).priceDecimals();
        priceBits = BITS_PER_UNDERLYING * (10 ** priceDecimals);
        maxPrice = maxPriceFromPriceDecimals(priceDecimals);

        emit OracleUpdated(oracle);
        _rebase(price);
    }

    //--------------------------------------------------------------------------
    // ERC20 Metadata
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IERC20Metadata
     * @notice Returns the number of decimals used for display purposes
     * @dev Matches the decimals of the underlying token for consistency
     * @return The number of decimals (typically 18)
     */
    function decimals() external view override returns (uint8) {
        return IERC20Metadata(underlying).decimals();
    }

    //--------------------------------------------------------------------------
    // ERC-20 View Functions
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IERC20
     * @notice Returns the total supply of button tokens in circulation
     * @dev Calculated dynamically based on current oracle price
     *      totalSupply = totalUnderlying * currentPrice
     * @return The total supply of button tokens
     */
    function totalSupply() external view override returns (uint256) {
        uint256 price;
        (price, ) = _queryPrice();
        return _bitsToAmount(_activeBits(), price);
    }

    /**
     * @inheritdoc IERC20
     * @notice Returns the button token balance of the specified account
     * @dev Balance changes automatically with price updates (rebasing)
     *      balance = accountBits * bitsPerToken(currentPrice)
     *
     * @param account The address to query the balance of
     * @return The button token balance of the account
     *
     * @custom:example
     * ```solidity
     * uint256 balance = buttonToken.balanceOf(msg.sender);
     * // Balance will change after rebase even without any transfers
     * ```
     */
    function balanceOf(address account) external view override returns (uint256) {
        if (account == address(0)) {
            return 0;
        }
        uint256 price;
        (price, ) = _queryPrice();
        return _bitsToAmount(_accountBits[account], price);
    }

    /**
     * @inheritdoc IRebasingERC20
     * @notice Returns the scaled (underlying) total supply
     * @dev This is the total underlying tokens deposited, unaffected by rebasing
     * @return The scaled total supply in underlying token units
     */
    function scaledTotalSupply() external view override returns (uint256) {
        return _bitsToUAmount(_activeBits());
    }

    /**
     * @inheritdoc IRebasingERC20
     * @notice Returns the scaled (underlying) balance of an account
     * @dev This balance is fixed and doesn't change with rebasing
     *      Use this to get a user's share of the underlying pool
     *
     * @param account The address to query
     * @return The scaled balance in underlying token units
     */
    function scaledBalanceOf(address account) external view override returns (uint256) {
        if (account == address(0)) {
            return 0;
        }
        return _bitsToUAmount(_accountBits[account]);
    }

    /**
     * @inheritdoc IERC20
     * @notice Returns the remaining allowance for a spender
     * @dev Standard ERC20 allowance - not affected by rebasing
     *
     * @param owner_ The address of the token owner
     * @param spender The address of the approved spender
     * @return The remaining allowance in button token units
     */
    function allowance(address owner_, address spender) external view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    //--------------------------------------------------------------------------
    // ButtonWrapper View Functions
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonWrapper
     * @notice Returns the total underlying tokens held by this contract
     * @dev Equivalent to the ERC20 balance of underlying tokens in this contract
     * @return The total underlying token balance
     */
    function totalUnderlying() external view override returns (uint256) {
        return _bitsToUAmount(_activeBits());
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Returns the underlying token balance attributable to an account
     * @dev This is the amount of underlying tokens the user could withdraw
     *
     * @param who The address to query
     * @return The underlying token balance
     *
     * @custom:example
     * ```solidity
     * uint256 underlying = buttonToken.balanceOfUnderlying(msg.sender);
     * // This value stays constant regardless of price changes
     * ```
     */
    function balanceOfUnderlying(address who) external view override returns (uint256) {
        if (who == address(0)) {
            return 0;
        }
        return _bitsToUAmount(_accountBits[who]);
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Converts underlying token amount to button token amount
     * @dev Useful for calculating expected button tokens from a deposit
     *
     * @param uAmount The amount of underlying tokens
     * @return The equivalent amount of button tokens at current price
     *
     * @custom:example
     * ```solidity
     * uint256 expectedButtons = buttonToken.underlyingToWrapper(1 ether);
     * // If price is $2000, returns 2000e18 (2000 button tokens)
     * ```
     */
    function underlyingToWrapper(uint256 uAmount) external view override returns (uint256) {
        uint256 price;
        (price, ) = _queryPrice();
        return _bitsToAmount(_uAmountToBits(uAmount), price);
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Converts button token amount to underlying token amount
     * @dev Useful for calculating underlying tokens received from a burn
     *
     * @param amount The amount of button tokens
     * @return The equivalent amount of underlying tokens at current price
     *
     * @custom:example
     * ```solidity
     * uint256 underlying = buttonToken.wrapperToUnderlying(2000e18);
     * // If price is $2000, returns 1e18 (1 underlying token)
     * ```
     */
    function wrapperToUnderlying(uint256 amount) external view override returns (uint256) {
        uint256 price;
        (price, ) = _queryPrice();
        return _bitsToUAmount(_amountToBits(amount, price));
    }

    //--------------------------------------------------------------------------
    // ERC-20 Write Functions
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IERC20
     * @notice Transfers button tokens to a recipient
     * @dev Triggers rebase before transfer. Amount is in button tokens (rebased)
     *
     * @param to The recipient address
     * @param amount The amount of button tokens to transfer
     * @return success True if transfer succeeded
     *
     * Requirements:
     * - to cannot be zero address or this contract
     * - Caller must have sufficient balance
     *
     * @custom:emits Transfer(from, to, amount)
     */
    function transfer(
        address to,
        uint256 amount
    ) external override validRecipient(to) onAfterRebase returns (bool) {
        _transfer(_msgSender(), to, _amountToBits(amount, lastPrice), amount);
        return true;
    }

    /**
     * @inheritdoc IRebasingERC20
     * @notice Transfers the entire button token balance to a recipient
     * @dev Useful for avoiding dust from rounding errors
     *
     * @param to The recipient address
     * @return success True if transfer succeeded
     *
     * @custom:example
     * ```solidity
     * // Transfer 100% of balance, avoiding rounding dust
     * buttonToken.transferAll(recipient);
     * ```
     */
    function transferAll(
        address to
    ) external override validRecipient(to) onAfterRebase returns (bool) {
        uint256 bits = _accountBits[_msgSender()];
        _transfer(_msgSender(), to, bits, _bitsToAmount(bits, lastPrice));
        return true;
    }

    /**
     * @inheritdoc IERC20
     * @notice Transfers button tokens from one address to another
     * @dev Requires approval. Supports infinite approval (type(uint256).max)
     *
     * @param from The sender address
     * @param to The recipient address
     * @param amount The amount of button tokens to transfer
     * @return success True if transfer succeeded
     *
     * Requirements:
     * - from must have sufficient balance
     * - Caller must have sufficient allowance (or infinite approval)
     *
     * @custom:note Infinite approvals (type(uint256).max) are not decremented
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external override validRecipient(to) onAfterRebase returns (bool) {
        if (_allowances[from][_msgSender()] != type(uint256).max) {
            _allowances[from][_msgSender()] -= amount;
            emit Approval(from, _msgSender(), _allowances[from][_msgSender()]);
        }

        _transfer(from, to, _amountToBits(amount, lastPrice), amount);
        return true;
    }

    /**
     * @inheritdoc IRebasingERC20
     * @notice Transfers the entire balance from one address to another
     * @dev Requires approval for at least the sender's full balance
     *
     * @param from The sender address
     * @param to The recipient address
     * @return success True if transfer succeeded
     */
    function transferAllFrom(
        address from,
        address to
    ) external override validRecipient(to) onAfterRebase returns (bool) {
        uint256 bits = _accountBits[from];
        uint256 amount = _bitsToAmount(bits, lastPrice);

        if (_allowances[from][_msgSender()] != type(uint256).max) {
            _allowances[from][_msgSender()] -= amount;
            emit Approval(from, _msgSender(), _allowances[from][_msgSender()]);
        }

        _transfer(from, to, bits, amount);
        return true;
    }

    /**
     * @inheritdoc IERC20
     * @notice Approves a spender to transfer button tokens
     * @dev Set to type(uint256).max for infinite approval
     *
     * @param spender The address to approve
     * @param amount The maximum amount to approve
     * @return success True if approval succeeded
     *
     * @custom:security Be careful with approvals, prefer increaseAllowance
     * @custom:emits Approval(owner, spender, amount)
     */
    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[_msgSender()][spender] = amount;

        emit Approval(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @notice Increases the allowance for a spender
     * @dev Safer than approve() for increasing allowance
     *
     * @param spender The address to increase allowance for
     * @param addedAmount The amount to add to the current allowance
     * @return success True if operation succeeded
     */
    function increaseAllowance(address spender, uint256 addedAmount) external returns (bool) {
        _allowances[_msgSender()][spender] += addedAmount;

        emit Approval(_msgSender(), spender, _allowances[_msgSender()][spender]);
        return true;
    }

    /**
     * @notice Decreases the allowance for a spender
     * @dev Saturates at zero (won't underflow)
     *
     * @param spender The address to decrease allowance for
     * @param subtractedAmount The amount to subtract from current allowance
     * @return success True if operation succeeded
     */
    function decreaseAllowance(address spender, uint256 subtractedAmount) external returns (bool) {
        if (subtractedAmount >= _allowances[_msgSender()][spender]) {
            delete _allowances[_msgSender()][spender];
        } else {
            _allowances[_msgSender()][spender] -= subtractedAmount;
        }

        emit Approval(_msgSender(), spender, _allowances[_msgSender()][spender]);
        return true;
    }

    //--------------------------------------------------------------------------
    // Rebasing Functions
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IRebasingERC20
     * @notice Triggers a manual rebase
     * @dev Called automatically by most state-changing functions
     *      Can be called manually to update balances without a transfer
     *
     * @custom:emits Rebase(epoch, newPrice) if price changed
     */
    function rebase() external override onAfterRebase {
        return;
    }

    //--------------------------------------------------------------------------
    // ButtonWrapper Write Functions - Minting
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonWrapper
     * @notice Mints a specific amount of button tokens
     * @dev Pulls the required underlying tokens automatically
     *
     * @param amount The desired amount of button tokens to mint
     * @return uAmount The amount of underlying tokens deposited
     *
     * Requirements:
     * - Caller must have approved this contract for underlying tokens
     * - Resulting underlying deposit must be > 0
     *
     * @custom:example
     * ```solidity
     * // Mint exactly 2000 button tokens
     * underlying.approve(address(buttonToken), type(uint256).max);
     * uint256 underlyingUsed = buttonToken.mint(2000e18);
     * ```
     */
    function mint(uint256 amount) external override onAfterRebase returns (uint256) {
        uint256 bits = _amountToBits(amount, lastPrice);
        uint256 uAmount = _bitsToUAmount(bits);
        _deposit(_msgSender(), _msgSender(), uAmount, amount, bits);
        return uAmount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Mints button tokens to a specified recipient
     * @dev Caller provides underlying, recipient receives button tokens
     *
     * @param to The recipient of the minted button tokens
     * @param amount The desired amount of button tokens to mint
     * @return uAmount The amount of underlying tokens deposited
     */
    function mintFor(address to, uint256 amount) external override onAfterRebase returns (uint256) {
        uint256 bits = _amountToBits(amount, lastPrice);
        uint256 uAmount = _bitsToUAmount(bits);
        _deposit(_msgSender(), to, uAmount, amount, bits);
        return uAmount;
    }

    //--------------------------------------------------------------------------
    // ButtonWrapper Write Functions - Burning
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonWrapper
     * @notice Burns button tokens and returns underlying
     * @dev Calculates underlying amount from button token amount
     *
     * @param amount The amount of button tokens to burn
     * @return uAmount The amount of underlying tokens returned
     *
     * @custom:example
     * ```solidity
     * // Burn 2000 button tokens, receive underlying
     * uint256 underlyingReceived = buttonToken.burn(2000e18);
     * ```
     */
    function burn(uint256 amount) external override onAfterRebase returns (uint256) {
        uint256 bits = _amountToBits(amount, lastPrice);
        uint256 uAmount = _bitsToUAmount(bits);
        _withdraw(_msgSender(), _msgSender(), uAmount, amount, bits);
        return uAmount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Burns button tokens and sends underlying to recipient
     *
     * @param to The recipient of the underlying tokens
     * @param amount The amount of button tokens to burn
     * @return uAmount The amount of underlying tokens returned
     */
    function burnTo(address to, uint256 amount) external override onAfterRebase returns (uint256) {
        uint256 bits = _amountToBits(amount, lastPrice);
        uint256 uAmount = _bitsToUAmount(bits);
        _withdraw(_msgSender(), to, uAmount, amount, bits);
        return uAmount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Burns all button tokens and returns underlying
     * @dev Use this to avoid dust from rounding
     *
     * @return uAmount The amount of underlying tokens returned
     */
    function burnAll() external override onAfterRebase returns (uint256) {
        uint256 bits = _accountBits[_msgSender()];
        uint256 uAmount = _bitsToUAmount(bits);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _withdraw(_msgSender(), _msgSender(), uAmount, amount, bits);
        return uAmount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Burns all button tokens and sends underlying to recipient
     *
     * @param to The recipient of the underlying tokens
     * @return uAmount The amount of underlying tokens returned
     */
    function burnAllTo(address to) external override onAfterRebase returns (uint256) {
        uint256 bits = _accountBits[_msgSender()];
        uint256 uAmount = _bitsToUAmount(bits);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _withdraw(_msgSender(), to, uAmount, amount, bits);
        return uAmount;
    }

    //--------------------------------------------------------------------------
    // ButtonWrapper Write Functions - Depositing
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonWrapper
     * @notice Deposits underlying tokens and mints button tokens
     * @dev This is the primary deposit function
     *
     * @param uAmount The amount of underlying tokens to deposit
     * @return amount The amount of button tokens minted
     *
     * Requirements:
     * - Caller must have approved this contract for underlying tokens
     * - uAmount must be > 0
     *
     * @custom:example
     * ```solidity
     * // Deposit 1 WETH, receive button tokens based on price
     * weth.approve(address(buttonToken), 1 ether);
     * uint256 buttonsReceived = buttonToken.deposit(1 ether);
     * ```
     */
    function deposit(uint256 uAmount) external override onAfterRebase returns (uint256) {
        uint256 bits = _uAmountToBits(uAmount);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _deposit(_msgSender(), _msgSender(), uAmount, amount, bits);
        return amount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Deposits underlying and mints button tokens to recipient
     * @dev Caller provides underlying, recipient receives button tokens
     *
     * @param to The recipient of the minted button tokens
     * @param uAmount The amount of underlying tokens to deposit
     * @return amount The amount of button tokens minted
     */
    function depositFor(
        address to,
        uint256 uAmount
    ) external override onAfterRebase returns (uint256) {
        uint256 bits = _uAmountToBits(uAmount);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _deposit(_msgSender(), to, uAmount, amount, bits);
        return amount;
    }

    //--------------------------------------------------------------------------
    // ButtonWrapper Write Functions - Withdrawing
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonWrapper
     * @notice Withdraws underlying tokens by specifying underlying amount
     *
     * @param uAmount The amount of underlying tokens to withdraw
     * @return amount The amount of button tokens burned
     */
    function withdraw(uint256 uAmount) external override onAfterRebase returns (uint256) {
        uint256 bits = _uAmountToBits(uAmount);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _withdraw(_msgSender(), _msgSender(), uAmount, amount, bits);
        return amount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Withdraws underlying tokens to a specified recipient
     *
     * @param to The recipient of the underlying tokens
     * @param uAmount The amount of underlying tokens to withdraw
     * @return amount The amount of button tokens burned
     */
    function withdrawTo(
        address to,
        uint256 uAmount
    ) external override onAfterRebase returns (uint256) {
        uint256 bits = _uAmountToBits(uAmount);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _withdraw(_msgSender(), to, uAmount, amount, bits);
        return amount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Withdraws all underlying tokens
     * @dev Use this to avoid dust from rounding
     *
     * @return amount The amount of button tokens burned
     */
    function withdrawAll() external override onAfterRebase returns (uint256) {
        uint256 bits = _accountBits[_msgSender()];
        uint256 uAmount = _bitsToUAmount(bits);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _withdraw(_msgSender(), _msgSender(), uAmount, amount, bits);
        return amount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Withdraws all underlying tokens to a specified recipient
     *
     * @param to The recipient of the underlying tokens
     * @return amount The amount of button tokens burned
     */
    function withdrawAllTo(address to) external override onAfterRebase returns (uint256) {
        uint256 bits = _accountBits[_msgSender()];
        uint256 uAmount = _bitsToUAmount(bits);
        uint256 amount = _bitsToAmount(bits, lastPrice);
        _withdraw(_msgSender(), to, uAmount, amount, bits);
        return amount;
    }

    //--------------------------------------------------------------------------
    // Private Functions
    //--------------------------------------------------------------------------

    /**
     * @dev Internal method to commit deposit state
     * @param from Address providing underlying tokens
     * @param to Address receiving button tokens
     * @param uAmount Amount of underlying tokens
     * @param amount Amount of button tokens
     * @param bits Internal bit representation
     *
     * NOTE: Expects bits, uAmount, amount to be pre-calculated
     */
    function _deposit(
        address from,
        address to,
        uint256 uAmount,
        uint256 amount,
        uint256 bits
    ) private {
        require(uAmount > 0, "ButtonToken: No tokens deposited");
        require(amount > 0, "ButtonToken: too few button tokens to mint");

        IERC20(underlying).safeTransferFrom(from, address(this), uAmount);

        _transfer(address(0), to, bits, amount);
    }

    /**
     * @dev Internal method to commit withdraw state
     * @param from Address burning button tokens
     * @param to Address receiving underlying tokens
     * @param uAmount Amount of underlying tokens
     * @param amount Amount of button tokens
     * @param bits Internal bit representation
     *
     * NOTE: Expects bits, uAmount, amount to be pre-calculated
     */
    function _withdraw(
        address from,
        address to,
        uint256 uAmount,
        uint256 amount,
        uint256 bits
    ) private {
        require(amount > 0, "ButtonToken: too few button tokens to burn");

        _transfer(from, address(0), bits, amount);

        IERC20(underlying).safeTransfer(to, uAmount);
    }

    /**
     * @dev Internal method to commit transfer state
     * @param from Source address (address(0) for minting)
     * @param to Destination address (address(0) for burning)
     * @param bits Amount in internal bits
     * @param amount Amount in button tokens (for event)
     *
     * NOTE: Expects bits/amounts to be pre-calculated
     */
    function _transfer(address from, address to, uint256 bits, uint256 amount) private {
        _accountBits[from] -= bits;
        _accountBits[to] += bits;

        emit Transfer(from, to, amount);

        if (_accountBits[from] == 0) {
            delete _accountBits[from];
        }
    }

    /**
     * @dev Updates the `lastPrice` and recomputes the internal scalar
     * @param price The new price from the oracle
     *
     * Effects:
     * - Caps price at maxPrice to prevent overflow
     * - Updates lastPrice
     * - Increments epoch counter
     * - Emits Rebase event
     */
    function _rebase(uint256 price) private {
        uint256 _maxPrice = maxPrice;
        if (price > _maxPrice) {
            price = _maxPrice;
        }

        lastPrice = price;

        _epoch++;

        emit Rebase(_epoch, price);
    }

    /**
     * @dev Returns the active "un-mined" bits
     * @return The total bits in circulation (not held by address(0))
     */
    function _activeBits() private view returns (uint256) {
        return TOTAL_BITS - _accountBits[address(0)];
    }

    /**
     * @dev Queries the oracle for the latest price
     * @return newPrice The price to use (either fresh or cached)
     * @return valid Whether the oracle returned valid data
     *
     * NOTE: Returns lastPrice if oracle data is invalid or price is 0
     *       Price of 0 is invalid because it would cause division by zero
     */
    function _queryPrice() private view returns (uint256, bool) {
        uint256 newPrice;
        bool valid;
        (newPrice, valid) = IOracle(oracle).getData();

        // Note: we consider newPrice == 0 to be invalid because accounting fails with price == 0
        // For example, _bitsPerToken needs to be able to divide by price so a div/0 is caused
        return (valid && newPrice > 0 ? newPrice : lastPrice, valid && newPrice > 0);
    }

    /**
     * @dev Convert button token amount to bits
     * @param amount Amount in button tokens
     * @param price Current price
     * @return bits Internal bit representation
     */
    function _amountToBits(uint256 amount, uint256 price) private view returns (uint256) {
        return amount * _bitsPerToken(price);
    }

    /**
     * @dev Convert underlying token amount to bits
     * @param uAmount Amount in underlying tokens
     * @return bits Internal bit representation
     */
    function _uAmountToBits(uint256 uAmount) private pure returns (uint256) {
        return uAmount * BITS_PER_UNDERLYING;
    }

    /**
     * @dev Convert bits to button token amount
     * @param bits Internal bit representation
     * @param price Current price
     * @return amount Amount in button tokens
     */
    function _bitsToAmount(uint256 bits, uint256 price) private view returns (uint256) {
        return bits / _bitsPerToken(price);
    }

    /**
     * @dev Convert bits to underlying token amount
     * @param bits Internal bit representation
     * @return uAmount Amount in underlying tokens
     */
    function _bitsToUAmount(uint256 bits) private pure returns (uint256) {
        return bits / BITS_PER_UNDERLYING;
    }

    /**
     * @dev Internal scalar to convert bits to button tokens
     * @param price Current price from oracle
     * @return Bits per button token at the given price
     */
    function _bitsPerToken(uint256 price) private view returns (uint256) {
        return priceBits / price;
    }

    /**
     * @dev Derives max-price based on price-decimals
     * @param priceDecimals Number of decimals in the price feed
     * @return maxPrice Maximum safe price value for the given decimals
     *
     * NOTE: Optimized for common decimal values (18, 8, 6)
     */
    function maxPriceFromPriceDecimals(uint256 priceDecimals) private pure returns (uint256) {
        require(priceDecimals <= 18, "ButtonToken: Price Decimals must be under 18");
        // Given that 18,8,6 are the most common price decimals, we optimize for those cases
        if (priceDecimals == 18) {
            return 2 ** 113 - 1;
        }
        if (priceDecimals == 8) {
            return 2 ** 96 - 1;
        }
        if (priceDecimals == 6) {
            return 2 ** 93 - 1;
        }
        if (priceDecimals == 0) {
            return 2 ** 83 - 1;
        }
        if (priceDecimals == 1) {
            return 2 ** 84 - 1;
        }
        if (priceDecimals == 2) {
            return 2 ** 86 - 1;
        }
        if (priceDecimals == 3) {
            return 2 ** 88 - 1;
        }
        if (priceDecimals == 4) {
            return 2 ** 89 - 1;
        }
        if (priceDecimals == 5) {
            return 2 ** 91 - 1;
        }
        if (priceDecimals == 7) {
            return 2 ** 94 - 1;
        }
        if (priceDecimals == 9) {
            return 2 ** 98 - 1;
        }
        if (priceDecimals == 10) {
            return 2 ** 99 - 1;
        }
        if (priceDecimals == 11) {
            return 2 ** 101 - 1;
        }
        if (priceDecimals == 12) {
            return 2 ** 103 - 1;
        }
        if (priceDecimals == 13) {
            return 2 ** 104 - 1;
        }
        if (priceDecimals == 14) {
            return 2 ** 106 - 1;
        }
        if (priceDecimals == 15) {
            return 2 ** 108 - 1;
        }
        if (priceDecimals == 16) {
            return 2 ** 109 - 1;
        }
        // priceDecimals == 17
        return 2 ** 111 - 1;
    }
}
