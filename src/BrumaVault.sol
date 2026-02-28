// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBrumaVault} from "./interface/IBrumaVault.sol";

/// @dev Minimal interface so the vault can push a WETH slice to the
///      ReinsurancePool inside receivePremium() without importing the full contract.
interface IReinsurancePool {
    function receiveYield(uint256 amount) external;
}

/**
 * @title BrumaVault
 * @notice ERC-4626 liquidity vault backing Bruma parametric rainfall options.
 *
 * ROLES:
 *   owner          — deploy-time config: weatherOptions, guardian, reinsurancePool,
 *                    reinsuranceYieldBps, maxLocationExposure
 *   guardian       — runtime risk adjustment: setUtilizationLimits, receiveReinsuranceDraw
 *                    (mapped to the CRE onRiskCron wallet so the job is fully autonomous)
 *   weatherOptions — lockCollateral / releaseCollateral / receivePremium
 *
 * REINSURANCE YIELD ROUTING (receivePremium):
 *   When reinsurancePool != address(0) and reinsuranceYieldBps > 0,
 *   receivePremium() forwards `amount * reinsuranceYieldBps / 10000` WETH
 *   to the ReinsurancePool as reinsurer yield. The vault retains the rest.
 *   Defaults to 0 / address(0) — routing is inert until owner activates it.
 *
 * REINSURANCE DRAW ACCOUNTING (receiveReinsuranceDraw):
 *   ReinsurancePool.fundPrimaryVault() transfers WETH here directly.
 *   The guardian then calls receiveReinsuranceDraw() to update
 *   totalReinsuranceReceived and emit ReinsuranceDrawReceived.
 *
 * INFLATION ATTACK PROTECTION:
 *   Virtual shares offset of 10^9 (_decimalsOffset = 9) — first depositor
 *   manipulation requires donating 1000x more than the deposit amount.
 */
