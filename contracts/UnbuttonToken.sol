// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;

import {IButtonWrapper} from "./interfaces/IButtonWrapper.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
// solhint-disable-next-line max-line-length
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
// solhint-disable-next-line max-line-length
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";

/**
 * @title UnbuttonToken - Fixed Balance ERC20 Token Wrapper
 * @author Buttonwood Protocol
 * @notice Wraps elastic/rebasing tokens into fixed-balance tokens using a share-based model
 *
 * @dev The UnbuttonToken wraps elastic balance (rebasing) tokens like AMPL, Chai,
 *      and AAVE's aTokens, to create a fixed balance representation.
 *
 *      ## How It Works
 *
 *      The ratio of a user's balance to the total supply represents their share
 *      of the total deposit pool. As the underlying rebasing token changes its
 *      supply, the user's UnbuttonToken balance stays the same, but their
 *      proportional claim to the underlying pool remains constant.
 *
 *      **Example Scenario:**
 *      1. Alice deposits 1,000 AMPL when total pool is 10,000 AMPL
 *      2. Alice receives UnbuttonAMPL tokens representing 10% of the pool
 *      3. AMPL rebases and the pool grows to 12,000 AMPL
 *      4. Alice's UnbuttonAMPL balance is unchanged
 *      5. Alice can now withdraw 1,200 AMPL (still 10% of the pool)
 *
 *      ## Use Cases
 *
 *      - **DeFi Integration**: Makes rebasing tokens compatible with protocols
 *        that expect fixed balances (lending, AMMs, etc.)
 *      - **Portfolio Management**: Simplifies accounting for rebasing assets
 *      - **Yield Farming**: Enables rebasing tokens in yield aggregators
 *
 *      ## Mathematical Model
 *
 *      - `userShares = userDeposit * totalSupply / totalUnderlying`
 *      - `userUnderlying = userShares * totalUnderlying / totalSupply`
 *
 *      ## Security Considerations
 *
 *      The maximum units of the underlying token that can be safely deposited
 *      without numeric overflow is calculated as:
 *
 *      `MAX_UNDERLYING = sqrt(MAX_UINT256 / INITIAL_RATE)`
 *
 *      where INITIAL_RATE is the conversion between underlying tokens to
 *      unbutton tokens for the initial mint.
 *
 *      Since underlying balances increase due to both:
 *      1. Users depositing into this contract
 *      2. The underlying token rebasing
 *
 *      There's no way to absolutely ENFORCE this bound. In practice,
 *      the underlying of any token with a reasonable supply will never
 *      reach this limit.
 */
