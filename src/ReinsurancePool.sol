// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ReinsurancePool
 * @notice Secondary ERC-4626 vault that absorbs correlated tail losses from BrumaVault.
 *
 * WATERFALL:
 *   Primary vault (BrumaVault) absorbs losses up to its utilization ceiling.
 *   If a correlated event exhausts primary liquidity, CRE guardian draws from here.
 *
 * INCENTIVE DESIGN:
 *   Reinsurers earn a higher base yield (reinsurancePremiumBps on top of vault yield)
 *   funded by a portion of every option premium flowing through the primary vault.
 *   In exchange they accept subordinated loss exposure — they only lose capital
 *   when the primary vault is fully exhausted on a correlated settlement.
 *
 * LOCK-UP:
 *   Reinsurers must lock capital for `lockupPeriod` after deposit.
 *   This prevents withdrawals exactly when the system needs reinsurance most.
 *
 * GUARDIAN:
 *   Only the CRE-authorized guardian (set by owner) can call `fundPrimaryVault()`.
 *   This maps to the Chainlink CRE operator wallet running `onRiskCron`.
 */
contract ReinsurancePool is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable weth;

    /// @notice Address of the primary BrumaVault — recipient of emergency draws
    address public primaryVault;

    /// @notice CRE guardian wallet authorized to trigger draws
    address public guardian;

    /// @notice How long reinsurers must keep capital locked (default: 30 days)
    uint256 public lockupPeriod = 30 days;

    /// @notice Maximum fraction of pool that can be drawn in a single event (bps)
    uint256 public maxSingleDrawBps = 5000; // 50% per event — prevents full drain

    /// @notice Minimum pool utilization reserve — pool will never draw below this (bps)
    uint256 public minReserveBps = 2000; // always keep 20% untouched

    /// @notice Accumulated yield owed to reinsurers (funded by primary vault premiums)
    uint256 public accruedYield;

    /// @notice Total capital ever drawn to primary vault
    uint256 public totalDrawn;

    /// @notice Total yield ever distributed to reinsurers
    uint256 public totalYieldDistributed;

    /// @notice Per-depositor lockup expiry timestamp
    mapping(address => uint256) public lockupExpiry;

    /// @notice Per-depositor deposit amount (for lockup tracking)
    mapping(address => uint256) public depositedAmount;

    /// @notice Draw history for transparency
    struct DrawRecord {
        uint256 amount;
        uint256 timestamp;
        address triggeredBy;
        string reason;
    }

    DrawRecord[] public drawHistory;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event PrimaryVaultUpdated(address indexed oldVault, address indexed newVault);
    event DrawExecuted(uint256 amount, address indexed vault, string reason, uint256 drawIndex);
    event YieldDeposited(uint256 amount);
    event YieldClaimed(address indexed reinsurer, uint256 amount);
    event LockupPeriodUpdated(uint256 newPeriod);
    event DrawLimitsUpdated(uint256 maxSingleDrawBps, uint256 minReserveBps);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnauthorizedGuardian();
    error PrimaryVaultNotSet();
    error DrawExceedsLimit();
    error InsufficientPoolLiquidity();
    error CapitalLocked(uint256 unlocksAt);
    error ZeroAmount();
    error InvalidAddress();
    error InvalidBps();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IERC20 _weth, string memory _name, string memory _symbol)
        ERC4626(_weth)
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        weth = _weth;
    }

    /*//////////////////////////////////////////////////////////////
                          DECIMALS OFFSET
                    (same inflation protection as BrumaVault)
    //////////////////////////////////////////////////////////////*/

    function _decimalsOffset() internal pure virtual override returns (uint8) {
        return 9;
    }

    /*//////////////////////////////////////////////////////////////
                          CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setGuardian(address _guardian) external onlyOwner {
        if (_guardian == address(0)) revert InvalidAddress();
        address old = guardian;
        guardian = _guardian;
        emit GuardianUpdated(old, _guardian);
    }

    function setPrimaryVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert InvalidAddress();
        address old = primaryVault;
        primaryVault = _vault;
        emit PrimaryVaultUpdated(old, _vault);
    }

    function setLockupPeriod(uint256 _period) external onlyOwner {
        lockupPeriod = _period;
        emit LockupPeriodUpdated(_period);
    }

    function setDrawLimits(uint256 _maxSingleDrawBps, uint256 _minReserveBps) external onlyOwner {
        if (_maxSingleDrawBps > 10000 || _minReserveBps > 10000) revert InvalidBps();
        if (_maxSingleDrawBps + _minReserveBps > 10000) revert InvalidBps();
        maxSingleDrawBps = _maxSingleDrawBps;
        minReserveBps = _minReserveBps;
        emit DrawLimitsUpdated(_maxSingleDrawBps, _minReserveBps);
    }

    /*//////////////////////////////////////////////////////////////
                     CORE: GUARDIAN DRAW FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Draw WETH from the reinsurance pool into the primary vault.
     * @dev Called by the CRE guardian (`onRiskCron`) when:
     *   (a) expected loss breaches threshold AND
     *   (b) primary vault utilization is critically high.
     *
     * Enforces:
     *   - Max 50% of pool per draw (prevents full drain)
     *   - Always keeps 20% reserve untouched
     *   - Records draw for transparency
     *
     * @param amount    WETH amount to transfer to primary vault
     * @param reason    Human-readable reason string (logged from CRE)
     */
    function fundPrimaryVault(uint256 amount, string calldata reason)
        external
        nonReentrant
        returns (uint256 actualAmount)
    {
        if (msg.sender != guardian) revert UnauthorizedGuardian();
        if (primaryVault == address(0)) revert PrimaryVaultNotSet();
        if (amount == 0) revert ZeroAmount();

        uint256 poolBalance = weth.balanceOf(address(this));

        // Enforce minimum reserve — pool keeps minReserveBps always
        uint256 minReserve = (poolBalance * minReserveBps) / 10000;
        uint256 maxDrawable = poolBalance > minReserve ? poolBalance - minReserve : 0;

        // Enforce per-draw cap
        uint256 maxSingleDraw = (poolBalance * maxSingleDrawBps) / 10000;
        uint256 cap = maxDrawable < maxSingleDraw ? maxDrawable : maxSingleDraw;

        if (cap == 0) revert InsufficientPoolLiquidity();

        // Draw the lesser of requested amount and cap
        actualAmount = amount > cap ? cap : amount;

        totalDrawn += actualAmount;

        drawHistory.push(
            DrawRecord({amount: actualAmount, timestamp: block.timestamp, triggeredBy: msg.sender, reason: reason})
        );

        // Transfer to primary vault
        weth.safeTransfer(primaryVault, actualAmount);

        emit DrawExecuted(actualAmount, primaryVault, reason, drawHistory.length - 1);
    }

    /*//////////////////////////////////////////////////////////////
                     YIELD: PRIMARY VAULT DEPOSITS PREMIUMS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Primary vault deposits a portion of collected premiums as reinsurer yield.
     * @dev Called by BrumaVault whenever it calls `receivePremium`.
     *      This is the incentive mechanism — reinsurers earn yield proportional
     *      to premiums flowing through the primary system.
     */
    function depositYield() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        accruedYield += msg.value;
        emit YieldDeposited(msg.value);
    }

    /**
     * @notice Reinsurers claim their pro-rata share of accrued yield.
     * @dev Yield is distributed proportional to share holdings.
     *      Does not require lockup to have expired — yield flows continuously.
     */
    function claimYield() external nonReentrant returns (uint256 yieldAmount) {
        uint256 shares = balanceOf(msg.sender);
        if (shares == 0) return 0;

        uint256 totalShares = totalSupply();
        if (totalShares == 0) return 0;

        // Pro-rata yield based on share ownership
        yieldAmount = (accruedYield * shares) / totalShares;
        if (yieldAmount == 0) return 0;

        accruedYield -= yieldAmount;
        totalYieldDistributed += yieldAmount;

        (bool success,) = payable(msg.sender).call{value: yieldAmount}("");
        require(success, "Yield transfer failed");

        emit YieldClaimed(msg.sender, yieldAmount);
    }

    /*//////////////////////////////////////////////////////////////
                     ERC-4626 OVERRIDES: LOCKUP ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Override deposit to record lockup expiry per depositor.
     */
    function deposit(uint256 assets, address receiver) public virtual override nonReentrant returns (uint256) {
        if (assets == 0) revert ZeroAmount();

        // Extend lockup from now (not from previous expiry — each deposit restarts)
        lockupExpiry[receiver] = block.timestamp + lockupPeriod;
        depositedAmount[receiver] += assets;

        return super.deposit(assets, receiver);
    }

    /**
     * @dev Override mint to record lockup expiry per depositor.
     */
    function mint(uint256 shares, address receiver) public virtual override nonReentrant returns (uint256) {
        if (shares == 0) revert ZeroAmount();

        lockupExpiry[receiver] = block.timestamp + lockupPeriod;

        return super.mint(shares, receiver);
    }

    /**
     * @dev Block withdrawals during lockup period.
     */
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        virtual
        override
        nonReentrant
        returns (uint256)
    {
        _checkLockup(owner_);
        return super.withdraw(assets, receiver, owner_);
    }

    /**
     * @dev Block redemptions during lockup period.
     */
    function redeem(uint256 shares, address receiver, address owner_)
        public
        virtual
        override
        nonReentrant
        returns (uint256)
    {
        _checkLockup(owner_);
        return super.redeem(shares, receiver, owner_);
    }

    function _checkLockup(address account) internal view {
        uint256 expiry = lockupExpiry[account];
        if (expiry != 0 && block.timestamp < expiry) {
            revert CapitalLocked(expiry);
        }
    }

    function _update(address from, address to, uint256 amount) internal virtual override {
        super._update(from, to, amount);
        // Propagate lockup to recipient on transfer
        if (from != address(0) && to != address(0)) {
            uint256 fromExpiry = lockupExpiry[from];
            if (fromExpiry > lockupExpiry[to]) {
                lockupExpiry[to] = fromExpiry;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view virtual override returns (uint256) {
        return weth.balanceOf(address(this));
    }

    function availableCapacity() public view returns (uint256) {
        uint256 balance = weth.balanceOf(address(this));
        uint256 reserve = (balance * minReserveBps) / 10000;
        return balance > reserve ? balance - reserve : 0;
    }

    function maxDrawableNow() public view returns (uint256) {
        uint256 balance = weth.balanceOf(address(this));
        uint256 maxSingleDraw = (balance * maxSingleDrawBps) / 10000;
        uint256 available = availableCapacity();
        return maxSingleDraw < available ? maxSingleDraw : available;
    }

    function isLocked(address account) external view returns (bool, uint256) {
        uint256 expiry = lockupExpiry[account];
        bool locked = expiry != 0 && block.timestamp < expiry;
        return (locked, expiry);
    }

    function getDrawHistory() external view returns (DrawRecord[] memory) {
        return drawHistory;
    }

    function getMetrics()
        external
        view
        returns (
            uint256 tvl,
            uint256 available,
            uint256 drawn,
            uint256 pendingYield,
            uint256 yieldDistributed,
            uint256 reinsurers
        )
    {
        tvl = totalAssets();
        available = availableCapacity();
        drawn = totalDrawn;
        pendingYield = accruedYield;
        yieldDistributed = totalYieldDistributed;
        reinsurers = totalSupply(); // proxy: non-zero means reinsurers exist
    }

    receive() external payable {}
}
