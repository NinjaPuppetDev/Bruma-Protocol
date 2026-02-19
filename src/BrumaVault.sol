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
 * @title WeatherOptionsVault - FIXED VERSION
 * @notice ERC-4626 vault with proper inflation attack protection
 *
 * FIX: Uses virtual shares/assets offset (modern OpenZeppelin approach)
 * Instead of minting dead shares, we add a virtual offset to all conversions
 */
contract BrumaVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable weth;
    address public weatherOptions;

    // Risk parameters
    uint256 public maxUtilizationBps = 8000; // 80% max utilization
    uint256 public targetUtilizationBps = 6000; // 60% target utilization

    // Collateral tracking
    uint256 public totalLocked;
    uint256 public totalPremiumsEarned;
    uint256 public totalPayouts;

    // Per-location risk limits
    mapping(bytes32 => uint256) public locationExposure;
    uint256 public maxLocationExposureBps = 2000; // 20% per location

    address public yieldStrategy;

    // Virtual offset prevents first depositor manipulation
    uint256 private constant _DECIMALS_OFFSET = 9; // 1000x offset

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event PremiumReceived(uint256 amount, uint256 optionId);
    event PayoutMade(uint256 amount, uint256 optionId);
    event CollateralLocked(uint256 amount, uint256 optionId);
    event CollateralReleased(uint256 amount, uint256 optionId);
    event UtilizationUpdated(uint256 newMaxBps, uint256 newTargetBps);
    event YieldStrategyUpdated(address newStrategy);
    event LocationExposureUpdated(bytes32 locationKey, uint256 exposure);

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnauthorizedCaller();
    error UtilizationTooHigh();
    error InsufficientLiquidity();
    error LocationExposureTooHigh();
    error InvalidParameters();
    error ZeroAmount();

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
                 INFLATION ATTACK PROTECTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Override decimals offset for inflation protection
     * Returns the number of decimals used to get user representation of shares.
     *
     * This adds a virtual offset to share/asset conversions:
     * - If offset = 3, first deposit of 1 wei gets 1000 shares
     * - Attacker would need to donate 1000 wei to make victim's deposit round to 0
     * - Much more expensive attack (vs 1 wei in vulnerable version)
     */
    function _decimalsOffset() internal pure virtual override returns (uint8) {
        return uint8(_DECIMALS_OFFSET);
    }

    /*//////////////////////////////////////////////////////////////
                    VAULT CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setWeatherOptions(address _weatherOptions) external onlyOwner {
        require(_weatherOptions != address(0), "Invalid address");
        weatherOptions = _weatherOptions;
    }

    function setUtilizationLimits(uint256 _maxBps, uint256 _targetBps) external onlyOwner {
        require(_maxBps <= 10000 && _targetBps <= _maxBps, "Invalid limits");
        maxUtilizationBps = _maxBps;
        targetUtilizationBps = _targetBps;
        emit UtilizationUpdated(_maxBps, _targetBps);
    }

    function setMaxLocationExposure(uint256 _maxBps) external onlyOwner {
        require(_maxBps <= 10000, "Invalid percentage");
        maxLocationExposureBps = _maxBps;
    }

    function setYieldStrategy(address _strategy) external onlyOwner {
        yieldStrategy = _strategy;
        emit YieldStrategyUpdated(_strategy);
    }

    /*//////////////////////////////////////////////////////////////
                    VAULT OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function lockCollateral(uint256 amount, uint256 optionId, bytes32 locationKey)
        external
        onlyWeatherOptions
        returns (bool success)
    {
        if (amount == 0) revert ZeroAmount();

        // Check utilization limits
        uint256 assets = totalAssets();
        if (assets == 0) revert InsufficientLiquidity();

        uint256 available = assets > totalLocked ? assets - totalLocked : 0;
        if (amount > available) revert InsufficientLiquidity();

        uint256 newUtilization = ((totalLocked + amount) * 10000) / assets;
        if (newUtilization > maxUtilizationBps) revert UtilizationTooHigh();

        // Check location exposure limits
        uint256 newLocationExposure = locationExposure[locationKey] + amount;
        uint256 locationExposurePct = (newLocationExposure * 10000) / assets;
        if (locationExposurePct > maxLocationExposureBps) {
            revert LocationExposureTooHigh();
        }

        // Update state
        totalLocked += amount;
        locationExposure[locationKey] += amount;

        emit CollateralLocked(amount, optionId);
        emit LocationExposureUpdated(locationKey, newLocationExposure);

        return true;
    }

    function releaseCollateral(uint256 amount, uint256 payout, uint256 optionId, bytes32 locationKey)
        external
        onlyWeatherOptions
    {
        require(amount >= payout, "Invalid amounts");
        require(totalLocked >= amount, "Invalid locked amount");
        require(locationExposure[locationKey] >= amount, "Invalid location exposure");

        // Update tracking
        totalLocked -= amount;
        totalPayouts += payout;
        locationExposure[locationKey] -= amount;

        // Transfer WETH payout to WeatherOptions contract
        if (payout > 0) {
            weth.safeTransfer(msg.sender, payout);
        }

        emit CollateralReleased(amount, optionId);
        emit PayoutMade(payout, optionId);
        emit LocationExposureUpdated(locationKey, locationExposure[locationKey]);
    }

    function receivePremium(uint256 amount, uint256 optionId) external onlyWeatherOptions {
        totalPremiumsEarned += amount;
        emit PremiumReceived(amount, optionId);
    }

    /*//////////////////////////////////////////////////////////////
                    VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function availableLiquidity() public view returns (uint256) {
        uint256 assets = totalAssets();
        if (totalLocked >= assets) return 0;

        uint256 available = assets - totalLocked;
        uint256 maxLockable = (assets * maxUtilizationBps) / 10000;

        if (totalLocked + available > maxLockable) {
            return maxLockable > totalLocked ? maxLockable - totalLocked : 0;
        }

        return available;
    }

    function utilizationRate() public view returns (uint256) {
        uint256 assets = totalAssets();
        if (assets == 0) return 0;
        return (totalLocked * 10000) / assets;
    }

    function canUnderwrite(uint256 amount, bytes32 locationKey) external view returns (bool) {
        if (amount > availableLiquidity()) return false;

        uint256 assets = totalAssets();
        if (assets == 0) return false;

        uint256 newUtil = ((totalLocked + amount) * 10000) / assets;
        if (newUtil > maxUtilizationBps) return false;

        uint256 newLocationExp = (locationExposure[locationKey] + amount) * 10000 / assets;
        if (newLocationExp > maxLocationExposureBps) return false;

        return true;
    }

    function getMetrics()
        external
        view
        returns (
            uint256 tvl,
            uint256 locked,
            uint256 available,
            uint256 utilization,
            uint256 premiums,
            uint256 payouts,
            int256 netPnL
        )
    {
        tvl = totalAssets();
        locked = totalLocked;
        available = availableLiquidity();
        utilization = utilizationRate();
        premiums = totalPremiumsEarned;
        payouts = totalPayouts;
        netPnL = int256(premiums) - int256(payouts);
    }

    function getPremiumMultiplier() public view returns (uint256 multiplierBps) {
        uint256 util = utilizationRate();

        if (util <= targetUtilizationBps) {
            return 10000;
        } else if (util <= maxUtilizationBps) {
            uint256 excessUtil = util - targetUtilizationBps;
            uint256 utilRange = maxUtilizationBps - targetUtilizationBps;
            return 10000 + (excessUtil * 10000) / utilRange;
        } else {
            return 25000;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    ERC-4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view virtual override returns (uint256) {
        return weth.balanceOf(address(this));
    }

    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        uint256 shares = balanceOf(owner);
        uint256 totalShares = totalSupply();

        if (shares == 0 || totalShares == 0) return 0;

        uint256 totalAssets_ = totalAssets();
        uint256 available = totalAssets_ > totalLocked ? totalAssets_ - totalLocked : 0;

        // User can withdraw their proportional share of available liquidity
        return (available * shares) / totalShares;
    }

    function maxRedeem(address owner) public view virtual override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        return convertToShares(maxAssets);
    }

    /**
     * @dev Override to add zero-amount checks
     */
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        if (assets == 0) revert ZeroAmount();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        if (shares == 0) revert ZeroAmount();
        return super.mint(shares, receiver);
    }

    /*//////////////////////////////////////////////////////////////
                    MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyWeatherOptions() {
        if (msg.sender != weatherOptions) revert UnauthorizedCaller();
        _;
    }
}
