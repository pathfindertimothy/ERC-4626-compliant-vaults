// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MultiStrategy4626Vault} from "../src/MultiStrategy4626Vault.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployMultiStrategy4626Vault is Script {

    HelperConfig helperConfig;

    function run() external returns (MultiStrategy4626Vault vault) {
        helperConfig = new HelperConfig();
        // --- required env vars ---
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address usdc       = vm.envAddress("USDC_ADDRESS");
        address accountAddr = vm.addr(deployerPk); //# For testing purpose
        console.log("Account address: ", accountAddr);

        // --- role addresses (default to deployer if not provided) ---
        address deployer = vm.addr(deployerPk);

        address admin   = helperConfig._envOr("ADMIN_ADDRESS", deployer);
        address manager = helperConfig._envOr("MANAGER_ADDRESS", deployer);
        address pauser  = helperConfig._envOr("PAUSER_ADDRESS", deployer);

        // --- optional metadata ---
        string memory name_   = helperConfig._envOrString("VAULT_NAME", "Multi Strat USDC Vault");
        string memory symbol_ = helperConfig._envOrString("VAULT_SYMBOL", "msUSDC");

        vm.startBroadcast(deployerPk);

        vault = new MultiStrategy4626Vault(
            IERC20(usdc),
            name_,
            symbol_,
            admin,
            manager,
            pauser
        );

        vm.stopBroadcast();

        console.log("Deployed MultiStrategy4626Vault to:", address(vault));
        console.log("Asset (USDC):", usdc);
        console.log("Admin:", admin);
        console.log("Manager:", manager);
        console.log("Pauser:", pauser);
    }
}