// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AgentGig} from "../src/AgentGig.sol";
import {IAgentID} from "../src/interfaces/IAgentID.sol";

/// forge script script/Deploy.s.sol --rpc-url $BSC_RPC_URL --private-key $TESTNET_WALLET_PK --broadcast
contract Deploy is Script {
    IAgentID constant REGISTRY = IAgentID(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F);

    function run() external returns (AgentGig gig) {
        require(block.chainid == 56, "not BNB Chain mainnet");
        require(address(REGISTRY).code.length > 0, "registry missing");
        vm.startBroadcast();
        gig = new AgentGig(REGISTRY);
        vm.stopBroadcast();
        require(address(gig.AGENT_ID()) == address(REGISTRY), "bad wiring");
        console2.log("AgentGig deployed at", address(gig));
    }
}
