// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * Strategy interface for:
 * - deposit routing
 * - instant withdrawals OR locked withdrawals (request + claim)
 * - reporting current value attributable to the vault
 */
interface IStrategyAdapter {
    function asset() external view returns (address);

    function deposit(uint256 assets) external returns (uint256 sharesOrReceipt);

    function withdraw(uint256 assets, address to) external returns (uint256 assetsWithdrawn);

    function requestWithdraw(uint256 assets) external returns (uint256 requestId);

    function claimWithdraw(uint256 requestId, address to) external returns (uint256 assetsClaimed);

    function totalAssetsOf(address account) external view returns (uint256);

    function isInstant() external view returns (bool);
}

contract MultiStrategy4626Vault is ERC4626, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE  = keccak256("PAUSER_ROLE");

    uint256 public constant BPS = 10_000;

    struct StrategyConfig {
        IStrategyAdapter strat;
        uint16 targetBps;     // target allocation
        uint16 maxBps;        // cap (e.g., 5000 = 50%)
        bool enabled;
    }

    StrategyConfig[] public strategies;

    struct PendingWithdrawal {
        uint256 assetsPending;
    }

    mapping(address => PendingWithdrawal) public pending;

    mapping(uint256 => address) public requestOwner;

    event StrategiesUpdated();
    event Rebalanced(uint256 totalDepositedToStrats, uint256 totalWithdrawnToIdle);
    event WithdrawalQueued(address indexed user, uint256 assetsQueued, uint256 requestId, address strategy);
    event PendingClaimed(address indexed user, uint256 assetsClaimed, uint256 requestId, address strategy);

    error InvalidStrategyAsset();
    error AllocationSumNot100();
    error AllocationCapExceeded();
    error NoStrategies();
    error InsufficientLiquidity();
    error LengthMismatch();
    error UnknownRequest();

    constructor(
        IERC20 usdc,
        string memory name_,
        string memory symbol_,
        address admin,
        address manager,
        address pauser
    )
        ERC20(name_, symbol_)
        ERC4626(usdc)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MANAGER_ROLE, manager);
        _grantRole(PAUSER_ROLE, pauser);
    }

    // -------------------------
    // Admin / Manager controls
    // -------------------------

    function addStrategy(
        IStrategyAdapter strat,
        uint16 maxBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (strat.asset() != address(asset())) revert InvalidStrategyAsset();
        strategies.push(StrategyConfig({
            strat: strat,
            targetBps: 0,
            maxBps: maxBps,
            enabled: true
        }));
        emit StrategiesUpdated();
    }

    function setStrategyEnabled(uint256 idx, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        strategies[idx].enabled = enabled;
        emit StrategiesUpdated();
    }

    /**
     * Set target allocations across enabled strategies.
     * Must sum to 10000 and each <= maxBps.
     */
    function setAllocations(uint16[] calldata targetBps) external onlyRole(MANAGER_ROLE) {
        if (strategies.length == 0) revert NoStrategies();
        if(targetBps.length != strategies.length) revert LengthMismatch();

        uint256 sum;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (!strategies[i].enabled) {
                strategies[i].targetBps = 0;
                continue;
            }
            uint16 bps = targetBps[i];
            if (bps > strategies[i].maxBps) revert AllocationCapExceeded();
            strategies[i].targetBps = bps;
            sum += bps;
        }
        if (sum != BPS) revert AllocationSumNot100();
        emit StrategiesUpdated();
    }

    /**
     * Rebalance idle assets into strategies to match targets.
     * (Push-only for simplicity; extend to pull from overweight strategies if needed.)
     */
    function rebalance() external onlyRole(MANAGER_ROLE) whenNotPaused {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle == 0) {
            emit Rebalanced(0, 0);
            return;
        }

        uint256 deposited;
        for (uint256 i = 0; i < strategies.length; i++) {
            StrategyConfig memory cfg = strategies[i];
            if (!cfg.enabled || cfg.targetBps == 0) continue;

            uint256 toDeposit = (idle * cfg.targetBps) / BPS;
            if (toDeposit == 0) continue;

            IERC20(asset()).safeIncreaseAllowance(address(cfg.strat), toDeposit);
            cfg.strat.deposit(toDeposit);
            deposited += toDeposit;
        }

        emit Rebalanced(deposited, 0);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // -------------------------
    // ERC-4626 core accounting
    // -------------------------

    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        for (uint256 i = 0; i < strategies.length; i++) {
            if (!strategies[i].enabled) continue;
            total += strategies[i].strat.totalAssetsOf(address(this));
        }
        return total;
    }

    // -------------------------
    // Deposit / Mint overrides
    // -------------------------

    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    // -------------------------
    // Withdraw / Redeem with queue
    // -------------------------

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256 sharesBurned)
    {
        sharesBurned = previewWithdraw(assets);
        _withdrawWithQueue(assets, receiver, owner, sharesBurned);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256 assetsOut)
    {
        assetsOut = previewRedeem(shares);
        _withdrawWithQueue(assetsOut, receiver, owner, shares);
    }

    function _withdrawWithQueue(
        uint256 assets,
        address receiver,
        address owner,
        uint256 shares
    ) internal {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Burn shares up-front so accounting stays correct even if part is queued
        _burn(owner, shares);

        uint256 remaining = assets;

        // 1) Use idle balance
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle > 0) {
            uint256 pay = idle >= remaining ? remaining : idle;
            IERC20(asset()).safeTransfer(receiver, pay);
            remaining -= pay;
        }
        if (remaining == 0) return;

        // 2) Try instant strategies (only up to what each can provide)
        for (uint256 i = 0; i < strategies.length && remaining > 0; i++) {
            StrategyConfig memory cfg = strategies[i];
            if (!cfg.enabled) continue;
            if (!cfg.strat.isInstant()) continue;

            // How much this strategy can return for the vault right now (in assets)
            uint256 availableValue = cfg.strat.totalAssetsOf(address(this));
            if (availableValue == 0) continue;

            uint256 toPull = availableValue >= remaining ? remaining : availableValue;

            // Pull to the vault, then pay receiver from the vault
            uint256 got = cfg.strat.withdraw(toPull, address(this));
            if (got > toPull) got = toPull;

            IERC20(asset()).safeTransfer(receiver, got);
            remaining -= got;
        }
        if (remaining == 0) return;


        // 3) Queue from locked strategies
        for (uint256 i = 0; i < strategies.length && remaining > 0; i++) {
            StrategyConfig memory cfg = strategies[i];
            if (!cfg.enabled) continue;
            if (cfg.strat.isInstant()) continue;

            uint256 availableValue = cfg.strat.totalAssetsOf(address(this));
            if (availableValue == 0) continue;

            uint256 toRequest = availableValue >= remaining ? remaining : availableValue;

            uint256 requestId = cfg.strat.requestWithdraw(toRequest);
            requestOwner[requestId] = owner;

            pending[owner].assetsPending += toRequest;
            emit WithdrawalQueued(owner, toRequest, requestId, address(cfg.strat));

            remaining -= toRequest;
        }

        if (remaining != 0) revert InsufficientLiquidity();
    }

    function claim(uint256 requestId, address strategyAddr)
        external
        whenNotPaused
        returns (uint256 assetsClaimed)
    {
        address owner = requestOwner[requestId];
        if(owner == address(0)) revert UnknownRequest();

        assetsClaimed = IStrategyAdapter(strategyAddr).claimWithdraw(requestId, owner);

        PendingWithdrawal storage p = pending[owner];
        if (assetsClaimed >= p.assetsPending) {
            p.assetsPending = 0;
        } else {
            p.assetsPending -= assetsClaimed;
        }

        emit PendingClaimed(owner, assetsClaimed, requestId, strategyAddr);
        delete requestOwner[requestId];
    }

    function strategyCount() external view returns (uint256) {
        return strategies.length;
    }
}
