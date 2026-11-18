// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentID} from "../../src/interfaces/IAgentID.sol";

contract MockAgentID is IAgentID {
    mapping(address => string) internal _h;
    mapping(bytes32 => address) internal _o;

    function give(address a, string memory h) external {
        _h[a] = h;
        _o[keccak256(bytes(h))] = a;
    }

    function balanceOf(address a) external view returns (uint256) {
        return bytes(_h[a]).length == 0 ? 0 : 1;
    }

    function handleOf(address a) external view returns (string memory) {
        return _h[a];
    }

    function ownerOfHandle(string calldata h) external view returns (address) {
        return _o[keccak256(bytes(h))];
    }
}

/// standard ERC20 returning bool
contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public feeBps; // fee-on-transfer simulation
    bool public noReturn; // USDT-on-Ethereum style

    function setFee(uint256 b) external { feeBps = b; }
    function setNoReturn(bool v) external { noReturn = v; }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function _move(address f, address t, uint256 a) internal {
        balanceOf[f] -= a;
        uint256 fee = a * feeBps / 10_000;
        balanceOf[t] += a - fee;
        totalSupply -= fee;
    }

    function transfer(address t, uint256 a) external returns (bool) {
        _move(msg.sender, t, a);
        if (noReturn) assembly { return(0, 0) }
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        _move(f, t, a);
        if (noReturn) assembly { return(0, 0) }
        return true;
    }
}

/// token whose transfers return false instead of reverting
contract FalseToken {
    mapping(address => uint256) public balanceOf;
    function transfer(address, uint256) external pure returns (bool) { return false; }
    function transferFrom(address, address, uint256) external pure returns (bool) { return false; }
}

contract RevertingReceiver {
    receive() external payable { revert("nope"); }
}

interface IGig {
    function release(uint256) external;
    function withdraw() external;
    function cancel(uint256) external;
}

/// worker/poster contract that tries to re-enter on receive
contract Reenterer {
    IGig public gig;
    uint256 public target;
    bool public attempted;
    bool public reentered;

    constructor(IGig g) { gig = g; }
    function setTarget(uint256 id) external { target = id; }

    function call(address to, bytes calldata data, uint256 v) external payable returns (bytes memory) {
        (bool ok, bytes memory r) = to.call{value: v}(data);
        require(ok, "inner call failed");
        return r;
    }

    receive() external payable {
        if (!attempted) {
            attempted = true;
            try gig.cancel(target) { reentered = true; } catch {}
            try gig.release(target) { reentered = true; } catch {}
        }
    }
}
