// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {AgentGig} from "../src/AgentGig.sol";
import {IAgentID} from "../src/interfaces/IAgentID.sol";

interface IBEP20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

/// Fork tests against the REAL Agent ID registry on BNB Chain mainnet.
/// Run: BSC_RPC_URL=https://bsc-rpc.publicnode.com forge test --match-path test/AgentGig.fork.t.sol
contract AgentGigForkTest is Test {
    IAgentID constant REGISTRY = IAgentID(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F);
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955; // BSC-USD (18 decimals)

    // real Agent ID holders (public addresses, handles read live from the registry)
    address constant GEMPAR = 0x78d4a5197d643C01F52E1A0b65255f72c90B6703;
    address constant AGUNVERSE = 0xFA26F27494422C553473A62C6B10b00082C0D966;
    address constant APRI = 0x52A0a5b71F586087b248e5f9EC04D989212096eC;
    // deployer, no Agent ID
    address constant WT = 0x152C2ed122A696987441E3929c7663444100493A;

    AgentGig gig;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        vm.prank(WT);
        gig = new AgentGig(REGISTRY);
    }

    modifier onFork() {
        if (!forked) {
            console2.log("skipped: set BSC_RPC_URL to run fork tests");
            return;
        }
        _;
    }

    function test_fork_registryFacts() public onFork {
        assertEq(block.chainid, 56);
        assertGt(REGISTRY.balanceOf(GEMPAR), 0);
        assertEq(REGISTRY.handleOf(GEMPAR), "gempar");
        assertEq(REGISTRY.ownerOfHandle("gempar"), GEMPAR);
        assertEq(REGISTRY.balanceOf(WT), 0);
    }

    function test_fork_profileReadsRealHandles() public onFork {
        (string memory h,) = gig.profile(AGUNVERSE);
        assertEq(h, "agunverse");
        (h,) = gig.profile(WT);
        assertEq(bytes(h).length, 0);
    }

    function test_fork_nonHolderBlocked() public onFork {
        vm.deal(WT, 1 ether);
        vm.prank(WT);
        vm.expectRevert(AgentGig.NotAgent.selector);
        gig.post{value: 0.001 ether}(address(0), 0.001 ether, 1 days, "x");
    }

    function test_fork_fullFlow_BNB_realHolders() public onFork {
        vm.deal(AGUNVERSE, 1 ether);
        uint256 w0 = GEMPAR.balance;
        vm.recordLogs();
        vm.prank(AGUNVERSE);
        uint256 id = gig.post{value: 0.0005 ether}(address(0), 0.0005 ether, 1 days, "Summarize BSC block 1 in 3 bullets");
        vm.prank(GEMPAR);
        gig.claim(id);
        vm.prank(GEMPAR);
        gig.submit(id, keccak256("summary"), "https://gist.github.com/x");
        vm.prank(AGUNVERSE);
        gig.release(id);
        assertEq(GEMPAR.balance - w0, 0.0005 ether);
        vm.prank(AGUNVERSE);
        gig.rate(id, 5);
        vm.prank(GEMPAR);
        gig.rate(id, 5);
        (string memory h, AgentGig.Rep memory r) = gig.profile(GEMPAR);
        assertEq(h, "gempar");
        assertEq(r.completed, 1);
        assertEq(r.ratingSum, 5);
    }

    function test_fork_fullFlow_USDT_exactApproval() public onFork {
        deal(USDT, APRI, 10e18);
        vm.startPrank(APRI);
        IBEP20(USDT).approve(address(gig), 2e18);
        uint256 id = gig.post(USDT, 2e18, 2 hours, "Translate README.md to Bahasa Indonesia");
        vm.stopPrank();
        assertEq(IBEP20(USDT).allowance(APRI, address(gig)), 0);
        assertEq(IBEP20(USDT).balanceOf(address(gig)), 2e18);
        vm.prank(GEMPAR);
        gig.claim(id);
        vm.prank(GEMPAR);
        gig.submit(id, keccak256("id.md"), "ipfs://bafy");
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(WT); // anyone (even a non-holder) can trigger the auto-release
        gig.release(id);
        assertEq(IBEP20(USDT).balanceOf(GEMPAR) >= 2e18, true);
        assertEq(IBEP20(USDT).balanceOf(address(gig)), 0);
    }

    function test_fork_gasProfile() public onFork {
        vm.deal(AGUNVERSE, 1 ether);
        uint256 g = gasleft();
        vm.prank(AGUNVERSE);
        uint256 id = gig.post{value: 0.0005 ether}(address(0), 0.0005 ether, 1 days, "Summarize BSC block 1 in 3 bullets");
        console2.log("post gas", g - gasleft());
        g = gasleft();
        vm.prank(GEMPAR);
        gig.claim(id);
        console2.log("claim gas", g - gasleft());
    }
}
