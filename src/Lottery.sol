// SPDX-License-Identifier: MIT

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
pragma solidity 0.8.19;

contract Lottery is VRFConsumerBaseV2Plus {
    error Lottery__NotEnoughEth();
    error Lottery__TransferFailed();
    error Lottery__NotOpen();
    error Lottery__UpkeepNotNeeded(
        uint256 balance,
        uint256 playersLength,
        LotteryStatus status
    );

    enum LotteryStatus {
        OPEN,
        CALCULATING,
        FINISHED
    }
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    uint256 private immutable i_entranceFee;
    // the duration of the lottery in seconds
    uint256 private immutable i_interval;
    uint256 private immutable i_subscriptionId;
    // The gas amount that I'm willing to pay
    bytes32 private immutable i_gasLane;
    uint32 private immutable i_callbackGasLimit;

    address payable[] private s_players;

    uint256 private s_createdAt;
    uint256 private s_finishedAt;

    address private s_winner;
    LotteryStatus private s_status;

    event LotteryEntered(address indexed player);
    event LotteryWinner(address indexed winner);
    event RequestedLotteryWinner(uint256 indexed requestId);

    constructor(
        uint256 entranceFee,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint256 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        i_entranceFee = entranceFee;
        i_interval = interval;
        s_createdAt = block.timestamp;
        i_gasLane = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;

        s_status = LotteryStatus.OPEN;
    }

    function enter() public payable {
        //require(msg.value >= i_entranceFee, "Not enough ETH sent");
        //require(msg.value <= i_entranceFee, NotEnoughEth()); #just available from 0.8.26 and it is less gas efficient than if below

        if (msg.value < i_entranceFee) {
            revert Lottery__NotEnoughEth();
        }

        if (s_status != LotteryStatus.OPEN) {
            revert Lottery__NotOpen();
        }
        s_players.push(payable(msg.sender));
        emit LotteryEntered(msg.sender);
    }

    function checkUpkeep(
        bytes memory /* checkData */
    ) public view returns (bool upkeepNeeded, bytes memory /* performData */) {
        bool timeHasPassed = (block.timestamp - s_createdAt) >= i_interval;
        bool isOpen = s_status == LotteryStatus.OPEN;
        bool hasBalance = address(this).balance > 0;
        bool hasPlayers = s_players.length > 0;
        upkeepNeeded = timeHasPassed && isOpen && hasBalance && hasPlayers;

        return (upkeepNeeded, "");
    }

    function performUpkeep(bytes calldata /* performData */) external {
        (bool upkeepNeeded, ) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Lottery__UpkeepNotNeeded(
                address(this).balance,
                s_players.length,
                s_status
            );
        }
        s_status = LotteryStatus.CALCULATING;

        VRFV2PlusClient.RandomWordsRequest memory request = VRFV2PlusClient
            .RandomWordsRequest({
                keyHash: i_gasLane,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: NUM_WORDS,
                // Pay using native token instead of LINK.
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            });

        uint256 requestId = s_vrfCoordinator.requestRandomWords(request);

        emit RequestedLotteryWinner(requestId);
    }

    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    function fulfillRandomWords(
        uint256 /* requestId */,
        uint256[] calldata randomWords
    ) internal virtual override {
        uint256 indexOfWinner = randomWords[0] % s_players.length;

        address payable winner = s_players[indexOfWinner];
        s_winner = winner;

        s_status = LotteryStatus.FINISHED;
        s_finishedAt = block.timestamp;
        emit LotteryWinner(winner);
        (bool success, ) = winner.call{value: address(this).balance}("");
        if (!success) {
            revert Lottery__TransferFailed();
        }
    }

    function getStatus() public view returns (LotteryStatus) {
        return s_status;
    }

    function getPlayers() public view returns (uint256) {
        return s_players.length;
    }

    function getPlayerByIndex(uint256 index) public view returns (address) {
        return s_players[index];
    }

    function getCreatedAt() public view returns (uint256) {
        return s_createdAt;
    }

    function getFinishedAt() public view returns (uint256) {
        return s_finishedAt;
    }

    function getWinner() public view returns (address) {
        return s_winner;
    }

    function getNumWords() public pure returns (uint32) {
        return NUM_WORDS;
    }
}
