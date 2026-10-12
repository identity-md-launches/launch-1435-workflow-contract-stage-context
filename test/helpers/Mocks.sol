// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIntake} from "../../src/IIntake.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

contract MockToken is ERC20 {
    bool public rejectTransfers;
    uint256 public tax;
    address public hookTarget;
    address public hookFrom;
    bytes public hookData;
    bool public hookAttempted;
    bool public hookSucceeded;
    bytes public hookReturn;

    constructor() ERC20("Mock payment", "PAY") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReject(bool on) external {
        rejectTransfers = on;
    }

    function setTax(uint256 amount) external {
        tax = amount;
    }

    function setHook(address target, address from, bytes calldata data) external {
        hookTarget = target;
        hookFrom = from;
        hookData = data;
        hookAttempted = false;
        hookSucceeded = false;
        delete hookReturn;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            require(!rejectTransfers, "token rejected transfer");
            if (hookTarget != address(0) && from == hookFrom && !hookAttempted) {
                hookAttempted = true;
                (hookSucceeded, hookReturn) = hookTarget.call(hookData);
            }
            if (tax != 0) {
                super._update(from, address(0), tax);
                amount -= tax;
            }
        }
        super._update(from, to, amount);
    }
}

contract FalseToken is MockToken {
    bool public returnFalse;

    function setFalse(bool value) external {
        returnFalse = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (returnFalse) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (returnFalse) return false;
        return super.transferFrom(from, to, amount);
    }
}

contract MockIntake is IIntake {
    using SafeERC20 for IERC20;

    struct Ask {
        address payer;
        Callback callback;
        bytes4 failure;
        bytes32 action;
        address asset;
        uint256 amount;
        bytes body;
        bool completed;
    }
    mapping(bytes32 => Ask) private _asks;
    uint256 public nonce;
    uint256 public price = 0.5 ether;
    bool public rejectRequest;
    bool public skipPull;
    bytes32 public forcedId;
    bool public forceId;

    function setPrice(uint256 value) external {
        price = value;
    }

    function setReject(bool on) external {
        rejectRequest = on;
    }

    function setSkipPull(bool on) external {
        skipPull = on;
    }

    function setForcedId(bytes32 id) external {
        forcedId = id;
        forceId = true;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function getAsk(bytes32 id) external view returns (Ask memory) {
        return _asks[id];
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32)
    {
        return _request(action, body, callback, bytes4(0), asset, amount);
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 failure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32) {
        return _request(action, body, callback, failure, asset, amount);
    }

    function _request(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 failure,
        address asset,
        uint256 amount
    ) private returns (bytes32 id) {
        require(!rejectRequest, "Intake unavailable");
        require(amount == price && msg.value == 0, "wrong payment");
        if (!skipPull) IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        id = forceId ? forcedId : keccak256(abi.encode(address(this), ++nonce));
        _asks[id] = Ask(msg.sender, callback, failure, action, asset, amount, body, false);
    }

    function deliverResult(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool called)
    {
        Ask storage ask = _asks[id];
        require(!ask.completed, "completed");
        ask.completed = true;
        (called,) =
            ask.callback.target.call{gas: 200_000}(abi.encodeWithSelector(ask.callback.selector, id, a, signature));
    }

    function deliverFailure(bytes32 id, uint8 status, bytes32 reason, uint16 agreed, uint16 answered)
        external
        returns (bool called)
    {
        Ask storage ask = _asks[id];
        require(!ask.completed, "completed");
        ask.completed = true;
        (called,) = ask.callback.target.call{gas: 200_000}(
            abi.encodeWithSelector(ask.failure, id, status, reason, agreed, answered, bytes(""))
        );
    }
}

/// @dev Simulates an ERC-1271 registry which needs more than the callback's verification budget.
contract SlowSigner {
    bytes4 private constant MAGIC = 0x1626ba7e;

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        if (gasleft() < 140_000) return bytes4(0);
        return MAGIC;
    }
}
