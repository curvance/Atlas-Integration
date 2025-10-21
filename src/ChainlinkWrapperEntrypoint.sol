// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ChainlinkCurvanceOEVWrapper} from "./ChainlinkCurvanceOEVWrapper.sol";

/// @title ChainlinkWrapperEntrypoint
/// @notice Batch entrypoint contract for updating multiple ChainlinkCurvanceOEVWrapper contracts
/// @dev This contract allows efficient batch updates of price feeds by calling updatePriceEarly()
///      on multiple wrapper contracts in a single transaction. The entrypoint must be whitelisted
///      on each wrapper contract it intends to update.
contract ChainlinkWrapperEntrypoint is Ownable {
    /// @notice Array of wrapper contracts to update
    address[] public wrappers;

    /// @notice Emitted when a batch update is initiated
    /// @param updater The address that initiated the batch update
    /// @param totalWrappers The total number of wrappers in the batch
    /// @param successfulUpdates The number of successful updates
    event BatchUpdateExecuted(
        address indexed updater,
        uint256 totalWrappers,
        uint256 successfulUpdates
    );

    /// @notice Emitted when a wrapper is added to the list
    /// @param wrapper The wrapper address that was added
    event WrapperAdded(address indexed wrapper);

    /// @notice Emitted when a wrapper is removed from the list
    /// @param wrapper The wrapper address that was removed
    event WrapperRemoved(address indexed wrapper);

    /// @notice Constructor to initialize the contract
    /// @param _owner Address of the contract owner
    constructor(address _owner) Ownable(_owner) {}

    /// @notice Update prices early on all configured wrapper contracts
    /// @dev Calls updatePriceEarly() on each wrapper in the stored list.
    ///      Individual failures are caught and do not revert the entire batch.
    /// @return successCount The number of successful updates
    function batchUpdatePriceEarly() external returns (uint256 successCount) {
        uint256 length = wrappers.length;

        for (uint256 i = 0; i < length; ++i) {
            try ChainlinkCurvanceOEVWrapper(wrappers[i]).updatePriceEarly() {
                ++successCount;
            } catch {
                // Silently continue on failure
            }
        }

        emit BatchUpdateExecuted(msg.sender, length, successCount);
    }

    /// @notice Configure a wrapper by adding or removing it from the list
    /// @dev Only callable by the owner
    /// @param _wrapper Address of the wrapper contract
    /// @param _add True to add the wrapper, false to remove it
    function configureWrapper(address _wrapper, bool _add) external onlyOwner {
        if (_add) {
            // Add wrapper - check for duplicates
            uint256 length = wrappers.length;
            for (uint256 i = 0; i < length; ++i) {
                require(wrappers[i] != _wrapper, "Wrapper already exists");
            }
            wrappers.push(_wrapper);
            emit WrapperAdded(_wrapper);
        } else {
            // Remove wrapper - find and remove using swap-and-pop
            uint256 length = wrappers.length;
            for (uint256 i = 0; i < length; ++i) {
                if (wrappers[i] == _wrapper) {
                    // Replace with last element and pop
                    wrappers[i] = wrappers[length - 1];
                    wrappers.pop();
                    emit WrapperRemoved(_wrapper);
                    return;
                }
            }
            revert("Wrapper not found");
        }
    }

    /// @notice Get the complete list of wrapper contracts
    /// @return Array of wrapper contract addresses
    function getWrappers() external view returns (address[] memory) {
        return wrappers;
    }

    /// @notice Get the number of wrappers in the list
    /// @return The length of the wrappers array
    function getWrapperCount() external view returns (uint256) {
        return wrappers.length;
    }
}
