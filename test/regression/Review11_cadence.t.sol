// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

contract Review11Cadence is Review7ConfigBase {
    // Pinned counterexample from the exploratory fuzz run; independent of the fuzz seed.
    uint256 internal constant BOOK_SEED = 140653879380060612168287087802739575806369689966206822431409354204410;

    /// EXACT `q` (a power of one half) is cadence-exact to integer dust: every `q^d` the band
    /// re-anchoring composes is exact, so one lazy solve and one solve per block agree to the
    /// floors alone.
    function test_binaryQStaysWithinCadencePrecisionBudget() public {
        (uint256 worst, uint256 poured, uint256 blocks) = _compareCadence(BOOK_SEED, Q96 / 2);
        assertLe(worst, 96 * blocks * 10, "exact q must be cadence-exact to integer dust");
        assertLt(worst, 1_000, "and in fact to a few hundred wei");
        poured;
    }

    /// INEXACT `q` carries a relative error instead. `_extend` weighs a newcomer against the
    /// band's CURRENT top (`wTop * q^d`), so across a sweep that moves the band many times the
    /// weights compose as a product of rounded powers rather than one exact power; each `rpow`
    /// and each `_rescale` contributes about 2^-96 of relative error and the band's weight range
    /// (here `q^64`, fourteen orders of magnitude) amplifies it. The deviation is therefore
    /// measured against what was POURED, not against an integer-dust budget: it stays under one
    /// part per billion, i.e. a nanoMONO on a 185 MONO pour. Characterisation, not a defect —
    /// the docstring's "N*R in one sweep lands where N sweeps of R would" is exact only for an
    /// exact `q` (round-11; see agent-docs "Bounded window").
    function test_nonBinaryQCadenceErrorIsRelativeAndNegligible() public {
        (uint256 worst, uint256 poured,) = _compareCadence(BOOK_SEED, Q96 * 6 / 10);
        emit log_named_uint("poured over the run (token wei)", poured);
        emit log_named_uint("worst deviation, parts per 1e18 of the pour", worst * 1e18 / poured);
        assertLe(worst * 1e9, poured, "cadence deviation exceeds one part per billion of the pour");
    }

    function _compareCadence(uint256 seed, uint256 q)
        internal
        returns (uint256 worst, uint256 poured, uint256 elapsed)
    {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.decayQ = q;
        c.windowTicks = 64;
        _deployWith(c);
        address[] memory users = new address[](96);
        uint256 total;
        for (uint256 i; i < users.length; ++i) {
            users[i] = address(uint160(0x33000 + i));
            uint256 capacity = 1e18 + uint256(keccak256(abi.encode(seed, i))) % 2e18;
            uint256 price = 1e18 + i * 1e16;
            uint128 amount = uint128((capacity * price + 1e18 - 1) / 1e18);
            _stakeFor(users[i], 1e18);
            _bid(users[i], price, amount, i == 0 ? 1e18 : price - 1e16);
            total += uint256(amount) * 1e18 / price;
        }
        uint256 blocks = total * 97 / 100 / 1e18;
        uint256 start = block.number;
        uint256 snapshot = vm.snapshotState();
        vm.roll(start + blocks);
        auction.sync(10_000);
        assertEq(auction.settleCursor(), 0, "control: lazy solve did not hit a settlement budget");
        uint256[] memory lazy = new uint256[](users.length);
        for (uint256 i; i < users.length; ++i) {
            lazy[i] = _owed(users[i]);
        }
        assertTrue(vm.revertToState(snapshot));
        for (uint256 i = 1; i <= blocks; ++i) {
            vm.roll(start + i);
            auction.sync(10_000);
            assertEq(auction.settleCursor(), 0, "control: frequent solve did not hit a settlement budget");
        }
        for (uint256 i; i < users.length; ++i) {
            uint256 frequent = _owed(users[i]);
            uint256 diff = frequent > lazy[i] ? frequent - lazy[i] : lazy[i] - frequent;
            if (diff > worst) worst = diff;
        }
        emit log_named_uint("q (Q96)", c.decayQ);
        emit log_named_uint("elapsed blocks", blocks);
        emit log_named_uint("worst allocation difference (token wei)", worst);
        poured = auction.tokensSold();
        elapsed = blocks;
    }
}
