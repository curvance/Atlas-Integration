// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";

/// @title ChainlinkFeedOEVWrapper
/// @notice A wrapper for Chainlink price feeds that allows early updates with a fee
/// @dev This contract implements the AggregatorV3Interface and adds OEV (Oracle Extractable Value) functionality
contract ChainlinkCurvanceOEVWrapper is AggregatorV3Interface, Ownable {
    /// @notice Emitted when the price is updated
    /// @param updater The address that updated the price
    /// @param roundId The round ID that was cached
    event PriceUpdatedEarly(address indexed updater, uint256 roundId);

    /// @notice Emitted when an address is added or removed from whitelist
    /// @param account The address that was updated
    /// @param isWhitelisted Whether the address is now whitelisted
    event WhitelistUpdated(address indexed account, bool isWhitelisted);

    /// @notice Emitted when the max decrements value is changed
    /// @param oldMaxDecrements The old maximum number of decrements
    /// @param newMaxDecrements The new maximum number of decrements
    event MaxDecrementsChanged(uint8 oldMaxDecrements, uint8 newMaxDecrements);

    /// @notice Emitted when the max round delay is changed
    /// @param oldMaxRoundDelay The old maximum round delay
    /// @param newMaxRoundDelay The new maximum round delay
    event NewMaxRoundDelay(uint8 oldMaxRoundDelay, uint8 newMaxRoundDelay);

    /// @notice The original Chainlink price feed contract
    AggregatorV3Interface public immutable originalFeed;

    /// @notice The maximum number of times to decrement the round before falling back to latest price
    uint8 public maxDecrements;

    /// @notice The max delay a round can have before falling back to latest price
    uint8 public maxRoundDelay;

    /// @notice The last cached round id
    uint256 public cachedRoundId;

    /// @notice Mapping of whitelisted addresses allowed to update price early
    mapping(address => bool) public whitelist;

    /// @notice Constructor to initialize the wrapper
    /// @param _originalFeed Address of the original Chainlink feed
    /// @param _owner Address of the contract owner
    /// @param _maxDecrements The maximum number of decrements before falling back to latest price
    /// @param _maxRoundDelay The max delay a round can have before falling back to latest price
    constructor(address _originalFeed, address _owner, uint8 _maxDecrements, uint8 _maxRoundDelay)
        Ownable(_owner)
    {
        originalFeed = AggregatorV3Interface(_originalFeed);

        maxDecrements = _maxDecrements;
        maxRoundDelay = _maxRoundDelay;

        cachedRoundId = originalFeed.latestRound();
    }

    /// @notice Get the latest round data
    /// @dev Returns cached data if the current round is the same as the cached round and 10 seconds have not passed
    /// @return roundId The round ID
    /// @return answer The price
    /// @return startedAt The timestamp when the round started
    /// @return updatedAt The timestamp when the round was updated
    /// @return answeredInRound The round ID in which the answer was computed
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = originalFeed.latestRoundData();

        // Return the current round data if either:
        // 1. This round has already been cached (meaning someone paid for it)
        // 2. The round is too old
        if (roundId == cachedRoundId || block.timestamp >= updatedAt + maxRoundDelay) {
            _validateRoundData(roundId, answer, updatedAt, answeredInRound);
            return (roundId, answer, startedAt, updatedAt, answeredInRound);
        }

        uint256 startRoundId = roundId;

        // If the current round is not too old and hasn't been paid for,
        // attempt to find the most recent valid round by checking previous rounds
        for (uint256 i = 0; i < maxDecrements && --startRoundId > 0; i++) {
            try originalFeed.getRoundData(uint80(startRoundId)) returns (
                uint80 r, int256 a, uint256 s, uint256 u, uint80 ar
            ) {
                _validateRoundData(r, a, u, ar);

                roundId = r;
                answer = a;
                startedAt = s;
                updatedAt = u;
                answeredInRound = ar;
                return (roundId, answer, startedAt, updatedAt, answeredInRound);
            } catch {}
        }

        // Validate round data if we fall back to the latest price
        _validateRoundData(roundId, answer, updatedAt, answeredInRound);
    }

    /// @notice Get the number of decimals in the feed
    /// @return The number of decimals
    function decimals() external view override returns (uint8) {
        return originalFeed.decimals();
    }

    /// @notice Get the description of the feed
    /// @return The description string
    function description() external view override returns (string memory) {
        return originalFeed.description();
    }

    /// @notice Get the version number of the aggregator
    /// @return The version number
    function version() external view override returns (uint256) {
        return originalFeed.version();
    }

    /// @notice Get data about a specific round
    /// @param _roundId The round ID to retrieve data for
    /// @return roundId The round ID
    /// @return answer The price
    /// @return startedAt The timestamp when the round started
    /// @return updatedAt The timestamp when the round was updated
    /// @return answeredInRound The round ID in which the answer was computed
    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = originalFeed.getRoundData(_roundId);
    }

    /// @notice Get the latest round ID
    /// @return The latest round ID
    function latestRound() external view override returns (uint256) {
        return originalFeed.latestRound();
    }

    /// @notice Update the price earlier than the standard update interval
    /// @dev Only callable by whitelisted addresses
    function updatePriceEarly() external {
        require(whitelist[msg.sender], "ChainlinkOEVWrapper: Not whitelisted");

        // Get latest round data and validate it
        (uint256 latestRoundId, int256 latestAnswer,, uint256 latestUpdatedAt, uint80 latestAnsweredInRound) =
            originalFeed.latestRoundData();

        _validateRoundData(uint80(latestRoundId), latestAnswer, latestUpdatedAt, latestAnsweredInRound);

        // Only update if the new round is higher than cached
        if (latestRoundId > cachedRoundId) {
            cachedRoundId = latestRoundId;

            // Emit event for the early price update
            emit PriceUpdatedEarly(msg.sender, latestRoundId);
        }
        // Else gracefully move on without reverting.
        // This allows the off-chain auctioneer to call this function regardless of
        // there being a new price update; and for interest-triggered liquidations to
        // occur via this UserOp path.
    }

    /// @notice Add or remove an address from the whitelist
    /// @param account The address to update
    /// @param isWhitelisted Whether to whitelist or remove from whitelist
    /// @dev Only callable by the contract owner
    function setWhitelist(address account, bool isWhitelisted) external onlyOwner {
        whitelist[account] = isWhitelisted;
        emit WhitelistUpdated(account, isWhitelisted);
    }

    /// @notice Set the maximum number of decrements before falling back to latest price
    /// @param _maxDecrements The new maximum number of decrements
    function setMaxDecrements(uint8 _maxDecrements) external onlyOwner {
        uint8 oldMaxDecrements = maxDecrements;
        maxDecrements = _maxDecrements;

        emit MaxDecrementsChanged(oldMaxDecrements, _maxDecrements);
    }

    /// @notice Set the maximum round delay
    /// @param _maxRoundDelay The new maximum round delay
    function setMaxRoundDelay(uint8 _maxRoundDelay) external onlyOwner {
        uint8 oldMaxRoundDelay = maxRoundDelay;
        maxRoundDelay = _maxRoundDelay;

        emit NewMaxRoundDelay(oldMaxRoundDelay, maxRoundDelay);
    }

    /// @notice Validate the round data from Chainlink
    /// @param roundId The round ID to validate
    /// @param answer The price to validate
    /// @param updatedAt The timestamp when the round was updated
    /// @param answeredInRound The round ID in which the answer was computed
    function _validateRoundData(uint80 roundId, int256 answer, uint256 updatedAt, uint80 answeredInRound)
        internal
        pure
    {
        require(answer > 0, "Chainlink price cannot be lower or equal to 0");
        require(updatedAt != 0, "Round is in incompleted state");
        require(answeredInRound >= roundId, "Stale price");
    }
}