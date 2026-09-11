// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review14ScheduleBase} from "./Review14_schedule_Base.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

/// Round-14 SCHEDULE lens, part 2: the `ScheduleFrozen` guard (945b735), the constructor's
/// "a life shorter than one round makes the lever inert" guard, and the fold's `_scheduleBlock`
/// clamp that `ScheduleFrozen` is supposed to make unreachable.
contract Review14ScheduleFrozen is Review14ScheduleBase {
    /// Does `setRoundParams` succeed at ANY block of the sale's life (and past it)?
    function _leverEverWorks(uint256 upTo) internal returns (bool ok, uint256 atBlock) {
        for (uint256 b = start; b <= upTo; ++b) {
            vm.roll(b);
            uint256 snap = vm.snapshotState();
            vm.prank(ADMIN);
            try auction.setRoundParams(7, 1e18) {
                vm.revertToState(snap);
                return (true, b);
            } catch {
                vm.revertToState(snap);
            }
        }
        return (false, 0);
    }

    /// BUG FORM. The constructor rejects `endBlock - startBlock < roundBlocks` because "a bounded
    /// life shorter than one round can never reach a round boundary, so the admin's one lever
    /// would be inert for the whole sale". EQUALITY is accepted -- and is just as inert: the only
    /// boundary the life contains is `startBlock + roundBlocks == endBlock`, and `ScheduleFrozen`
    /// refuses a boundary `>= endBlock`. Every call, at every block, forever.
    /// FIXED: a life of exactly one round is refused at deploy. It used to be accepted, and then
    /// `setRoundParams` was `ScheduleFrozen` at every block of the sale and forever after — the
    /// admin's only lever dead, with `admin` immutable and no recovery but a redeploy.
    function test_lifeOfExactlyOneRoundIsRefused() public {
        _freshMono();
        vm.expectRevert(IGenerousAuction.InvalidParams.selector);
        _deployOnly(uint64(block.number) + 100, 100, 100e18);
    }

    /// Control: one block more of life and the lever works from the very first block.
    function test_oneBlockMoreOfLifeAndTheLeverWorks() public {
        _freshMono();
        _deployOnly(uint64(block.number) + 101, 100, 100e18);
        (bool ok, uint256 at) = _leverEverWorks(uint256(life) + 500);
        emit log_named_uint("first block where setRoundParams succeeded", at);
        assertTrue(ok, "control failed");
        assertEq(at, start, "the lever should work immediately");
    }

    /// The exact frontier, fuzzed: the constructor's guard is `life < roundBlocks` but the real
    /// condition for a usable lever is `life > roundBlocks`.
    function testFuzz_leverIsUsableIffLifeExceedsOneRound(uint64 rawLen, uint64 rawExtra) public {
        uint64 len = uint64(bound(uint256(rawLen), 1, 50));
        uint64 extra = uint64(bound(uint256(rawExtra), 0, 3)); // life = len + extra
        _freshMono();
        if (extra == 0) {
            // The frontier is exactly `life > roundBlocks`, and the constructor now sits on it.
            vm.expectRevert(IGenerousAuction.InvalidParams.selector);
            _deployOnly(uint64(block.number) + len + extra, len, 100e18);
            return;
        }
        _deployOnly(uint64(block.number) + len + extra, len, 100e18);
        (bool ok,) = _leverEverWorks(uint256(life) + 4 * uint256(len) + 10);
        assertTrue(ok, "an accepted life must leave the lever usable");
    }

    /// CHARACTERISATION. `ScheduleFrozen` really does keep `pendingFrom` strictly under
    /// `endBlock`, so the `_scheduleBlock(from)` clamp inside the fold is dead code. Driven here
    /// by calling at EVERY block of a two-round life with every length that fits.
    function test_foldClampIsUnreachable_pendingFromNeverReachesEndBlock() public {
        uint256 accepted;
        uint256 refused;
        for (uint64 len = 1; len <= 6; ++len) {
            for (uint64 span = len + 1; span <= 18; ++span) {
                _freshMono();
                _deployOnly(uint64(block.number) + span, len, 10e18);
                for (uint256 b = start; b <= uint256(life) + 5; ++b) {
                    vm.roll(b);
                    vm.prank(ADMIN);
                    try auction.setRoundParams(len == 1 ? 2 : 1, 5e18) {
                        accepted++;
                        uint64 from = auction.pendingFrom();
                        assertLt(from, life, "pendingFrom reached endBlock -- the fold clamp is LIVE");
                        assertGt(from, b, "pendingFrom in the past");
                        assertEq(
                            (uint256(from) - _anchorBlock()) % auction.roundBlocks(), 0, "boundary is not a whole round"
                        );
                    } catch {
                        refused++;
                    }
                }
            }
        }
        emit log_named_uint("accepted queues", accepted);
        emit log_named_uint("ScheduleFrozen refusals", refused);
        assertGt(accepted, 0, "drove no accepted queue at all");
        assertGt(refused, 0, "drove no refusal at all");
    }

    /// A queue that is already EFFECTIVE but never folded, with `ScheduleFrozen` now refusing
    /// every further call: the count and the emission must still track it without an admin fold.
    function test_effectiveButUnfoldableGenerationStillCounts() public {
        _freshMono();
        _deployOnly(uint64(block.number) + 400, 100, 100e18);
        vm.roll(start + 10);
        vm.prank(ADMIN);
        auction.setRoundParams(50, 20e18); // effective at start+100, boundary 100 < 400
        assertEq(auction.pendingFrom(), start + 100, "boundary");

        vm.roll(start + 350);
        // Every further call is frozen: next boundary would be start+400 == endBlock.
        vm.prank(ADMIN);
        vm.expectRevert(IGenerousAuction.ScheduleFrozen.selector);
        auction.setRoundParams(10, 1e18);

        assertEq(_anchorRounds(), 0, "nothing was ever folded");
        // 1 round of 100 + 5 rounds of 50 = 6.
        assertEq(auction.roundsElapsed(), 6, "unfolded generation not counted");
        // 100e18 + 250 * 20e18/50 = 100e18 + 100e18.
        assertEq(auction.emittedToDate(), 200e18, "unfolded generation not accrued");

        vm.roll(uint256(life) + 100_000);
        assertEq(auction.roundsElapsed(), 1 + 300 / 50, "count not frozen at endBlock");
        assertEq(auction.emittedToDate(), 100e18 + (300 * 20e18) / 50, "emission not frozen at endBlock");
    }
}
