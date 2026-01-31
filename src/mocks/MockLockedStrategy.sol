// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStrategyAdapter} from "../MultiStrategy4626Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * Locked strategy:
 * - deposit: 1:1 accounting
 * - withdraw: not allowed (reverts)
 * - requestWithdraw: creates a request that unlocks after lockupSeconds
 * - claimWithdraw: transfers to recipient once unlocked
 */
contract MockLockedStrategy is IStrategyAdapter {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    uint256 public lockupSeconds;

    mapping(address => uint256) public bal;

    struct Request {
        address requester;
        uint256 amount;
        uint256 unlockAt;
        bool claimed;
    }

    uint256 public nextRequestId = 1;
    mapping(uint256 => Request) public requests;

    constructor(IERC20 _usdc, uint256 _lockupSeconds) {
        USDC = _usdc;
        lockupSeconds = _lockupSeconds;
    }

    function asset() external view returns (address) { return address(USDC); }
    function isInstant() external pure returns (bool) { return false; }

    function deposit(uint256 assets) external returns (uint256) {
        USDC.safeTransferFrom(msg.sender, address(this), assets);
        bal[msg.sender] += assets;
        return assets; // receipt
    }

    function withdraw(uint256, address) external pure returns (uint256) {
        revert("locked");
    }

    function requestWithdraw(uint256 assets) external returns (uint256 requestId) {
        require(bal[msg.sender] >= assets, "insufficient");
        bal[msg.sender] -= assets;

        requestId = nextRequestId++;
        requests[requestId] = Request({
            requester: msg.sender,
            amount: assets,
            unlockAt: block.timestamp + lockupSeconds,
            claimed: false
        });
    }

    function claimWithdraw(uint256 requestId, address to) external returns (uint256 assetsClaimed) {
        Request storage r = requests[requestId];
        require(!r.claimed, "claimed");
        require(block.timestamp >= r.unlockAt, "not unlocked");

        r.claimed = true;
        assetsClaimed = r.amount;

        USDC.safeTransfer(to, assetsClaimed);
    }

    function totalAssetsOf(address account) external view returns (uint256) {
        return bal[account];
    }
}
