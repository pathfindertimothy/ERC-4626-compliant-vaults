// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStrategyAdapter} from "../MultiStrategy4626Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockUSDC} from "./MockUSDC.sol";

/**
 * Instant liquidity strategy with a mutable "exchange rate" to simulate yield.
 * totalAssetsOf(vault) = shares[vault] * exchangeRate / 1e18
 */
contract MockInstant4626Strategy is IStrategyAdapter {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;

    uint256 public exchangeRate = 1e18; // assets per share, scaled 1e18

    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;

    constructor(IERC20 _usdc) {
        USDC = _usdc;
    }

    function asset() external view returns (address) { return address(USDC); }
    function isInstant() external pure returns (bool) { return true; }

    // function setExchangeRate(uint256 newRate) external {
    //     exchangeRate = newRate;
    // }
    function setExchangeRate(uint256 newRate) external {
        // If rate increases, the strategy's reported assets increase.
        // To keep the mock solvent, mint the difference to this strategy.
        if (newRate > exchangeRate && totalShares > 0) {
            uint256 oldAssets = (totalShares * exchangeRate) / 1e18;
            uint256 newAssets = (totalShares * newRate) / 1e18;

            uint256 delta = newAssets - oldAssets;
            if (delta > 0) {
                // MockUSDC has mint(); we can call it by casting
                // (this is a test/mock-only behavior)
                MockUSDC(address(USDC)).mint(address(this), delta);
            }
        }

        exchangeRate = newRate;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        USDC.safeTransferFrom(msg.sender, address(this), assets);

        // shares = assets / rate
        shares = (assets * 1e18) / exchangeRate;

        sharesOf[msg.sender] += shares;
        totalShares += shares;
        return shares;
    }

    function withdraw(uint256 assets, address to) external returns (uint256 assetsWithdrawn) {
        // sharesNeeded = ceil(assets / rate)
        uint256 sharesNeeded = (assets * 1e18 + exchangeRate - 1) / exchangeRate;
        require(sharesOf[msg.sender] >= sharesNeeded, "insufficient shares");

        sharesOf[msg.sender] -= sharesNeeded;
        totalShares -= sharesNeeded;

        assetsWithdrawn = assets;
        USDC.safeTransfer(to, assetsWithdrawn);
    }

    function requestWithdraw(uint256) external pure returns (uint256) {
        revert("instant strategy");
    }

    function claimWithdraw(uint256, address) external pure returns (uint256) {
        revert("instant strategy");
    }

    function totalAssetsOf(address account) external view returns (uint256) {
        return (sharesOf[account] * exchangeRate) / 1e18;
    }
}
