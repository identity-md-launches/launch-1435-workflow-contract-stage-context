// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Tribunal} from "../../src/Tribunal.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

/// @dev Exposes the inherited verification solely to accept the unchanged bytes32[] protocol vector.
contract ConformanceHarness is Tribunal {
    constructor(address owner_, address intake_, address asset_, bytes32 action_, uint256 price_, address signer_)
        Tribunal(owner_, intake_, asset_, action_, price_, signer_)
    {}

    function verifyProtocolVector(OracleAttestation.Attestation calldata a, bytes calldata signature) external view {
        _verifyAttestation(a, signature);
    }
}
