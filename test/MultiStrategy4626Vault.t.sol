// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm, console} from "forge-std/Test.sol";

import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockInstant4626Strategy} from "../src/mocks/MockInstant4626Strategy.sol";
import {MockLockedStrategy} from "../src/mocks/MockLockedStrategy.sol";
import {MultiStrategy4626Vault} from "../src/MultiStrategy4626Vault.sol";
// import {console} from "forge-std/Script.sol";

contract MultiStrategy4626Vault_HighSignal_Test is Test {
    MockUSDC usdc;
    MockInstant4626Strategy stratA; // instant (Protocol A)
    MockLockedStrategy stratB;      // locked  (Protocol B)
    MultiStrategy4626Vault vault;

    address admin   = address(0xA11CE);
    address manager = address(0xB0B);
    address pauser  = address(0xCAFE);
    address user    = address(0xD00D);

    function setUp() public {
        usdc = new MockUSDC();
        stratA = new MockInstant4626Strategy(usdc);
        stratB = new MockLockedStrategy(usdc, 7 days);

        vault = new MultiStrategy4626Vault(
            usdc,
            "Multi Strat USDC Vault",
            "msUSDC",
            admin,
            manager,
            pauser
        );

        vm.startPrank(admin);
        // Allow 100% caps so 60/40 is possible in the "happy path" test.
        vault.addStrategy(stratA, 10_000);
        vault.addStrategy(stratB, 10_000);
        vm.stopPrank();

        usdc.mint(user, 2_000e6);
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// High-signal: allocation caps should prevent concentration risk
    function test_AllocationCapsPreventConcentration() public {
        vm.startPrank(admin);
        // Fresh vault with 50% caps on both -> 60/40 should revert
        MultiStrategy4626Vault capped = new MultiStrategy4626Vault(
            usdc,
            "Capped Vault",
            "cUSDC",
            admin,
            manager,
            pauser
        );
        capped.addStrategy(stratA, 5000);
        capped.addStrategy(stratB, 5000);
        vm.stopPrank();

        vm.prank(manager);
        uint16[] memory bad = new uint16[](2);
        bad[0] = 6000;
        bad[1] = 4000;

        vm.expectRevert(MultiStrategy4626Vault.AllocationCapExceeded.selector);
        // console.log('----------------');
        // emit log_uint(vault.strategyCount()); // if you have it
        
        capped.setAllocations(bad);
        console.log('--------Time Below 1--------');
        console.log(block.timestamp);
        console.log('--------Time Below 2--------');
        console.log(block.number);
        console.log('--------Time Above--------');
    }

    /// High-signal: value aggregation + lockup withdrawal queue behavior
    function test_Deposit_60_40_Yield_Withdraw_WithLockupQueue() public {
        // 1) User deposits 1000 USDC
        vm.prank(user);
        uint256 shares = vault.deposit(1_000e6, user);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(user), shares);

        // 2) Manager sets 60/40 allocation to Protocol A / Protocol B
        vm.prank(manager);
        uint16[] memory alloc = new uint16[](2);
        alloc[0] = 6000; // A
        alloc[1] = 4000; // B
        vault.setAllocations(alloc);

        // push idle into strategies
        vm.prank(manager);
        vault.rebalance();

        // checkpoint: strategy holdings match 60/40 of 1000
        uint256 aValueBefore = stratA.totalAssetsOf(address(vault));
        uint256 bValueBefore = stratB.totalAssetsOf(address(vault));
        assertApproxEqAbs(aValueBefore, 600e6, 2);
        assertApproxEqAbs(bValueBefore, 400e6, 2);

        // 3) Protocol A increases in value by 10%
        stratA.setExchangeRate(1.1e18);

        // 4) User's shares are now worth ~1060 USDC
        // aggregate value = 660 (A) + 400 (B) = 1060
        uint256 total = vault.totalAssets();
        assertApproxEqAbs(total, 1_060e6, 2);

        uint256 assetsForUserShares = vault.previewRedeem(vault.balanceOf(user));
        assertApproxEqAbs(assetsForUserShares, 1_060e6, 2);

        // 5) User withdraws (handle lockup on Protocol B)
        // Expect: instant paid now (~660), locked queued (~400)
        uint256 balBefore = usdc.balanceOf(user);

        vm.recordLogs();
        vm.prank(user);
        vault.withdraw(assetsForUserShares, user, user);

        uint256 balAfter = usdc.balanceOf(user);
        uint256 receivedNow = balAfter - balBefore;
        assertApproxEqAbs(receivedNow, 660e6, 2);

        // pending should reflect locked portion ~400
        // NOTE: pending is a public mapping to a struct, so the getter returns a tuple.
        (uint256 pendingAssets) = vault.pending(user);
        assertApproxEqAbs(pendingAssets, 400e6, 2);

        // Extract requestId + strategy from WithdrawalQueued event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("WithdrawalQueued(address,uint256,uint256,address)");

        uint256 requestId;
        address strategyAddr;
        bool found;

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 0) continue;
            if (entries[i].topics[0] != sig) continue;

            address indexedUser = address(uint160(uint256(entries[i].topics[1])));
            if (indexedUser != user) continue;

            (uint256 assetsQueued, uint256 rid, address strat) =
                abi.decode(entries[i].data, (uint256, uint256, address));

            assertApproxEqAbs(assetsQueued, 400e6, 2);
            requestId = rid;
            strategyAddr = strat;
            found = true;
            break;
        }
        assertTrue(found, "WithdrawalQueued not found");
        assertEq(strategyAddr, address(stratB));

        // Before unlock, claim should revert (MockLockedStrategy uses "not unlocked")
        vm.expectRevert(bytes("not unlocked"));
        vault.claim(requestId, strategyAddr);

        // Warp beyond lockup and claim
        vm.warp(block.timestamp + 7 days + 1);

        uint256 balBeforeClaim = usdc.balanceOf(user);
        vault.claim(requestId, strategyAddr);
        uint256 balAfterClaim = usdc.balanceOf(user);

        uint256 claimed = balAfterClaim - balBeforeClaim;
        assertApproxEqAbs(claimed, 400e6, 2);

        // pending should be 0 after claim
        (uint256 pendingAfter) = vault.pending(user);
        assertEq(pendingAfter, 0);
    }
}
