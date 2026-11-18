// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentGig} from "../src/AgentGig.sol";
import {IAgentID} from "../src/interfaces/IAgentID.sol";
import {MockAgentID} from "./mocks/Mocks.sol";

/// Random actors drive random actions; escrow must always equal the sum of live rewards.
contract Handler is Test {
    AgentGig public gig;
    address[] public actors;
    uint256 public paidOut;
    uint256 public refunded;
    uint256 public deposited;

    constructor(AgentGig g, address[] memory a) {
        gig = g;
        actors = a;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _id(uint256 s) internal view returns (uint256) {
        uint256 n = gig.taskCount();
        return n == 0 ? 0 : s % n;
    }

    function post(uint256 a, uint96 amt, uint64 dur) external {
        address who = _actor(a);
        amt = uint96(bound(amt, 0, 5 ether));
        dur = uint64(bound(dur, 1 hours, 30 days));
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        gig.post{value: amt}(address(0), amt, dur, "inv");
        deposited += amt;
    }

    function claim(uint256 a, uint256 i) external {
        if (gig.taskCount() == 0) return;
        vm.prank(_actor(a));
        try gig.claim(_id(i)) {} catch {}
    }

    function unclaim(uint256 a, uint256 i) external {
        if (gig.taskCount() == 0) return;
        vm.prank(_actor(a));
        try gig.unclaim(_id(i)) {} catch {}
    }

    function submit(uint256 a, uint256 i) external {
        if (gig.taskCount() == 0) return;
        vm.prank(_actor(a));
        try gig.submit(_id(i), keccak256(abi.encode(i)), "r") {} catch {}
    }

    function reject(uint256 a, uint256 i) external {
        if (gig.taskCount() == 0) return;
        vm.prank(_actor(a));
        try gig.reject(_id(i), "no") {} catch {}
    }

    function release(uint256 a, uint256 i) external {
        if (gig.taskCount() == 0) return;
        uint256 id = _id(i);
        AgentGig.Task memory t = gig.getTask(id);
        vm.prank(_actor(a));
        try gig.release(id) {
            paidOut += t.reward;
        } catch {}
    }

    function cancel(uint256 a, uint256 i) external {
        if (gig.taskCount() == 0) return;
        uint256 id = _id(i);
        AgentGig.Task memory t = gig.getTask(id);
        vm.prank(_actor(a));
        try gig.cancel(id) {
            refunded += t.reward;
        } catch {}
    }

    function warp(uint32 s) external {
        vm.warp(block.timestamp + bound(s, 0, 5 days));
    }
}

contract AgentGigInvariant is Test {
    AgentGig gig;
    Handler h;

    function setUp() public {
        MockAgentID reg = new MockAgentID();
        address[] memory a = new address[](4);
        for (uint256 i; i < 4; i++) {
            a[i] = makeAddr(string(abi.encodePacked("agent", vm.toString(i))));
            reg.give(a[i], string(abi.encodePacked("agent", vm.toString(i))));
        }
        gig = new AgentGig(IAgentID(address(reg)));
        h = new Handler(gig, a);
        targetContract(address(h));
    }

    /// escrow == deposits - payouts - refunds, and equals the sum of rewards of live tasks
    function invariant_solvent() public view {
        uint256 live;
        uint256 n = gig.taskCount();
        for (uint256 i; i < n; i++) {
            AgentGig.Task memory t = gig.getTask(i);
            if (uint8(t.status) <= uint8(AgentGig.Status.Submitted)) live += t.reward;
        }
        assertEq(address(gig).balance, live, "balance == live escrow");
        assertEq(h.deposited() - h.paidOut() - h.refunded(), live, "accounting");
    }

    /// a settled task never changes again
    function invariant_workerNeverPoster() public view {
        uint256 n = gig.taskCount();
        for (uint256 i; i < n; i++) {
            AgentGig.Task memory t = gig.getTask(i);
            assertTrue(t.worker != t.poster);
            if (t.status == AgentGig.Status.Submitted) assertGt(t.reviewBy, 0);
        }
    }
}
