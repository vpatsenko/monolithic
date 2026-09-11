// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {GenerousAuction} from "../src/GenerousAuction.sol";
import {MockIndex} from "../src/MockIndex.sol";

/// @notice Drives one bid through a full cycle on a live deployment: approve, bid, sync, claim.
///         Proves the schedule, the tick book and the payout path all work on-chain, which a
///         deploy transcript alone does not.
/// @dev Three entrypoints, run in order and a round apart:
///
///          forge script script/SmokeTest.s.sol --tc SmokeTest --sig 'bid()'    --rpc-url chain46630 --broadcast
///          forge script script/SmokeTest.s.sol --tc SmokeTest --sig 'settle()' --rpc-url chain46630 --broadcast
///          forge script script/SmokeTest.s.sol --tc SmokeTest --sig 'report()' --rpc-url chain46630
///
///      ponytail: addresses hardcoded from `deployments/46630.json`. This is a one-shot bring-up
///      check against one deployment, not a test harness — the real suite is `test/`.
contract SmokeTest is Script {
    GenerousAuction internal constant AUCTION = GenerousAuction(0xC8e7a71225E4D01d6079c439D0bb2F8F73E3688E);
    MockIndex internal constant MONO = MockIndex(0x8B389fdc3D19E9551106518f07451827AFa9266A);
    MockIndex internal constant INDEX = MockIndex(0x3a6Ff23D4f0Ae2E15499Dc198913e352965c8784);

    /// @dev At the floor tick, so `prevTick` is 0 and no traversal is needed.
    uint256 internal constant PRICE = 1e18;
    uint128 internal constant BID = 100e18;
    /// @dev Escrow without stake buys nothing (the strict rule), so the bid needs a stake first.
    uint256 internal constant STAKE = 1e18;

    function bid() external {
        uint256 pk = vm.envUint("WALLET_PRIVATE_KEY");
        address me = vm.addr(pk);
        // `submitBid` requires `owner == msg.sender`, so the owner IS the broadcasting key —
        // deriving it here rather than reading a second env removes a silent way to get
        // `Unauthorized` from two settings that disagree.
        require(me == vm.envAddress("WALLET_ADDRESS"), "WALLET_ADDRESS is not WALLET_PRIVATE_KEY's address");

        vm.startBroadcast(pk);
        MONO.approve(address(AUCTION), STAKE);
        AUCTION.stake(STAKE);
        INDEX.approve(address(AUCTION), BID);
        AUCTION.submitBid(PRICE, BID, me, 0);
        vm.stopBroadcast();

        _report(me);
    }

    function settle() external {
        address me = vm.envAddress("WALLET_ADDRESS");
        uint256 before = MONO.balanceOf(me);

        vm.startBroadcast(vm.envUint("WALLET_PRIVATE_KEY"));
        AUCTION.sync(64);
        uint256 got = AUCTION.claim(me);
        vm.stopBroadcast();

        console.log("claim returned  :", got);
        console.log("MONO delta      :", MONO.balanceOf(me) - before);
        _report(me);
    }

    function report() external {
        _report(vm.envAddress("WALLET_ADDRESS"));
    }

    function _report(address me) internal view {
        (, uint128 amount, uint128 tokensOwed,,,,) = AUCTION.positions(me);

        console.log("--- auction ---");
        console.log("emittedToDate   :", AUCTION.emittedToDate());
        console.log("due             :", AUCTION.due());
        console.log("tokensSold      :", AUCTION.tokensSold());
        console.log("currencyRaised  :", AUCTION.currencyRaised());
        console.log("highestTick     :", AUCTION.highestTick());
        console.log("--- position @ floor ---");
        console.log("escrow at entry :", amount);
        console.log("tokensOwed      :", tokensOwed);
        console.log("--- wallet ---");
        console.log("MONO            :", MONO.balanceOf(me));
        console.log("INDEX           :", INDEX.balanceOf(me));
    }
}
