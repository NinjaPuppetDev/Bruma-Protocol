// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

/**
 * @title DiagnoseDeployment
 * @notice Check what's actually deployed at your contract addresses
 */
contract DiagnoseDeployment is Script {
    address constant WEATHER_OPTION = 0x88f72754fF39d05Ed7e84E8cd55e37b466D67Ab1;
    address constant VAULT = 0x86b8eb9811a0eFa71c43684F6666FDb652Bcc0F9;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    function run() external view {
        console.log("=== Deployment Diagnostics ===\n");

        _checkWeatherOption();
        console.log("");
        _checkVault();
        console.log("");
        _checkConnections();
    }

    function _checkWeatherOption() internal view {
        console.log("WeatherOptionV3 at:", WEATHER_OPTION);
        console.log("----------------------------------------");

        // Check if contract has code
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(WEATHER_OPTION)
        }
        console.log("Code size:", codeSize, "bytes");

        if (codeSize == 0) {
            console.log("ERROR: No code at this address!");
            return;
        }

        // Try calling various functions
        (bool success, bytes memory data) = WEATHER_OPTION.staticcall(
            abi.encodeWithSignature("owner()")
        );
        if (success) {
            address owner = abi.decode(data, (address));
            console.log("owner():", owner);
        } else {
            console.log("owner(): FAILED");
        }

        (success, data) = WEATHER_OPTION.staticcall(
            abi.encodeWithSignature("vault()")
        );
        if (success) {
            address vault = abi.decode(data, (address));
            console.log("vault():", vault);
        } else {
            console.log("vault(): FAILED - This is the problem!");
        }

        (success, data) = WEATHER_OPTION.staticcall(
            abi.encodeWithSignature("weth()")
        );
        if (success) {
            address weth = abi.decode(data, (address));
            console.log("weth():", weth);
        } else {
            console.log("weth(): FAILED");
        }

        (success, data) = WEATHER_OPTION.staticcall(
            abi.encodeWithSignature("rainfallCoordinator()")
        );
        if (success) {
            address coord = abi.decode(data, (address));
            console.log("rainfallCoordinator():", coord);
        } else {
            console.log("rainfallCoordinator(): FAILED");
        }

        (success, data) = WEATHER_OPTION.staticcall(
            abi.encodeWithSignature("premiumCoordinator()")
        );
        if (success) {
            address coord = abi.decode(data, (address));
            console.log("premiumCoordinator():", coord);
        } else {
            console.log("premiumCoordinator(): FAILED");
        }

        (success, data) = WEATHER_OPTION.staticcall(
            abi.encodeWithSignature("protocolFeeBps()")
        );
        if (success) {
            uint256 fee = abi.decode(data, (uint256));
            console.log("protocolFeeBps():", fee);
        } else {
            console.log("protocolFeeBps(): FAILED");
        }

        (success, data) = WEATHER_OPTION.staticcall(
            abi.encodeWithSignature("minPremium()")
        );
        if (success) {
            uint256 minPrem = abi.decode(data, (uint256));
            console.log("minPremium():", minPrem);
        } else {
            console.log("minPremium(): FAILED");
        }
    }

    function _checkVault() internal view {
        console.log("Vault at:", VAULT);
        console.log("----------------------------------------");

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(VAULT)
        }
        console.log("Code size:", codeSize, "bytes");

        if (codeSize == 0) {
            console.log("ERROR: No code at this address!");
            return;
        }

        (bool success, bytes memory data) = VAULT.staticcall(
            abi.encodeWithSignature("owner()")
        );
        if (success) {
            address owner = abi.decode(data, (address));
            console.log("owner():", owner);
        } else {
            console.log("owner(): FAILED");
        }

        (success, data) = VAULT.staticcall(
            abi.encodeWithSignature("weatherOptions()")
        );
        if (success) {
            address wo = abi.decode(data, (address));
            console.log("weatherOptions():", wo);
        } else {
            console.log("weatherOptions(): FAILED");
        }

        (success, data) = VAULT.staticcall(
            abi.encodeWithSignature("weth()")
        );
        if (success) {
            address weth = abi.decode(data, (address));
            console.log("weth():", weth);
        } else {
            console.log("weth(): FAILED");
        }

        (success, data) = VAULT.staticcall(
            abi.encodeWithSignature("totalAssets()")
        );
        if (success) {
            uint256 assets = abi.decode(data, (uint256));
            console.log("totalAssets():", assets);
        } else {
            console.log("totalAssets(): FAILED");
        }

        (success, data) = VAULT.staticcall(
            abi.encodeWithSignature("totalLocked()")
        );
        if (success) {
            uint256 locked = abi.decode(data, (uint256));
            console.log("totalLocked():", locked);
        } else {
            console.log("totalLocked(): FAILED");
        }

        (success, data) = VAULT.staticcall(
            abi.encodeWithSignature("availableLiquidity()")
        );
        if (success) {
            uint256 avail = abi.decode(data, (uint256));
            console.log("availableLiquidity():", avail);
        } else {
            console.log("availableLiquidity(): FAILED");
        }
    }

    function _checkConnections() internal view {
        console.log("Connection Check");
        console.log("----------------------------------------");

        (bool success, bytes memory data) = WEATHER_OPTION.staticcall(
            abi.encodeWithSignature("vault()")
        );
        
        if (!success) {
            console.log("ERROR: WeatherOption.vault() call failed!");
            console.log("This means the deployed contract is NOT WeatherOptionV3");
            console.log("You need to REDEPLOY!");
            return;
        }

        address woVault = abi.decode(data, (address));
        
        (success, data) = VAULT.staticcall(
            abi.encodeWithSignature("weatherOptions()")
        );
        address vaultWO = abi.decode(data, (address));

        console.log("WeatherOption.vault():", woVault);
        console.log("Vault.weatherOptions():", vaultWO);

        if (woVault == VAULT && vaultWO == WEATHER_OPTION) {
            console.log(" Connections are correct!");
        } else {
            console.log(" Connections are WRONG!");
            if (woVault != VAULT) {
                console.log("  - WeatherOption points to wrong vault:", woVault);
            }
            if (vaultWO != WEATHER_OPTION) {
                console.log("  - Vault points to wrong WeatherOption:", vaultWO);
            }
        }
    }
}