contract UnbuttonToken is IButtonWrapper, ERC20PermitUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    //--------------------------------------------------------------------------
    // Constants
    //--------------------------------------------------------------------------

    /**
     * @notice Small deposit locked to the contract to ensure totalUnderlying is always non-zero
     * @dev This prevents division by zero in share calculations and ensures
     *      the first depositor cannot manipulate the share price
     */
    uint256 public constant INITIAL_DEPOSIT = 1_000;

    //--------------------------------------------------------------------------
    // State Variables
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonWrapper
     * @dev The address of the rebasing ERC-20 token being wrapped (e.g., AMPL, aToken)
     */
    address public override underlying;

    //--------------------------------------------------------------------------
    // Initialization
    //--------------------------------------------------------------------------

    /**
     * @notice Initializes the UnbuttonToken contract
     * @dev Can only be called once. Sets up the token with underlying asset and initial rate.
     *      Makes an initial micro-deposit to prevent share price manipulation.
     *
     * @param underlying_ The address of the rebasing ERC20 token to wrap
     * @param name_ The human-readable name for the unbutton token
     * @param symbol_ The short symbol for the unbutton token
     * @param initialRate The initial conversion rate (unbutton tokens per underlying)
     *
     * Requirements:
     * - Caller must have approved this contract for at least INITIAL_DEPOSIT of underlying
     * - underlying_ must be a valid ERC20 address
     *
     * Effects:
     * - Transfers INITIAL_DEPOSIT from caller to this contract
     * - Mints INITIAL_DEPOSIT * initialRate unbutton tokens to this contract
     * - These initial tokens are permanently locked to prevent share manipulation
     *
     * @custom:example
     * ```solidity
     * // Approve the factory first
     * ampl.approve(address(factory), 1000);
     *
     * // Create UnbuttonAMPL with 1:1 initial rate
     * unbuttonToken.initialize(
     *     address(ampl),      // AMPL token
     *     "Unbutton AMPL",    // Name
     *     "ubAMPL",           // Symbol
     *     1                   // Initial rate: 1 ubAMPL per AMPL
     * );
     * ```
     *
     * @custom:security Initial deposit prevents first-depositor front-running attacks
     */
    function initialize(
        address underlying_,
        string memory name_,
        string memory symbol_,
        uint256 initialRate
    ) public initializer {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        underlying = underlying_;

        // NOTE: First mint with initial micro deposit
        // This ensures totalUnderlying() and totalSupply() are never zero
        uint256 mintAmount = INITIAL_DEPOSIT * initialRate;
        IERC20Upgradeable(underlying).safeTransferFrom(
            _msgSender(),
            address(this),
            INITIAL_DEPOSIT
        );
        _mint(address(this), mintAmount);
    }

    //--------------------------------------------------------------------------
    // ButtonWrapper Write Functions - Minting
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonWrapper
     * @notice Mints a specific amount of unbutton tokens
     * @dev Calculates and pulls the required underlying tokens automatically
     *
     * @param amount The desired amount of unbutton tokens to mint
     * @return uAmount The amount of underlying tokens deposited
     *
     * Requirements:
     * - Caller must have approved this contract for sufficient underlying
     * - amount must result in uAmount > 0 after calculation
     *
     * @custom:formula uAmount = amount * totalUnderlying / totalSupply
     *
     * @custom:example
     * ```solidity
     * // Mint exactly 100 unbutton tokens
     * ampl.approve(address(unbuttonToken), type(uint256).max);
     * uint256 amplUsed = unbuttonToken.mint(100e18);
     * ```
     */
    function mint(uint256 amount) external override returns (uint256) {
        uint256 uAmount = _toUnderlyingAmount(amount, _queryUnderlyingBalance(), totalSupply());
        _deposit(_msgSender(), _msgSender(), uAmount, amount);
        return uAmount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Mints unbutton tokens to a specified recipient
     * @dev Caller provides underlying tokens, recipient receives unbutton tokens
     *
     * @param to The recipient of the minted unbutton tokens
     * @param amount The desired amount of unbutton tokens to mint
     * @return uAmount The amount of underlying tokens deposited
     */
    function mintFor(address to, uint256 amount) external override returns (uint256) {
        uint256 uAmount = _toUnderlyingAmount(amount, _queryUnderlyingBalance(), totalSupply());
        _deposit(_msgSender(), to, uAmount, amount);
        return uAmount;
    }

    //--------------------------------------------------------------------------
    // ButtonWrapper Write Functions - Burning
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonWrapper
     * @notice Burns unbutton tokens and returns underlying
     * @dev Calculates underlying amount based on current share price
     *
     * @param amount The amount of unbutton tokens to burn
     * @return uAmount The amount of underlying tokens returned
     *
     * @custom:formula uAmount = amount * totalUnderlying / totalSupply
     *
     * @custom:example
     * ```solidity
     * // Burn 100 unbutton tokens, receive underlying
     * uint256 amplReceived = unbuttonToken.burn(100e18);
     * ```
     */
    function burn(uint256 amount) external override returns (uint256) {
        uint256 uAmount = _toUnderlyingAmount(amount, _queryUnderlyingBalance(), totalSupply());
        _withdraw(_msgSender(), _msgSender(), uAmount, amount);
        return uAmount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Burns unbutton tokens and sends underlying to recipient
     *
     * @param to The recipient of the underlying tokens
     * @param amount The amount of unbutton tokens to burn
     * @return uAmount The amount of underlying tokens returned
     */
    function burnTo(address to, uint256 amount) external override returns (uint256) {
        uint256 uAmount = _toUnderlyingAmount(amount, _queryUnderlyingBalance(), totalSupply());
        _withdraw(_msgSender(), to, uAmount, amount);
        return uAmount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Burns all unbutton tokens and returns underlying
     * @dev Use this to withdraw 100% of your position without dust
     *
     * @return uAmount The amount of underlying tokens returned
     *
     * @custom:example
     * ```solidity
     * // Withdraw entire position
     * uint256 totalAmpl = unbuttonToken.burnAll();
     * ```
     */
    function burnAll() external override returns (uint256) {
        uint256 amount = balanceOf(_msgSender());
        uint256 uAmount = _toUnderlyingAmount(amount, _queryUnderlyingBalance(), totalSupply());
        _withdraw(_msgSender(), _msgSender(), uAmount, amount);
        return uAmount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Burns all unbutton tokens and sends underlying to recipient
     *
     * @param to The recipient of the underlying tokens
     * @return uAmount The amount of underlying tokens returned
     */
    function burnAllTo(address to) external override returns (uint256) {
        uint256 amount = balanceOf(_msgSender());
        uint256 uAmount = _toUnderlyingAmount(amount, _queryUnderlyingBalance(), totalSupply());
        _withdraw(_msgSender(), to, uAmount, amount);
        return uAmount;
    }

    //--------------------------------------------------------------------------
    // ButtonWrapper Write Functions - Depositing
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonWrapper
     * @notice Deposits underlying tokens and mints unbutton tokens
     * @dev This is the primary deposit function
     *
     * @param uAmount The amount of underlying (rebasing) tokens to deposit
     * @return amount The amount of unbutton tokens minted
     *
     * Requirements:
     * - Caller must have approved this contract for uAmount of underlying
     * - uAmount must be > 0
     *
     * @custom:formula amount = uAmount * totalSupply / totalUnderlying
     *
     * @custom:example
     * ```solidity
     * // Deposit 1000 AMPL, receive unbutton tokens
     * ampl.approve(address(unbuttonToken), 1000e9);
     * uint256 sharesReceived = unbuttonToken.deposit(1000e9);
     * ```
     */
    function deposit(uint256 uAmount) external override returns (uint256) {
        uint256 amount = _fromUnderlyingAmount(uAmount, _queryUnderlyingBalance(), totalSupply());
        _deposit(_msgSender(), _msgSender(), uAmount, amount);
        return amount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Deposits underlying and mints unbutton tokens to recipient
     * @dev Caller provides underlying, recipient receives unbutton tokens
     *
     * @param to The recipient of the minted unbutton tokens
     * @param uAmount The amount of underlying tokens to deposit
     * @return amount The amount of unbutton tokens minted
     */
    function depositFor(address to, uint256 uAmount) external override returns (uint256) {
        uint256 amount = _fromUnderlyingAmount(uAmount, _queryUnderlyingBalance(), totalSupply());
        _deposit(_msgSender(), to, uAmount, amount);
        return amount;
    }

    //--------------------------------------------------------------------------
    // ButtonWrapper Write Functions - Withdrawing
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonWrapper
     * @notice Withdraws a specific amount of underlying tokens
     * @dev Burns the required unbutton tokens automatically
     *
     * @param uAmount The amount of underlying tokens to withdraw
     * @return amount The amount of unbutton tokens burned
     *
     * @custom:formula amount = uAmount * totalSupply / totalUnderlying
     */
    function withdraw(uint256 uAmount) external override returns (uint256) {
        uint256 amount = _fromUnderlyingAmount(uAmount, _queryUnderlyingBalance(), totalSupply());
        _withdraw(_msgSender(), _msgSender(), uAmount, amount);
        return amount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Withdraws underlying tokens to a specified recipient
     *
     * @param to The recipient of the underlying tokens
     * @param uAmount The amount of underlying tokens to withdraw
     * @return amount The amount of unbutton tokens burned
     */
    function withdrawTo(address to, uint256 uAmount) external override returns (uint256) {
        uint256 amount = _fromUnderlyingAmount(uAmount, _queryUnderlyingBalance(), totalSupply());
        _withdraw(_msgSender(), to, uAmount, amount);
        return amount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Withdraws all underlying tokens
     * @dev Use this to withdraw 100% of your position without dust
     *
     * @return amount The amount of unbutton tokens burned
     */
    function withdrawAll() external override returns (uint256) {
        uint256 amount = balanceOf(_msgSender());
        uint256 uAmount = _toUnderlyingAmount(amount, _queryUnderlyingBalance(), totalSupply());
        _withdraw(_msgSender(), _msgSender(), uAmount, amount);
        return amount;
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Withdraws all underlying tokens to a specified recipient
     *
     * @param to The recipient of the underlying tokens
     * @return amount The amount of unbutton tokens burned
     */
    function withdrawAllTo(address to) external override returns (uint256) {
        uint256 amount = balanceOf(_msgSender());
        uint256 uAmount = _toUnderlyingAmount(amount, _queryUnderlyingBalance(), totalSupply());
        _withdraw(_msgSender(), to, uAmount, amount);
        return amount;
    }

    //--------------------------------------------------------------------------
    // ButtonWrapper View Functions
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IButtonWrapper
     * @notice Returns the total underlying tokens held by this contract
     * @dev This value changes as the underlying rebasing token changes supply
     * @return The current balance of underlying tokens in the contract
     *
     * @custom:note Value increases/decreases with rebases even without deposits
     */
    function totalUnderlying() external view override returns (uint256) {
        return _queryUnderlyingBalance();
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Returns the underlying token balance attributable to an account
     * @dev Calculated as: userBalance * totalUnderlying / totalSupply
     *
     * @param owner The address to query
     * @return The underlying token balance
     *
     * @custom:example
     * ```solidity
     * // Check how much AMPL you can withdraw
     * uint256 myAmpl = unbuttonToken.balanceOfUnderlying(msg.sender);
     * // This value changes as AMPL rebases!
     * ```
     */
    function balanceOfUnderlying(address owner) external view override returns (uint256) {
        return _toUnderlyingAmount(balanceOf(owner), _queryUnderlyingBalance(), totalSupply());
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Converts underlying token amount to unbutton token amount
     * @dev Useful for calculating expected shares from a deposit
     *
     * @param uAmount The amount of underlying tokens
     * @return The equivalent amount of unbutton tokens
     *
     * @custom:formula shares = uAmount * totalSupply / totalUnderlying
     */
    function underlyingToWrapper(uint256 uAmount) external view override returns (uint256) {
        return _fromUnderlyingAmount(uAmount, _queryUnderlyingBalance(), totalSupply());
    }

    /**
     * @inheritdoc IButtonWrapper
     * @notice Converts unbutton token amount to underlying token amount
     * @dev Useful for calculating underlying tokens received from a burn
     *
     * @param amount The amount of unbutton tokens
     * @return The equivalent amount of underlying tokens
     *
     * @custom:formula underlying = amount * totalUnderlying / totalSupply
     */
    function wrapperToUnderlying(uint256 amount) external view override returns (uint256) {
        return _toUnderlyingAmount(amount, _queryUnderlyingBalance(), totalSupply());
    }

    //--------------------------------------------------------------------------
    // Private Functions
    //--------------------------------------------------------------------------

    /**
     * @dev Internal method to commit deposit state
     * @param from Address providing underlying tokens
     * @param to Address receiving unbutton tokens
     * @param uAmount Amount of underlying tokens
     * @param amount Amount of unbutton tokens to mint
     *
     * NOTE: Expects uAmount, amount to be pre-calculated
     */
    function _deposit(address from, address to, uint256 uAmount, uint256 amount) private {
        require(amount > 0, "UnbuttonToken: too few unbutton tokens to mint");

        // Transfer underlying token from the initiator to the contract
        IERC20Upgradeable(underlying).safeTransferFrom(from, address(this), uAmount);

        // Mint unbutton token to the beneficiary
        _mint(to, amount);
    }

    /**
     * @dev Internal method to commit withdraw state
     * @param from Address burning unbutton tokens
     * @param to Address receiving underlying tokens
     * @param uAmount Amount of underlying tokens
     * @param amount Amount of unbutton tokens to burn
     *
     * NOTE: Expects uAmount, amount to be pre-calculated
     */
    function _withdraw(address from, address to, uint256 uAmount, uint256 amount) private {
        require(amount > 0, "UnbuttonToken: too few unbutton tokens to burn");

        // Burn unbutton tokens from the initiator
        _burn(from, amount);

        // Transfer underlying tokens to the beneficiary
        IERC20Upgradeable(underlying).safeTransfer(to, uAmount);
    }

    /**
     * @dev Queries the underlying ERC-20 balance of this contract
     * @return The current balance of underlying tokens held by this contract
     *
     * @custom:note This balance changes with rebases of the underlying token
     */
    function _queryUnderlyingBalance() private view returns (uint256) {
        return IERC20Upgradeable(underlying).balanceOf(address(this));
    }

    /**
     * @dev Converts underlying to unbutton token amount
     * @param uAmount Amount of underlying tokens
     * @param totalUnderlying_ Total underlying tokens in the contract
     * @param totalSupply Total supply of unbutton tokens
     * @return The equivalent amount of unbutton tokens
     *
     * @custom:formula shares = uAmount * totalSupply / totalUnderlying
     */
    function _fromUnderlyingAmount(
        uint256 uAmount,
        uint256 totalUnderlying_,
        uint256 totalSupply
    ) private pure returns (uint256) {
        return (uAmount * totalSupply) / totalUnderlying_;
    }

    /**
     * @dev Converts unbutton to underlying token amount
     * @param amount Amount of unbutton tokens
     * @param totalUnderlying_ Total underlying tokens in the contract
     * @param totalSupply Total supply of unbutton tokens
     * @return The equivalent amount of underlying tokens
     *
     * @custom:formula underlying = amount * totalUnderlying / totalSupply
     */
    function _toUnderlyingAmount(
        uint256 amount,
        uint256 totalUnderlying_,
        uint256 totalSupply
    ) private pure returns (uint256) {
        return (amount * totalUnderlying_) / totalSupply;
    }
}
