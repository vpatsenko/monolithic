// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

contract Review12EmissionModel is Review7ConfigBase {
    struct Model {
        uint256 start;
        uint256 k;
        uint256 r;
        uint256 next;
        uint256 pendingK;
        uint256 pendingR;
        uint256 emitted;
    }

    // Accrue one block at a time, including fractional-wei schedules. Unlike the
    // contract's lazy anchor fold, the model eagerly adopts each boundary as it passes.
    function testFuzz_reschedulingMatchesEagerBlockModel(uint256 seed) public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.admin = address(this);
        c.roundBlocks = 7;
        c.emissionPerRound = 13;
        _deployWith(c);
        Model memory m = Model(c.startBlock, 7, 13, 0, 0, 0, 0);
        for (uint256 step = 1; step <= 300; ++step) {
            uint256 t = uint256(c.startBlock) + step;
            vm.roll(t);
            uint256 age = t - m.start;
            m.emitted += age * m.r / m.k - (age - 1) * m.r / m.k;
            if (t == m.next) {
                m.start = t;
                m.k = m.pendingK;
                m.r = m.pendingR;
                m.next = 0;
            }
            assertEq(auction.emittedToDate(), m.emitted, "lazy schedule disagrees with per-block accrual");
            uint256 random = uint256(keccak256(abi.encode(seed, step)));
            if (random % 3 == 0) {
                uint64 k = uint64(1 + (random >> 8) % 37);
                uint128 r = uint128((random >> 32) % 201); // includes zero and sub-wei/block
                auction.setRoundParams(k, r);
                m.next = m.start + ((t - m.start) / m.k + 1) * m.k;
                m.pendingK = k;
                m.pendingR = r;
                assertEq(auction.pendingFrom(), m.next, "new schedule uses the wrong boundary");
                assertEq(auction.emittedToDate(), m.emitted, "admin call rewrote prior emission");
            }
        }
    }
}
