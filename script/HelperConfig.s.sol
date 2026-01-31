// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";


contract HelperConfig is Script {

    // constructor() {}

    function _envOr(string memory key, address fallbackValue) public view returns (address) {
        // vm.envAddress reverts if missing; use try/catch to provide fallback
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return fallbackValue;
        }
    }

    function _envOrString(string memory key, string memory fallbackValue)
        public view
        returns (string memory)
    {
        try vm.envString(key) returns (string memory v) {
            return v;
        } catch {
            return fallbackValue;
        }
    }

}