contract BrumaVault is IBrumaVault, ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable weth;

    // ── Access control ────────────────────────────────────────────────────────
    address public override weatherOptions;
    address public override guardian;

    // ── Risk parameters ───────────────────────────────────────────────────────
    uint256 public override maxUtilizationBps = 8000; // 80%
    uint256 public override targetUtilizationBps = 6000; // 60%
    uint256 public override maxLocationExposureBps = 2000; // 20%

    // ── Accounting ────────────────────────────────────────────────────────────
    uint256 public override totalLocked;
    uint256 public override totalPremiumsEarned;
    uint256 public override totalPayouts;
    uint256 public override totalReinsuranceReceived;

    // ── Per-location exposure ─────────────────────────────────────────────────
    mapping(bytes32 => uint256) public override locationExposure;

    // ── Reinsurance routing ───────────────────────────────────────────────────
    /// @notice Address of the ReinsurancePool. address(0) disables routing.
    address public override reinsurancePool;

    /// @notice Basis points of each premium forwarded to ReinsurancePool as WETH yield.
    ///         Default 0. Capped at 5000 (50%) by setReinsuranceYieldBps.
    uint256 public override reinsuranceYieldBps;

    // ── Inflation protection constant ─────────────────────────────────────────
    uint256 private constant _OFFSET = 9;

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

    function _decimalsOffset() internal pure virtual override returns (uint8) {
        return uint8(_OFFSET);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNER CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setWeatherOptions(address _wo) external override onlyOwner {
        if (_wo == address(0)) revert InvalidAddress();
        weatherOptions = _wo;
    }

    function setGuardian(address _guardian) external override onlyOwner {
        if (_guardian == address(0)) revert InvalidAddress();
        address old = guardian;
        guardian = _guardian;
        emit GuardianUpdated(old, _guardian);
    }

    /// @notice Set or clear the ReinsurancePool. address(0) disables yield routing.
    function setReinsurancePool(address _pool) external override onlyOwner {
        address old = reinsurancePool;
        reinsurancePool = _pool;
        emit ReinsurancePoolUpdated(old, _pool);
    }

    /**
     * @notice Set the fraction of each premium routed to ReinsurancePool.
     * @param _bps Basis points. 0 = off. Max 5000 (50% of premium).
     */
    function setReinsuranceYieldBps(uint256 _bps) external override onlyOwner {
        if (_bps > 5000) revert InvalidLimits();
        uint256 old = reinsuranceYieldBps;
        reinsuranceYieldBps = _bps;
        emit ReinsuranceYieldBpsUpdated(old, _bps);
    }

    function setMaxLocationExposure(uint256 _maxBps) external override onlyOwner {
        if (_maxBps > 10000) revert InvalidLimits();
        maxLocationExposureBps = _maxBps;
    }

    /*//////////////////////////////////////////////////////////////
                        GUARDIAN OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Tighten or relax utilization limits in response to CRE risk signals.
     * @dev Guardian-only so the CRE job can act autonomously without owner sign-off.
     */
    function setUtilizationLimits(uint256 _newMaxBps, uint256 _newTargetBps) external override onlyGuardian {
        if (_newMaxBps > 10000 || _newTargetBps > _newMaxBps) revert InvalidLimits();
        maxUtilizationBps = _newMaxBps;
        targetUtilizationBps = _newTargetBps;
        emit UtilizationLimitsUpdated(_newMaxBps, _newTargetBps);
    }

    /**
     * @notice Record WETH that arrived from a ReinsurancePool draw.
     * @dev WETH is transferred to this contract by ReinsurancePool.fundPrimaryVault()
     *      before this call. This function only updates accounting + emits an event.
     *      Guardian calls this immediately after triggering the draw.
     */
    function receiveReinsuranceDraw(uint256 _amount) external override onlyGuardian {
        if (_amount == 0) revert ZeroAmount();
        totalReinsuranceReceived += _amount;
        emit ReinsuranceDrawReceived(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                    WEATHER OPTIONS OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function lockCollateral(uint256 _amount, uint256 _optionId, bytes32 _locationKey)
        external
        override
        onlyWeatherOptions
        returns (bool)
    {
        if (_amount == 0) revert ZeroAmount();

        uint256 assets = totalAssets();
        if (assets == 0) revert InsufficientLiquidity();

        uint256 available = assets > totalLocked ? assets - totalLocked : 0;
        if (_amount > available) revert InsufficientLiquidity();

        uint256 newUtil = ((totalLocked + _amount) * 10000) / assets;
        if (newUtil > maxUtilizationBps) revert UtilizationTooHigh();

        uint256 newLocationExp = locationExposure[_locationKey] + _amount;
        if ((newLocationExp * 10000) / assets > maxLocationExposureBps) {
            revert LocationExposureTooHigh();
        }

        totalLocked += _amount;
        locationExposure[_locationKey] += _amount;

        emit CollateralLocked(_optionId, _amount, _locationKey);
        emit LocationExposureUpdated(_locationKey, newLocationExp);

        return true;
    }

    function releaseCollateral(uint256 _amount, uint256 _payout, uint256 _optionId, bytes32 _locationKey)
        external
        override
        onlyWeatherOptions
    {
        require(_amount >= _payout, "Invalid amounts");
        require(totalLocked >= _amount, "Invalid locked amount");
        require(locationExposure[_locationKey] >= _amount, "Invalid location exposure");

        totalLocked -= _amount;
        totalPayouts += _payout;
        locationExposure[_locationKey] -= _amount;

        if (_payout > 0) {
            weth.safeTransfer(msg.sender, _payout);
        }

        emit CollateralReleased(_optionId, _amount, _payout, _locationKey);
        emit LocationExposureUpdated(_locationKey, locationExposure[_locationKey]);
    }

    /**
     * @notice Receive premium WETH from Bruma and route reinsurance yield slice.
     *
     * ROUTING:
     *   yieldSlice  = _amount * reinsuranceYieldBps / 10000  → weth.safeTransfer to pool
     *   vaultShare  = _amount - yieldSlice                   → stays here as LP yield
     *
     * WETH has already been transferred to this contract by Bruma._handlePayments()
     * before this call. No token pull happens here — only a push to the pool.
     *
     * INACTIVE STATE (default):
     *   reinsurancePool == address(0) OR reinsuranceYieldBps == 0
     *   → yieldSlice = 0, full amount books to totalPremiumsEarned.
     *   Identical to pre-reinsurance behavior.
     */
    function receivePremium(uint256 _amount, uint256 _optionId) external override onlyWeatherOptions {
        if (_amount == 0) revert ZeroAmount();

        uint256 yieldSlice;
        address pool = reinsurancePool;

        if (pool != address(0) && reinsuranceYieldBps > 0) {
            yieldSlice = (_amount * reinsuranceYieldBps) / 10000;
            if (yieldSlice > 0) {
                weth.safeTransfer(pool, yieldSlice);
                emit ReinsuranceYieldRouted(_optionId, yieldSlice);
            }
        }

        totalPremiumsEarned += _amount - yieldSlice;
        emit PremiumReceived(_optionId, _amount - yieldSlice);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view virtual override returns (uint256) {
        return weth.balanceOf(address(this));
    }

    function availableLiquidity() public view override returns (uint256) {
        uint256 assets = totalAssets();
        if (totalLocked >= assets) return 0;

        uint256 available = assets - totalLocked;
        uint256 maxLockable = (assets * maxUtilizationBps) / 10000;

        if (totalLocked + available > maxLockable) {
            return maxLockable > totalLocked ? maxLockable - totalLocked : 0;
        }
        return available;
    }

    function utilizationRate() public view override returns (uint256) {
        uint256 assets = totalAssets();
        if (assets == 0) return 0;
        return (totalLocked * 10000) / assets;
    }

    function canUnderwrite(uint256 _amount, bytes32 _locationKey) external view override returns (bool) {
        if (_amount > availableLiquidity()) return false;

        uint256 assets = totalAssets();
        if (assets == 0) return false;

        if (((totalLocked + _amount) * 10000) / assets > maxUtilizationBps) return false;

        if ((locationExposure[_locationKey] + _amount) * 10000 / assets > maxLocationExposureBps) {
            return false;
        }

        return true;
    }

    function getPremiumMultiplier() public view override returns (uint256) {
        uint256 util = utilizationRate();
        if (util <= targetUtilizationBps) {
            return 10000;
        } else if (util <= maxUtilizationBps) {
            uint256 excess = util - targetUtilizationBps;
            uint256 range = maxUtilizationBps - targetUtilizationBps;
            return 10000 + (excess * 10000) / range;
        } else {
            return 25000; // hard cap multiplier above max utilization
        }
    }

    /// @inheritdoc IBrumaVault
    function getMetrics() external view override returns (VaultMetrics memory) {
        uint256 premiums = totalPremiumsEarned;
        uint256 payouts = totalPayouts;
        return VaultMetrics({
            tvl: totalAssets(),
            locked: totalLocked,
            available: availableLiquidity(),
            utilizationBps: utilizationRate(),
            premiumsEarned: premiums,
            totalPayouts: payouts,
            netPnL: int256(premiums) - int256(payouts),
            reinsuranceReceived: totalReinsuranceReceived
        });
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function maxWithdraw(address _owner) public view virtual override returns (uint256) {
        uint256 shares = balanceOf(_owner);
        uint256 totalShares = totalSupply();
        if (shares == 0 || totalShares == 0) return 0;

        uint256 assets = totalAssets();
        uint256 available = assets > totalLocked ? assets - totalLocked : 0;
        return (available * shares) / totalShares;
    }

    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        return convertToShares(maxWithdraw(_owner));
    }

    function deposit(uint256 _assets, address _receiver) public virtual override returns (uint256) {
        if (_assets == 0) revert ZeroAmount();
        return super.deposit(_assets, _receiver);
    }

    function mint(uint256 _shares, address _receiver) public virtual override returns (uint256) {
        if (_shares == 0) revert ZeroAmount();
        return super.mint(_shares, _receiver);
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyWeatherOptions() {
        if (msg.sender != weatherOptions) revert UnauthorizedCaller();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert UnauthorizedGuardian();
        _;
    }
}
