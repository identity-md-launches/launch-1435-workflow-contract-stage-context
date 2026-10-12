// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice IdentityMD Intake v2. Request IDs here are distinct from oracle UUIDs.
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256);

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId);

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId);
}
