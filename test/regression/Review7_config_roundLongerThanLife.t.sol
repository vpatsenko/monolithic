// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";

/// HAZARD: `roundBlocks` may be anything up to uint32.max (src/GenerousAuction.sol L216) and
/// `endBlock` need only exceed `startBlock` (L223). A bounded sale whose life is SHORTER than one
/// round is accepted. Consequences, all from `setRoundParams` (L349-384) + `_emittedAt`
/// (L322-337):
///   - the next boundary is `startBlock + roundBlocks > endBlock`, `_scheduleBlock` clamps every
///     read at `endBlock`, so `pendingFrom` is never reached: the admin's ONLY power - pacing -
///     is inert for the whole life of the sale, while `RoundParamsQueued` is emitted as if the
///     change were coming;
///   - `roundsElapsed()` reads 0 forever;
///   - the sale emits the pro-rata fraction `life / roundBlocks` of ONE round and nothing else.
/// The guard: `endBlock == 0 || endBlock - startBlock >= roundBlocks`.
contract Review7ConfigRoundLongerThanLife is Review7ConfigBase {
    function _deployShortLife() internal {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.roundBlocks = 10_000;
        c.emissionPerRound = 100e18;
        c.endBlock = uint64(block.number + 5_000);
        _deployWith(c);
    }

    /// A bounded life shorter than one round is rejected at deploy: the admin's reschedule could
    /// never take effect inside it.
    function test_lifeShorterThanOneRoundIsRejected() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.roundBlocks = 10_000;
        c.emissionPerRound = 100e18;
        c.endBlock = uint64(block.number + 5_000);
        vm.expectRevert(IGenerousAuction.InvalidParams.selector);
        new GenerousAuction(c);
    }

    /// Mid-sale, a reschedule whose boundary would land at or past `endBlock` reverts
    /// `ScheduleFrozen` instead of queueing an inert generation and emitting its event.
    function test_rescheduleIntoTheFrozenTailReverts() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.roundBlocks = 100;
        c.endBlock = uint64(block.number + 200); // exactly two rounds
        _deployWith(c);

        // First round: the next boundary (start + 100) is inside the life.
        vm.roll(block.number + 10);
        vm.prank(address(0xF1));
        auction.setRoundParams(100, 50e18);
        assertEq(auction.pendingFrom(), auction.endBlock() - 100, "queued for the boundary inside the life");

        // Last round: the next boundary IS endBlock, where the schedule is frozen.
        vm.roll(auction.endBlock() - 50);
        vm.prank(address(0xF1));
        vm.expectRevert(IGenerousAuction.ScheduleFrozen.selector);
        auction.setRoundParams(1, 1e18);
        assertEq(auction.pendingFrom(), auction.endBlock() - 100, "nothing new was queued");
    }

    /// Past the end every reschedule reverts and the frozen schedule stays frozen.
    function test_rescheduleAfterTheEndReverts() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.roundBlocks = 100;
        c.endBlock = uint64(block.number + 150); // one and a half rounds
        _deployWith(c);
        vm.roll(auction.endBlock() + 100);
        assertEq(auction.emittedToDate(), 150e18, "block-linear: the exact pro-rata tail");
        vm.prank(address(0xF1));
        vm.expectRevert(IGenerousAuction.ScheduleFrozen.selector);
        auction.setRoundParams(1, 1e18);
        assertEq(auction.emittedToDate(), 150e18, "unchanged");
    }
}
