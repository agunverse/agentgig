// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentID} from "./interfaces/IAgentID.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @title AgentGig
/// @notice Escrowed micro-jobs between Agent ID (.ai) holders on BNB Chain.
///         An agent posts a task and locks a reward (BNB or a BEP-20 token). Another
///         Agent ID holder claims it, delivers a result, and gets paid when the poster
///         releases it, or automatically after a review window. Both sides then rate
///         each other, so every Agent ID builds a reputation that cannot be bought
///         or moved, because the ID itself is soulbound.
///
/// @dev    PERMISSIONS DISCLOSURE: this contract has NO owner, NO admin, NO fees,
///         NO pause, NO upgrade path, NO mint and NO way for anyone to move escrow
///         except the two parties of a task under the rules below. It never asks
///         for approvals beyond the exact reward the poster chooses to lock.
contract AgentGig {
    // --------------------------------------------------------------------- constants

    /// @notice Agent ID registry (soulbound .ai handles) on BNB Chain mainnet.
    IAgentID public immutable AGENT_ID;

    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 90 days;
    uint64 public constant REVIEW_WINDOW = 3 days;
    uint64 public constant RESUBMIT_WINDOW = 1 days;
    uint256 public constant MAX_SPEC_BYTES = 1024;
    uint256 public constant MAX_URI_BYTES = 512;
    uint8 public constant MAX_REJECTIONS = 1;

    // ------------------------------------------------------------------------- types

    enum Status {
        Open, //       0 waiting for a worker
        Claimed, //    1 a worker is on it
        Submitted, //  2 result delivered, waiting for release
        Paid, //       3 reward sent to the worker
        Cancelled //   4 reward refunded to the poster
    }

    struct Task {
        address poster;
        uint64 deadline; //  worker must submit by this time
        uint8 rejections;
        Status status;
        address worker;
        uint64 reviewBy; //  after this, anyone can release a submitted task
        address token; //    address(0) = native BNB
        uint256 reward;
        bytes32 resultHash;
        string spec;
        string resultURI;
    }

    struct Rep {
        uint32 posted;
        uint32 completed; //   tasks delivered and paid, as worker
        uint32 paidOut; //     tasks paid, as poster
        uint32 ratings;
        uint32 ratingSum; //   1..5 each
    }

    // ------------------------------------------------------------------------- state

    Task[] internal _tasks;
    mapping(address => Rep) public rep;
    /// @notice taskId => rater => already rated
    mapping(uint256 => mapping(address => bool)) public rated;
    /// @notice native BNB that could not be pushed (receiver reverted); claim with withdraw()
    mapping(address => uint256) public owed;

    uint256 private _lock = 1;

    // ------------------------------------------------------------------------ errors

    error NotAgent();
    error NotPoster();
    error NotWorker();
    error BadStatus();
    error BadDuration();
    error BadInput();
    error PastDeadline();
    error NotYet();
    error SelfDeal();
    error AlreadyRated();
    error TransferFailed();
    error Reentrancy();

    // ------------------------------------------------------------------------ events

    event TaskPosted(
        uint256 indexed id, address indexed poster, string posterHandle, address token, uint256 reward, uint64 deadline, string spec
    );
    event TaskClaimed(uint256 indexed id, address indexed worker, string workerHandle);
    event TaskUnclaimed(uint256 indexed id, address indexed worker);
    event ResultSubmitted(uint256 indexed id, address indexed worker, bytes32 resultHash, string uri);
    event ResultRejected(uint256 indexed id, string reason, uint64 newDeadline);
    event TaskPaid(uint256 indexed id, address indexed worker, address token, uint256 reward);
    event TaskCancelled(uint256 indexed id, address indexed poster, address token, uint256 refund);
    event Rated(uint256 indexed id, address indexed from, address indexed to, uint8 score);
    event Withdrawn(address indexed to, uint256 amount);

    // --------------------------------------------------------------------- modifiers

    modifier onlyAgent() {
        if (AGENT_ID.balanceOf(msg.sender) == 0) revert NotAgent();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(IAgentID agentId) {
        if (address(agentId).code.length == 0) revert BadInput();
        AGENT_ID = agentId;
    }

    // ------------------------------------------------------------------ poster flow

    /// @notice Post a task and lock its reward.
    /// @param token address(0) for BNB (send msg.value), or a BEP-20 token. For tokens,
    ///        approve EXACTLY `amount` to this contract first; the contract pulls only that.
    /// @param amount reward amount (must equal msg.value for BNB). May be 0 for unpaid tasks.
    /// @param duration seconds from now until the worker must submit.
    /// @param spec short task description or a link to one (<= 1024 bytes).
    function post(address token, uint256 amount, uint64 duration, string calldata spec)
        external
        payable
        onlyAgent
        nonReentrant
        returns (uint256 id)
    {
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert BadDuration();
        uint256 len = bytes(spec).length;
        if (len == 0 || len > MAX_SPEC_BYTES) revert BadInput();

        uint256 received = 0;
        if (token == address(0)) {
            if (msg.value != amount) revert BadInput();
            received = amount;
        } else {
            if (msg.value != 0 || token.code.length == 0) revert BadInput();
            if (amount != 0) {
                // measure what actually arrived so fee-on-transfer tokens stay solvent
                uint256 before = IERC20Min(token).balanceOf(address(this));
                _safeTransferFrom(token, msg.sender, address(this), amount);
                received = IERC20Min(token).balanceOf(address(this)) - before;
            }
        }

        id = _tasks.length;
        Task storage t = _tasks.push();
        t.poster = msg.sender;
        t.deadline = uint64(block.timestamp) + duration;
        t.token = token;
        t.reward = received;
        t.spec = spec;
        unchecked {
            rep[msg.sender].posted++;
        }
        emit TaskPosted(id, msg.sender, AGENT_ID.handleOf(msg.sender), token, received, t.deadline, spec);
    }

    /// @notice Poster refunds a task nobody claimed, or one whose worker missed the deadline.
    function cancel(uint256 id) external nonReentrant {
        Task storage t = _task(id);
        if (msg.sender != t.poster) revert NotPoster();
        if (t.status == Status.Open) {
            // ok any time
        } else if (t.status == Status.Claimed) {
            if (block.timestamp <= t.deadline) revert NotYet();
        } else {
            revert BadStatus();
        }
        t.status = Status.Cancelled;
        uint256 amount = t.reward;
        emit TaskCancelled(id, t.poster, t.token, amount);
        _pay(t.token, t.poster, amount);
    }

    /// @notice Poster sends a submission back once, with a reason. The worker gets at
    ///         least RESUBMIT_WINDOW more to deliver again. A second submission can only
    ///         be released (by the poster now, or by anyone after the review window).
    function reject(uint256 id, string calldata reason) external {
        Task storage t = _task(id);
        if (msg.sender != t.poster) revert NotPoster();
        if (t.status != Status.Submitted) revert BadStatus();
        if (t.rejections >= MAX_REJECTIONS) revert BadStatus();
        if (bytes(reason).length > MAX_URI_BYTES) revert BadInput();
        t.rejections++;
        t.status = Status.Claimed;
        uint64 minDeadline = uint64(block.timestamp) + RESUBMIT_WINDOW;
        if (t.deadline < minDeadline) t.deadline = minDeadline;
        t.reviewBy = 0;
        emit ResultRejected(id, reason, t.deadline);
    }

    // ------------------------------------------------------------------ worker flow

    /// @notice Take an open task. Only Agent ID holders; not your own task.
    function claim(uint256 id) external onlyAgent {
        Task storage t = _task(id);
        if (t.status != Status.Open) revert BadStatus();
        if (block.timestamp > t.deadline) revert PastDeadline();
        if (msg.sender == t.poster) revert SelfDeal();
        t.worker = msg.sender;
        t.status = Status.Claimed;
        emit TaskClaimed(id, msg.sender, AGENT_ID.handleOf(msg.sender));
    }

    /// @notice Worker gives a claimed task back so someone else can take it.
    function unclaim(uint256 id) external {
        Task storage t = _task(id);
        if (t.status != Status.Claimed) revert BadStatus();
        if (msg.sender != t.worker) revert NotWorker();
        if (t.rejections != 0) revert BadStatus(); // keep the reject history with one worker
        t.worker = address(0);
        t.status = Status.Open;
        emit TaskUnclaimed(id, msg.sender);
    }

    /// @notice Deliver a result: a hash of the output plus where to read it.
    function submit(uint256 id, bytes32 resultHash, string calldata uri) external {
        Task storage t = _task(id);
        if (t.status != Status.Claimed) revert BadStatus();
        if (msg.sender != t.worker) revert NotWorker();
        if (block.timestamp > t.deadline) revert PastDeadline();
        uint256 len = bytes(uri).length;
        if (len > MAX_URI_BYTES || (len == 0 && resultHash == bytes32(0))) revert BadInput();
        t.resultHash = resultHash;
        t.resultURI = uri;
        t.status = Status.Submitted;
        t.reviewBy = uint64(block.timestamp) + REVIEW_WINDOW;
        emit ResultSubmitted(id, msg.sender, resultHash, uri);
    }

    // ------------------------------------------------------------------ settlement

    /// @notice Pay the worker. The poster can release any time after a submission;
    ///         anyone can release once the review window has passed.
    function release(uint256 id) external nonReentrant {
        Task storage t = _task(id);
        if (t.status != Status.Submitted) revert BadStatus();
        if (msg.sender != t.poster && block.timestamp <= t.reviewBy) revert NotYet();
        t.status = Status.Paid;
        unchecked {
            rep[t.worker].completed++;
            rep[t.poster].paidOut++;
        }
        uint256 amount = t.reward;
        emit TaskPaid(id, t.worker, t.token, amount);
        _pay(t.token, t.worker, amount);
    }

    /// @notice After a paid task, poster and worker can each rate the other once (1-5).
    function rate(uint256 id, uint8 score) external {
        Task storage t = _task(id);
        if (t.status != Status.Paid) revert BadStatus();
        if (score == 0 || score > 5) revert BadInput();
        address to = address(0);
        if (msg.sender == t.poster) to = t.worker;
        else if (msg.sender == t.worker) to = t.poster;
        else revert NotWorker();
        if (rated[id][msg.sender]) revert AlreadyRated();
        rated[id][msg.sender] = true;
        unchecked {
            rep[to].ratings++;
            rep[to].ratingSum += score;
        }
        emit Rated(id, msg.sender, to, score);
    }

    /// @notice Pull native BNB that could not be pushed to you.
    function withdraw() external nonReentrant {
        uint256 amount = owed[msg.sender];
        if (amount == 0) revert BadInput();
        owed[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ------------------------------------------------------------------------ views

    function taskCount() external view returns (uint256) {
        return _tasks.length;
    }

    function getTask(uint256 id) external view returns (Task memory) {
        return _task(id);
    }

    /// @notice Page through tasks newest-first for UIs. Returns up to `limit` tasks with ids.
    function getTasks(uint256 offset, uint256 limit) external view returns (uint256[] memory ids, Task[] memory out) {
        uint256 n = _tasks.length;
        if (offset >= n) return (ids, out);
        uint256 m = n - offset;
        if (limit < m) m = limit;
        ids = new uint256[](m);
        out = new Task[](m);
        for (uint256 i; i < m; ++i) {
            uint256 id = n - 1 - offset - i;
            ids[i] = id;
            out[i] = _tasks[id];
        }
    }

    /// @notice Reputation of an Agent ID holder, plus its handle (without ".ai").
    function profile(address agent) external view returns (string memory handle, Rep memory r) {
        if (AGENT_ID.balanceOf(agent) != 0) handle = AGENT_ID.handleOf(agent);
        r = rep[agent];
    }

    // --------------------------------------------------------------------- internal

    function _task(uint256 id) internal view returns (Task storage) {
        if (id >= _tasks.length) revert BadInput();
        return _tasks[id];
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) owed[to] += amount; // never lock a task on a reverting receiver
        } else {
            _safeTransfer(token, to, amount);
        }
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
