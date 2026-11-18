// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentGig} from "../src/AgentGig.sol";
import {IAgentID} from "../src/interfaces/IAgentID.sol";
import {MockAgentID, MockERC20, FalseToken, RevertingReceiver, Reenterer, IGig} from "./mocks/Mocks.sol";

contract AgentGigTest is Test {
    AgentGig gig;
    MockAgentID reg;
    MockERC20 usd;

    address poster = makeAddr("poster");
    address worker = makeAddr("worker");
    address other = makeAddr("other");
    address stranger = makeAddr("stranger"); // no Agent ID

    uint64 constant DUR = 1 days;

    function setUp() public {
        reg = new MockAgentID();
        reg.give(poster, "poster");
        reg.give(worker, "worker");
        reg.give(other, "other");
        gig = new AgentGig(IAgentID(address(reg)));
        usd = new MockERC20();
        vm.deal(poster, 10 ether);
        vm.deal(stranger, 10 ether);
        usd.mint(poster, 1000e18);
    }

    // ----------------------------------------------------------- helpers
    function _postBNB(uint256 amt) internal returns (uint256 id) {
        vm.prank(poster);
        id = gig.post{value: amt}(address(0), amt, DUR, "summarize block 1");
    }

    function _claimSubmit(uint256 id) internal {
        vm.prank(worker);
        gig.claim(id);
        vm.prank(worker);
        gig.submit(id, keccak256("result"), "ipfs://result");
    }

    // ----------------------------------------------------------- deploy
    function test_constructor_rejectsEOA() public {
        vm.expectRevert(AgentGig.BadInput.selector);
        new AgentGig(IAgentID(makeAddr("eoa")));
    }

    function test_noOwnerSurface() public view {
        // there is no owner(), pause(), setFee(), upgradeTo() etc. Only the immutable registry.
        assertEq(address(gig.AGENT_ID()), address(reg));
    }

    // ----------------------------------------------------------- happy paths
    function test_fullFlow_BNB() public {
        uint256 id = _postBNB(0.01 ether);
        assertEq(address(gig).balance, 0.01 ether);
        _claimSubmit(id);
        vm.prank(poster);
        gig.release(id);
        assertEq(worker.balance, 0.01 ether);
        assertEq(address(gig).balance, 0);
        AgentGig.Task memory t = gig.getTask(id);
        assertEq(uint8(t.status), uint8(AgentGig.Status.Paid));
        (, AgentGig.Rep memory w) = gig.profile(worker);
        assertEq(w.completed, 1);
        (, AgentGig.Rep memory p) = gig.profile(poster);
        assertEq(p.posted, 1);
        assertEq(p.paidOut, 1);
    }

    function test_fullFlow_token_exactApproval() public {
        vm.startPrank(poster);
        usd.approve(address(gig), 50e18);
        uint256 id = gig.post(address(usd), 50e18, DUR, "translate README to id");
        vm.stopPrank();
        assertEq(usd.allowance(poster, address(gig)), 0, "pulls exactly the approved amount");
        assertEq(usd.balanceOf(address(gig)), 50e18);
        _claimSubmit(id);
        vm.prank(poster);
        gig.release(id);
        assertEq(usd.balanceOf(worker), 50e18);
    }

    function test_feeOnTransferToken_recordsReceived() public {
        usd.setFee(100); // 1%
        vm.startPrank(poster);
        usd.approve(address(gig), 100e18);
        uint256 id = gig.post(address(usd), 100e18, DUR, "x");
        vm.stopPrank();
        assertEq(gig.getTask(id).reward, 99e18);
        _claimSubmit(id);
        vm.prank(poster);
        gig.release(id); // must not revert for insolvency
        assertEq(usd.balanceOf(address(gig)), 0);
    }

    function test_noReturnToken_works() public {
        usd.setNoReturn(true);
        vm.startPrank(poster);
        usd.approve(address(gig), 1e18);
        uint256 id = gig.post(address(usd), 1e18, DUR, "x");
        vm.stopPrank();
        _claimSubmit(id);
        vm.prank(poster);
        gig.release(id);
        assertEq(usd.balanceOf(worker), 1e18);
    }

    function test_falseToken_reverts() public {
        FalseToken f = new FalseToken();
        vm.prank(poster);
        vm.expectRevert(AgentGig.TransferFailed.selector);
        gig.post(address(f), 1, DUR, "x");
    }

    function test_zeroRewardTask() public {
        uint256 id = _postBNB(0);
        _claimSubmit(id);
        vm.prank(poster);
        gig.release(id);
        (, AgentGig.Rep memory w) = gig.profile(worker);
        assertEq(w.completed, 1);
    }

    // ----------------------------------------------------------- Agent ID gating
    function test_post_requiresAgentID() public {
        vm.prank(stranger);
        vm.expectRevert(AgentGig.NotAgent.selector);
        gig.post{value: 1}(address(0), 1, DUR, "x");
    }

    function test_claim_requiresAgentID() public {
        uint256 id = _postBNB(1);
        vm.prank(stranger);
        vm.expectRevert(AgentGig.NotAgent.selector);
        gig.claim(id);
    }

    function test_cannotClaimOwnTask() public {
        uint256 id = _postBNB(1);
        vm.prank(poster);
        vm.expectRevert(AgentGig.SelfDeal.selector);
        gig.claim(id);
    }

    function test_eventsCarryHandles() public {
        vm.expectEmit(true, true, false, true);
        emit AgentGig.TaskPosted(0, poster, "poster", address(0), 5, uint64(block.timestamp) + DUR, "hello");
        vm.prank(poster);
        gig.post{value: 5}(address(0), 5, DUR, "hello");
        vm.expectEmit(true, true, false, true);
        emit AgentGig.TaskClaimed(0, worker, "worker");
        vm.prank(worker);
        gig.claim(0);
    }

    // ----------------------------------------------------------- input validation
    function test_post_validation() public {
        vm.startPrank(poster);
        vm.expectRevert(AgentGig.BadDuration.selector);
        gig.post(address(0), 0, 59 minutes, "x");
        vm.expectRevert(AgentGig.BadDuration.selector);
        gig.post(address(0), 0, 91 days, "x");
        vm.expectRevert(AgentGig.BadInput.selector);
        gig.post(address(0), 0, DUR, "");
        vm.expectRevert(AgentGig.BadInput.selector);
        gig.post(address(0), 0, DUR, string(new bytes(1025)));
        vm.expectRevert(AgentGig.BadInput.selector);
        gig.post{value: 2}(address(0), 1, DUR, "x"); // value mismatch
        vm.expectRevert(AgentGig.BadInput.selector);
        gig.post{value: 1}(address(usd), 1, DUR, "x"); // BNB sent with token task
        vm.expectRevert(AgentGig.BadInput.selector);
        gig.post(makeAddr("notAToken"), 1, DUR, "x");
        vm.stopPrank();
    }

    function test_badTaskId() public {
        vm.expectRevert(AgentGig.BadInput.selector);
        gig.getTask(0);
        vm.prank(worker);
        vm.expectRevert(AgentGig.BadInput.selector);
        gig.claim(7);
    }

    function test_submit_validation() public {
        uint256 id = _postBNB(1);
        vm.prank(worker);
        gig.claim(id);
        vm.startPrank(worker);
        vm.expectRevert(AgentGig.BadInput.selector);
        gig.submit(id, bytes32(0), "");
        vm.expectRevert(AgentGig.BadInput.selector);
        gig.submit(id, bytes32(0), string(new bytes(513)));
        gig.submit(id, bytes32(0), "https://gist.example/r"); // uri-only is fine
        vm.stopPrank();
    }

    // ----------------------------------------------------------- access control
    function test_onlyWorkerSubmits() public {
        uint256 id = _postBNB(1);
        vm.prank(worker);
        gig.claim(id);
        vm.prank(other);
        vm.expectRevert(AgentGig.NotWorker.selector);
        gig.submit(id, keccak256("x"), "");
    }

    function test_onlyPosterCancelsAndRejects() public {
        uint256 id = _postBNB(1);
        vm.prank(other);
        vm.expectRevert(AgentGig.NotPoster.selector);
        gig.cancel(id);
        _claimSubmit(id);
        vm.prank(worker);
        vm.expectRevert(AgentGig.NotPoster.selector);
        gig.reject(id, "no");
    }

    function test_releaseBeforeReviewOnlyPoster() public {
        uint256 id = _postBNB(1 ether);
        _claimSubmit(id);
        vm.prank(worker);
        vm.expectRevert(AgentGig.NotYet.selector);
        gig.release(id);
        vm.prank(stranger);
        vm.expectRevert(AgentGig.NotYet.selector);
        gig.release(id);
    }

    function test_autoReleaseAfterReviewWindow_byAnyone() public {
        uint256 id = _postBNB(1 ether);
        _claimSubmit(id);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(stranger);
        gig.release(id);
        assertEq(worker.balance, 1 ether);
    }

    // ----------------------------------------------------------- cancel paths
    function test_cancelOpen_refunds() public {
        uint256 id = _postBNB(1 ether);
        uint256 b = poster.balance;
        vm.prank(poster);
        gig.cancel(id);
        assertEq(poster.balance, b + 1 ether);
        vm.prank(worker);
        vm.expectRevert(AgentGig.BadStatus.selector);
        gig.claim(id);
    }

    function test_cancelClaimed_onlyAfterDeadline() public {
        uint256 id = _postBNB(1 ether);
        vm.prank(worker);
        gig.claim(id);
        vm.prank(poster);
        vm.expectRevert(AgentGig.NotYet.selector);
        gig.cancel(id);
        vm.warp(block.timestamp + DUR + 1);
        vm.prank(poster);
        gig.cancel(id);
        assertEq(address(gig).balance, 0);
    }

    function test_cannotCancelSubmitted() public {
        uint256 id = _postBNB(1 ether);
        _claimSubmit(id);
        vm.warp(block.timestamp + 30 days);
        vm.prank(poster);
        vm.expectRevert(AgentGig.BadStatus.selector);
        gig.cancel(id);
    }

    function test_noDoublePayOrRefund() public {
        uint256 id = _postBNB(1 ether);
        _claimSubmit(id);
        vm.prank(poster);
        gig.release(id);
        vm.prank(poster);
        vm.expectRevert(AgentGig.BadStatus.selector);
        gig.release(id);
        vm.prank(poster);
        vm.expectRevert(AgentGig.BadStatus.selector);
        gig.cancel(id);
    }

    // ----------------------------------------------------------- deadlines
    function test_claimAfterDeadlineFails() public {
        uint256 id = _postBNB(1);
        vm.warp(block.timestamp + DUR + 1);
        vm.prank(worker);
        vm.expectRevert(AgentGig.PastDeadline.selector);
        gig.claim(id);
    }

    function test_submitAfterDeadlineFails() public {
        uint256 id = _postBNB(1);
        vm.prank(worker);
        gig.claim(id);
        vm.warp(block.timestamp + DUR + 1);
        vm.prank(worker);
        vm.expectRevert(AgentGig.PastDeadline.selector);
        gig.submit(id, keccak256("x"), "");
    }

    // ----------------------------------------------------------- reject / resubmit
    function test_rejectOnce_thenMustRelease() public {
        uint256 id = _postBNB(1 ether);
        _claimSubmit(id);
        vm.warp(block.timestamp + DUR - 10); // near deadline
        vm.prank(poster);
        gig.reject(id, "missing chart");
        AgentGig.Task memory t = gig.getTask(id);
        assertEq(uint8(t.status), uint8(AgentGig.Status.Claimed));
        assertGe(t.deadline, block.timestamp + 1 days, "worker gets resubmit window");
        // worker can't hand it back after a rejection
        vm.prank(worker);
        vm.expectRevert(AgentGig.BadStatus.selector);
        gig.unclaim(id);
        vm.prank(worker);
        gig.submit(id, keccak256("v2"), "ipfs://v2");
        vm.prank(poster);
        vm.expectRevert(AgentGig.BadStatus.selector);
        gig.reject(id, "again");
        vm.warp(block.timestamp + 3 days + 1);
        gig.release(id);
        assertEq(worker.balance, 1 ether);
    }

    function test_rejectedWorkerGhosts_posterRefund() public {
        uint256 id = _postBNB(1 ether);
        _claimSubmit(id);
        vm.prank(poster);
        gig.reject(id, "wrong");
        vm.warp(gig.getTask(id).deadline + 1);
        vm.prank(poster);
        gig.cancel(id);
        assertEq(address(gig).balance, 0);
    }

    function test_unclaim_reopens() public {
        uint256 id = _postBNB(1);
        vm.prank(worker);
        gig.claim(id);
        vm.prank(other);
        vm.expectRevert(AgentGig.NotWorker.selector);
        gig.unclaim(id);
        vm.prank(worker);
        gig.unclaim(id);
        vm.prank(other);
        gig.claim(id);
        assertEq(gig.getTask(id).worker, other);
    }

    // ----------------------------------------------------------- ratings
    function test_rating_bothSidesOnce() public {
        uint256 id = _postBNB(1);
        vm.prank(poster);
        vm.expectRevert(AgentGig.BadStatus.selector);
        gig.rate(id, 5); // not paid yet
        _claimSubmit(id);
        vm.prank(poster);
        gig.release(id);
        vm.prank(poster);
        gig.rate(id, 5);
        vm.prank(worker);
        gig.rate(id, 4);
        vm.prank(poster);
        vm.expectRevert(AgentGig.AlreadyRated.selector);
        gig.rate(id, 1);
        vm.prank(other);
        vm.expectRevert(AgentGig.NotWorker.selector);
        gig.rate(id, 1);
        vm.prank(worker);
        vm.expectRevert(AgentGig.AlreadyRated.selector);
        gig.rate(id, 5);
        (, AgentGig.Rep memory w) = gig.profile(worker);
        (, AgentGig.Rep memory p) = gig.profile(poster);
        assertEq(w.ratingSum, 5);
        assertEq(p.ratingSum, 4);
        assertEq(w.ratings, 1);
    }

    function test_rating_bounds() public {
        uint256 id = _postBNB(0);
        _claimSubmit(id);
        vm.prank(poster);
        gig.release(id);
        vm.startPrank(poster);
        vm.expectRevert(AgentGig.BadInput.selector);
        gig.rate(id, 0);
        vm.expectRevert(AgentGig.BadInput.selector);
        gig.rate(id, 6);
        vm.stopPrank();
    }

    // ----------------------------------------------------------- payment robustness
    function test_revertingReceiver_creditsOwed() public {
        RevertingReceiver rr = new RevertingReceiver();
        reg.give(address(rr), "rr");
        uint256 id = _postBNB(1 ether);
        vm.prank(address(rr));
        gig.claim(id);
        vm.prank(address(rr));
        gig.submit(id, keccak256("x"), "");
        vm.prank(poster);
        gig.release(id); // must not brick
        assertEq(gig.owed(address(rr)), 1 ether);
        vm.prank(address(rr));
        vm.expectRevert(AgentGig.TransferFailed.selector);
        gig.withdraw();
        assertEq(gig.owed(address(rr)), 1 ether, "still owed after failed withdraw");
    }

    function test_withdraw_nothing() public {
        vm.expectRevert(AgentGig.BadInput.selector);
        gig.withdraw();
    }

    function test_reentrancyBlocked() public {
        Reenterer r = new Reenterer(IGig(address(gig)));
        reg.give(address(r), "reent");
        uint256 id = _postBNB(1 ether);
        r.setTarget(id);
        r.call(address(gig), abi.encodeCall(AgentGig.claim, (id)), 0);
        r.call(address(gig), abi.encodeCall(AgentGig.submit, (id, keccak256("x"), "")), 0);
        vm.prank(poster);
        gig.release(id);
        assertTrue(r.attempted());
        assertFalse(r.reentered());
        assertEq(address(r).balance, 1 ether);
        assertEq(address(gig).balance, 0);
    }

    function test_directBNBSendRejected() public {
        vm.prank(poster);
        (bool ok,) = address(gig).call{value: 1}("");
        assertFalse(ok, "no receive(): stray BNB can't get stuck");
    }

    // ----------------------------------------------------------- views
    function test_getTasks_paging() public {
        for (uint256 i; i < 5; i++) _postBNB(i);
        (uint256[] memory ids, AgentGig.Task[] memory ts) = gig.getTasks(0, 3);
        assertEq(ids.length, 3);
        assertEq(ids[0], 4);
        assertEq(ts[2].reward, 2);
        (ids,) = gig.getTasks(3, 10);
        assertEq(ids.length, 2);
        assertEq(ids[1], 0);
        (ids,) = gig.getTasks(9, 10);
        assertEq(ids.length, 0);
        assertEq(gig.taskCount(), 5);
    }

    function test_profile_nonHolder() public view {
        (string memory h,) = gig.profile(stranger);
        assertEq(bytes(h).length, 0);
        (h,) = gig.profile(worker);
        assertEq(h, "worker");
    }

    // ----------------------------------------------------------- fuzz
    function testFuzz_postAndSettle(uint96 amt, uint64 dur, bool releaseIt) public {
        dur = uint64(bound(dur, 1 hours, 90 days));
        vm.deal(poster, amt);
        vm.prank(poster);
        uint256 id = gig.post{value: amt}(address(0), amt, dur, "fuzz");
        if (releaseIt) {
            _claimSubmit(id);
            vm.prank(poster);
            gig.release(id);
            assertEq(worker.balance, amt);
        } else {
            vm.prank(poster);
            gig.cancel(id);
            assertEq(poster.balance, amt);
        }
        assertEq(address(gig).balance, 0);
    }

    function testFuzz_strangersCannotTouchEscrow(address who, uint8 action) public {
        vm.assume(who != poster && who != worker && who != address(0));
        uint256 id = _postBNB(1 ether);
        vm.prank(worker);
        gig.claim(id);
        vm.prank(worker);
        gig.submit(id, keccak256("x"), "");
        vm.startPrank(who);
        uint8 a = action % 3;
        if (a == 0) {
            vm.expectRevert();
            gig.release(id);
        } else if (a == 1) {
            vm.expectRevert(AgentGig.NotPoster.selector);
            gig.cancel(id);
        } else {
            vm.expectRevert(AgentGig.NotPoster.selector);
            gig.reject(id, "x");
        }
        vm.stopPrank();
        assertEq(address(gig).balance, 1 ether);
    }
}
