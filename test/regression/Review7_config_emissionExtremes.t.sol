// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";

interface IMonoLike {
    function premiumCloseAmount() external view returns (uint256);
}

/// Emission-schedule extremes the constructor accepts (src/GenerousAuction.sol L216: only
/// `roundBlocks` is bounded; `emissionPerRound` is never checked, L274).
///
/// (a) `emissionPerRound == 0` is accepted: the sale is inert until `admin` acts - bidders
///     escrow and stake into a book that owes nothing. Low, but a one-line guard.
/// (b) NEGATIVE RESULT, asked for by the lens: a per-block rate under 1 wei does NOT floor to zero
///     forever - `_accrue` (L342-348) is the closed form `(until - from) * R / K`, so R = 1,
///     K = 10_000 accrues exactly 1 wei every 10_000 blocks. Nobody is starved by flooring.
/// (c) `emissionPerRound = type(uint128).max` (the natural "as fast as the cap allows" sentinel -
///     `due()` clamps at `saleSupply` so the sale itself works) is accepted, but the fold in
///     `setRoundParams` (L361-370) stores cumulative emission in a uint128 `anchorEmitted` and
///     reverts `InvalidParams` when it does not fit. After ONE queued change lands, every later
///     `setRoundParams` reverts forever: the admin's only lever is gone. Guard:
///     `emissionPerRound <= saleSupply` (or fold with the `saleSupply` clamp applied).
contract Review7ConfigEmissionExtremes is Review7ConfigBase {
    function _deployRK(uint128 r, uint64 k, uint64 end) internal {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.emissionPerRound = r;
        c.roundBlocks = k;
        c.endBlock = end;
        _deployWith(c);
    }

    // ---------------------------------------------------------------- (a) zero emission

    /// Zero is LEGAL by design: the documented dormant-deploy pattern (ship at rate 0, start
    /// later with `setRoundParams`, no carry accrues in the gap — `test_zeroEmissionThenStart`).
    function test_zeroEmission_dormantDeployIsLegal() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.emissionPerRound = 0;
        GenerousAuction a = new GenerousAuction(c);
        assertEq(a.emissionPerRound(), 0);
    }

    function test_zeroEmission_inertSale() public {
        _deployRK(0, 100, 0);
        _stakeFor(aa, 1e18);
        _bid(aa, 1e18, 1000e18, 1e18);
        vm.roll(block.number + 100_000);
        auction.sync(64);
        assertEq(auction.due(), 0, "nothing ever owed");
        assertEq(_owed(aa), 0, "nothing ever accrues");
        assertEq(auction.tokensSold(), 0);
    }

    // ---------------------------------------------------------------- (b) sub-wei per block

    /// R = 1 wei / K = 10_000 blocks: 1e-4 wei per block, and it still accrues (closed form).
    function test_subWeiPerBlock_doesNotFloorToZeroForever() public {
        _deployRK(1, 10_000, 0);
        vm.roll(block.number + 9_999);
        assertEq(auction.emittedToDate(), 0, "under one round: 0 (linear, floored once)");
        vm.roll(block.number + 1);
        assertEq(auction.emittedToDate(), 1, "one wei at exactly one round");
        vm.roll(block.number + 1_000_000);
        assertEq(auction.emittedToDate(), 101, "and 1 wei per 10k blocks thereafter - never stuck");
    }

    /// Per-sync flooring inside the window: with R = 1 wei / K = 1 block, synced EVERY block, two
    /// equal stakers one tick apart. Expected from the q-split: top 2/3, floor 1/3. Measured: the
    /// carry sticks at 1 wei (supply per sync = 2), `_pour` floors the floor tick's 2/3 to 0 on
    /// every sync, and the top takes every wei. The lower tick NEVER accrues at this cadence.
    /// Same book synced once per 200 blocks: the split is the q-split. So at dust emission the
    /// allocation is decided by whoever calls `sync` (permissionless, ~30k gas) - not by q.
    function test_oneWeiPerBlock_syncCadenceDecidesTheSplit() public {
        // Cadence A: every block.
        _deployRK(1, 1, 0);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, 1e18, 1000e18, 1e18);
        _bid(bb, 1e18 + 1e16, 1000e18, 1e18);
        for (uint256 i; i < 200; ++i) {
            vm.roll(block.number + 1);
            auction.sync(64);
        }
        emit log_named_uint("every-block cadence: tokensSold", auction.tokensSold());
        emit log_named_uint("every-block cadence: floor owed", _owed(aa));
        emit log_named_uint("every-block cadence: top owed", _owed(bb));
        emit log_named_uint("every-block cadence: carry", auction.due());
        assertEq(_owed(aa), 0, "floor tick starved at every-block cadence");
        assertEq(_owed(bb), 199, "top took everything");

        // Cadence B: once, after 200 blocks.
        _deployRK(1, 1, 0);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, 1e18, 1000e18, 1e18);
        _bid(bb, 1e18 + 1e16, 1000e18, 1e18);
        vm.roll(block.number + 200);
        auction.sync(64);
        emit log_named_uint("one-shot cadence: floor owed", _owed(aa));
        emit log_named_uint("one-shot cadence: top owed", _owed(bb));
        assertApproxEqAbs(_owed(aa), 66, 2, "one-shot: floor gets its 1/3");
        assertApproxEqAbs(_owed(bb), 133, 2, "one-shot: top gets its 2/3");
    }

    // ---------------------------------------------------------------- (c) uint128.max sentinel

    /// A rate above the sale's size is rejected at deploy and in `setRoundParams`: it is
    /// economically `saleSupply` anyway and used to overflow the uint128 fold.
    function test_emissionAboveSaleSupplyIsRejected() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.emissionPerRound = type(uint128).max;
        vm.expectRevert(IGenerousAuction.InvalidParams.selector);
        new GenerousAuction(c);

        _deployRK(100e18, 100, 0);
        uint128 tooMuch = uint128(auction.saleSupply() + 1);
        vm.prank(address(0xF1));
        vm.expectRevert(IGenerousAuction.InvalidParams.selector);
        auction.setRoundParams(100, tooMuch);
    }

    /// The legitimate "everything at once" sentinel is `saleSupply` per block, and the admin can
    /// reschedule again and again after it has landed.
    function test_saleSupplySentinel_adminCanRescheduleRepeatedly() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.emissionPerRound = uint128(IMonoLike(address(mono)).premiumCloseAmount());
        c.roundBlocks = 1;
        _deployWith(c);
        vm.roll(block.number + 1);
        assertEq(auction.due(), auction.saleSupply(), "sentinel: everything due at once, as intended");

        vm.prank(address(0xF1));
        auction.setRoundParams(100, 100e18);
        vm.roll(auction.pendingFrom() + 1);
        vm.prank(address(0xF1));
        auction.setRoundParams(100, 50e18); // folds the sentinel generation, clamped at saleSupply
        assertEq(auction.pendingEmission(), 50e18, "second reschedule queued");
        vm.roll(auction.pendingFrom() + 1);
        vm.prank(address(0xF1));
        auction.setRoundParams(1, 1);
        assertEq(auction.pendingEmission(), 1, "third reschedule queued");
    }
}
