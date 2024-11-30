// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {Lottery} from "src/Lottery.sol";

import {HelperConfig} from "./HelperConfig.s.sol";
import {CreateSubscription, FundSubscription, AddConsumer} from "script/Interactions.s.sol";

contract DeployLottery is Script {
    function run() public {
        deploy();
    }

    function deploy() public returns (Lottery, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory networkConfig = helperConfig
            .getConfig();

        if (networkConfig.subscriptionId == 0) {
            CreateSubscription createSubscription = new CreateSubscription();
            (
                networkConfig.subscriptionId,
                networkConfig.vrfCoordinator
            ) = createSubscription.create(
                networkConfig.vrfCoordinator,
                networkConfig.account
            );
            FundSubscription fundSubscription = new FundSubscription();
            fundSubscription.fund(
                networkConfig.vrfCoordinator,
                networkConfig.subscriptionId,
                networkConfig.link,
                networkConfig.account
            );
        }

        vm.startBroadcast(networkConfig.account);
        Lottery lottery = new Lottery(
            networkConfig.entranceFee,
            networkConfig.interval,
            networkConfig.vrfCoordinator,
            networkConfig.gasLane,
            networkConfig.subscriptionId,
            networkConfig.callbackGasLimit
        );
        vm.stopBroadcast();

        AddConsumer addConsumer = new AddConsumer();
        addConsumer.add(
            address(lottery),
            networkConfig.vrfCoordinator,
            networkConfig.subscriptionId,
            networkConfig.account
        );
        return (lottery, helperConfig);
    }
}
