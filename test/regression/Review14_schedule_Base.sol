// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review-14 SCHEDULE lens. Harness plus an INDEPENDENT replay model of the emission schedule
/// that knows nothing about `anchorBlock` / `anchorRounds` / `pendingFrom`: it keeps the list of
/// generations `(fromBlock, roundBlocks, emissionPerRound)` that actually ran and integrates it.
abstract contract Review14ScheduleBase is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;
    MockPool internal pool;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    address internal constant ADMIN = address(0xF1);

    // storage layout (forge inspect): slot 14 = anchorBlock|anchorEmitted|roundBlocks,
    //                                 slot 16 = pendingEmission|anchorRounds
    uint256 internal constant SLOT_ANCHOR = 14;
    uint256 internal constant SLOT_PEND2 = 16;

    uint64 internal start;
    uint64 internal life; // endBlock, 0 = open

    // ---- the model ----------------------------------------------------------------
    struct Gen {
        uint256 from;
        uint256 len;
        uint256 rate;
    }

    Gen[] internal gens;

    function _freshMono() internal {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));
    }

    function _deploy(uint64 endBlock_, uint64 roundBlocks_, uint128 emission_) internal {
        _freshMono();
        _deployOnly(endBlock_, roundBlocks_, emission_);
    }

    function _deployOnly(uint64 endBlock_, uint64 roundBlocks_, uint128 emission_) internal {
        start = uint64(block.number);
        life = endBlock_;
        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: ADMIN,
                floorPrice: 1e18,
                tickSpacing: 1e16,
                decayQ: HALF,
                windowTicks: 8,
                startBlock: start,
                endBlock: endBlock_,
                roundBlocks: roundBlocks_,
                emissionPerRound: emission_,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
        delete gens;
        gens.push(Gen({from: start, len: roundBlocks_, rate: emission_}));
    }

    /// Mirror of what `setRoundParams` promises: the round in flight finishes under the rate it
    /// started with, so the new generation begins at the strictly-next boundary of the generation
    /// running right now. A queue that has not taken effect yet is simply replaced.
    function _modelQueue(uint256 b, uint256 len, uint256 rate) internal {
        uint256 n = gens.length;
        if (n > 1 && gens[n - 1].from > b) {
            gens.pop(); // the previous queue never took effect; it is overwritten
            n--;
        }
        Gen memory c = gens[n - 1];
        uint256 elapsed = b > c.from ? (b - c.from) / c.len : 0;
        gens.push(Gen({from: c.from + (elapsed + 1) * c.len, len: len, rate: rate}));
    }

    function _clampT(uint256 b) internal view returns (uint256) {
        return (life != 0 && b > life) ? life : b;
    }

    function _modelRounds(uint256 b) internal view returns (uint256 done) {
        uint256 t = _clampT(b);
        for (uint256 i; i < gens.length; ++i) {
            if (t <= gens[i].from) break;
            uint256 upTo = (i + 1 < gens.length && gens[i + 1].from < t) ? gens[i + 1].from : t;
            done += (upTo - gens[i].from) / gens[i].len;
        }
    }

    function _modelEmitted(uint256 b) internal view returns (uint256 e) {
        uint256 t = _clampT(b);
        for (uint256 i; i < gens.length; ++i) {
            if (t <= gens[i].from) break;
            uint256 upTo = (i + 1 < gens.length && gens[i + 1].from < t) ? gens[i + 1].from : t;
            e += ((upTo - gens[i].from) * gens[i].rate) / gens[i].len;
        }
    }

    // ---- raw storage readers for the internal anchor -------------------------------
    function _anchorBlock() internal view returns (uint64) {
        return uint64(uint256(vm.load(address(auction), bytes32(SLOT_ANCHOR))));
    }

    function _anchorEmitted() internal view returns (uint128) {
        return uint128(uint256(vm.load(address(auction), bytes32(SLOT_ANCHOR))) >> 64);
    }

    function _anchorRounds() internal view returns (uint64) {
        return uint64(uint256(vm.load(address(auction), bytes32(SLOT_PEND2))) >> 128);
    }

    /// The 8 bytes above `anchorRounds` in its slot must stay zero: nothing else lives there.
    function _slot16Top() internal view returns (uint64) {
        return uint64(uint256(vm.load(address(auction), bytes32(SLOT_PEND2))) >> 192);
    }
}
