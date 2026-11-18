// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal view interface of the Agent ID registry on BNB Chain
///         (SPACE ID Agent ID, 0x60b9262456de011f7d15a54cdd8c48baaa8b022f).
///         Agent IDs are soulbound ERC-721 handles, one per address.
interface IAgentID {
    function balanceOf(address owner) external view returns (uint256);
    function handleOf(address owner) external view returns (string memory);
    function ownerOfHandle(string calldata handle) external view returns (address);
}
