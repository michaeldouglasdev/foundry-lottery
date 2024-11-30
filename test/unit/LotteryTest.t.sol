// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployLottery} from "script/DeployLottery.s.sol";
import {Lottery} from "src/Lottery.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {CodeConstants} from "script/HelperConfig.s.sol";

contract LotteryTest is Test, CodeConstants {
    Lottery public lottery;
    HelperConfig public helperConfig;
    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_PLAYER_BALANCE = 10 ether;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint32 callbackGasLimit;
    uint256 subscriptionId;

    address vrfCoordinatorV2_5;

    event LotteryEntered(address indexed player);
    event LotteryWinner(address indexed winner);

    function setUp() external {
        DeployLottery deploy = new DeployLottery();
        (lottery, helperConfig) = deploy.deploy();
        HelperConfig.NetworkConfig memory networkConfig = helperConfig
            .getConfig();
        entranceFee = networkConfig.entranceFee;
        interval = networkConfig.interval;
        vrfCoordinator = networkConfig.vrfCoordinator;
        gasLane = networkConfig.gasLane;
        callbackGasLimit = networkConfig.callbackGasLimit;
        subscriptionId = networkConfig.subscriptionId;
        vm.deal(PLAYER, STARTING_PLAYER_BALANCE);
    }

    function testLotteryInitializesInOpenState() public view {
        assert(lottery.getStatus() == Lottery.LotteryStatus.OPEN);
    }

    function testLotteryRevertsWhenYouDontPayEnough() public {
        vm.prank(PLAYER);
        vm.expectRevert(Lottery.Lottery__NotEnoughEth.selector);

        lottery.enter{value: 0.005 ether}();
    }

    function testLotteryRecordsPlayerWhenTheyEnter() public {
        vm.prank(PLAYER);

        lottery.enter{value: entranceFee}();

        assertEq(lottery.getPlayerByIndex(0), PLAYER);
    }

    function testEnteringRaffleEmitsEvent() public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(lottery));
        emit LotteryEntered(PLAYER);
        lottery.enter{value: entranceFee}();
    }

    function testDontAllowPlayersIfStatusIsNotOpen() public {
        vm.prank(PLAYER);
        lottery.enter{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        lottery.performUpkeep("");

        vm.expectRevert(Lottery.Lottery__NotOpen.selector);
        vm.prank(PLAYER);
        lottery.enter{value: entranceFee}();
    }

    function testCheckUpkeepReturnsFalseIfItHasNoBalance() public {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        (bool upkeepNeeded, ) = lottery.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfLotteryIsNotOpen() public {
        vm.prank(PLAYER);
        lottery.enter{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        lottery.performUpkeep("");

        (bool upkeepNeeded, ) = lottery.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    // testCheckUpkeepReturnsFalseIfEnoughTimeHasPassed
    // testCheckUpkeepReturnsTrueWhenparametersAreGood

    function testPerformUpKeepCanOnlyRunIfCheckUpkeepIsTrue() public {
        vm.prank(PLAYER);
        lottery.enter{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        lottery.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        vm.prank(PLAYER);
        lottery.enter{value: entranceFee}();

        uint256 currentBalance = entranceFee;
        uint256 numPlayers = 1;
        Lottery.LotteryStatus status = lottery.getStatus();

        vm.expectRevert(
            abi.encodeWithSelector(
                Lottery.Lottery__UpkeepNotNeeded.selector,
                currentBalance,
                numPlayers,
                status
            )
        );
        lottery.performUpkeep("");
    }

    modifier lotteryEntered() {
        vm.prank(PLAYER);
        lottery.enter{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        _;
    }

    function testPerformUpkeepUpdatesLotteryStateAndEmitsRequestId()
        public
        lotteryEntered
    {
        // Act
        vm.recordLogs();
        lottery.performUpkeep(""); // emits requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        //[0] = vrfCoordinator contract
        bytes32 requestId = entries[1].topics[1];

        // Assert
        Lottery.LotteryStatus status = lottery.getStatus();
        // requestId = raffle.getLastRequestId();
        assert(uint256(requestId) > 0);
        assert(uint256(status) == uint256(Lottery.LotteryStatus.CALCULATING));
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep()
        public
        lotteryEntered
        skipFork
    {
        vm.expectRevert();
        VRFCoordinatorV2_5Mock(vrfCoordinatorV2_5).fulfillRandomWords(
            0,
            address(lottery)
        );
    }

    modifier skipFork() {
        if (block.chainid != LOCAL_CHAIN_ID) {
            return;
        }
        _;
    }

    function testFulfillrandomWordsPicksAWinnerAndSendsMoneyAndFinishs()
        public
        lotteryEntered
        skipFork
    {
        uint256 additionalEntrants = 3; // 4 total
        uint256 startingIndex = 1;
        for (
            uint256 i = startingIndex;
            i < startingIndex + additionalEntrants;
            i++
        ) {
            address newPlayer = address(uint160(i));
            hoax(newPlayer, 1 ether);
            lottery.enter{value: entranceFee}();
        }

        uint256 createdAt = lottery.getCreatedAt();

        vm.recordLogs();
        lottery.performUpkeep("");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        uint256 REQUEST_NUMS = lottery.getNumWords();

        uint256[] memory words = new uint256[](REQUEST_NUMS);
        for (uint256 i = 0; i < REQUEST_NUMS; i++) {
            words[i] = uint256(keccak256(abi.encode(requestId, i)));
        }
        uint256 indexWinner = words[0] % lottery.getPlayers();
        address expectedWinner = lottery.getPlayerByIndex(indexWinner);
        uint winnerStartingBalance = expectedWinner.balance;

        vm.expectEmit(true, false, false, false, address(lottery));
        emit LotteryWinner(payable(expectedWinner));
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(lottery)
        );

        address winner = lottery.getWinner();

        Lottery.LotteryStatus status = lottery.getStatus();

        uint256 winnerBalance = winner.balance;
        uint256 finishedAt = lottery.getFinishedAt();
        uint256 prize = entranceFee * (additionalEntrants + 1);

        assert(winner == expectedWinner);
        assert(status == Lottery.LotteryStatus.FINISHED);
        assert(winnerBalance == winnerStartingBalance + prize);
        assert(finishedAt > createdAt);
    }
}
