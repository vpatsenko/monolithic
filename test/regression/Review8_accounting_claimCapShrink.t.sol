// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Review8AccountingBase} from "./Review8_accounting_Base.sol";

/// Review 8, accounting lens. `_claim` harvests (L1447) WITHOUT re-seating: `_harvest` rewrites
/// `p.amount -= ceil(eaten * price / WAD)` and re-anchors `accAtEntry`, but `p.kappa` and the
/// tick's `capTokens` stay as they were seated. At a non-integral price the position's REAL
/// remaining capacity `floor(amount' * WAD / price)` can be one token-wei below the model's
/// `cap - eaten` (the ceil charge ate part of a token's worth of escrow). Every path that
/// re-weighs a position (`stake`/`unstake`/`submitBid`/`claimAndStake`) heals this through
/// `_reseat`; a plain `claim` does not. The pour then hands the tick a token-wei nobody can
/// crystallise: `tokensBooked`/`tokensUnclaimed` take it (single seat: no reserve, L1153-1157)
/// and `currencyRaised` charges `price` for it — escrow that was never debited from anyone.
/// That is exactly the round-7 #3 shape the (seats-1) reserve was added against, reached from
/// a different site: it is a per-CLAIM leak, not a per-seat one, so the reserve does not cover
/// the one-seat tick — the most common tick shape there is.
contract Review8AccountingClaimCapShrinkTest is Review8AccountingBase {
    address internal aa = address(0xA1);

    // 9999.99 INDEX/MONO: on the 1e16 grid, under MAX_PRICE_MULTIPLE * floor (1e22).
    uint256 internal constant P = 999_999 * 1e16;
    // 999,999 wei of escrow buys exactly 100 token-wei at P (999999 / 9999.99 == 100).
    uint128 internal constant ESCROW = 999_999;

    function setUp() public {
        // 1 wei per round: each pour is one token-wei, so the harvest cadence is the pour cadence.
        _deploy(1, 0);
    }

    function _roundAndClaim() internal returns (uint256 got) {
        vm.roll(block.number + K);
        got = auction.claim(aa);
    }

    /// Deterministic: stake 2^60 (so the per-pour ceil step on `acc` is exact and the model's
    /// last segment lands on kappa). One bidder, one tick, 100 token-wei of capacity, claim after
    /// every 1-wei pour. The FIRST claim shrinks the cap: escrow 999,999 -> 989,999 buys 98, not
    /// 99. The model still pours 100. The pot books and charges for a wei nobody can claim.
    function test_singleSeat_claimShrink_currencyDeficit() public {
        _stakeFor(aa, 1 << 60);
        _bid(aa, P, ESCROW);
        address[] memory owners = new address[](1);
        owners[0] = aa;

        uint256 got1 = _roundAndClaim();
        assertEq(got1, 1, "first pour: 1 token-wei");
        (, uint128 amt,,,,,) = auction.positions(aa);
        assertEq(amt, 999_999 - 10_000, "charged ceil(9999.99) = 10000");
        // The seat still says 99 remain (kappa untouched); the escrow only buys 98.
        assertEq(amt * 1e18 / P, 98, "real remaining capacity after the claim");
        (,, uint256 capTokens,,,,) = auction.ticks(P);
        assertEq(capTokens, 98, "model (tick) capacity after the claim follows the real one");

        uint256 claimed = got1;
        for (uint256 r = 2; r <= 100; ++r) {
            claimed += _roundAndClaim();
        }
        (,, capTokens,,,,) = auction.ticks(P);
        emit log_named_uint("tokensSold", auction.tokensSold());
        emit log_named_uint("tokensBooked", auction.tokensBooked());
        emit log_named_uint("tokensMinted", auction.tokensMinted());
        emit log_named_uint("claimed by the only bidder", claimed);
        emit log_named_uint("tokensUnclaimed left (phantom, nobody can claim it)", auction.tokensUnclaimed());
        emit log_named_uint("tick capTokens at the end", capTokens);
        emit log_named_uint("currencyRaised", auction.currencyRaised());
        emit log_named_uint("escrow actually debited", ESCROW - amt);
        {
            (, uint128 amt2,,,,,) = auction.positions(aa);
            emit log_named_uint("bidder's residual live escrow", amt2);
            emit log_named_uint("INDEX the contract holds", cur.balanceOf(address(auction)));
        }
        emit log_named_int("coverage: held - live - unpacked (wei)", _coverage(owners));

        assertEq(claimed, 99, "the position could only ever crystallise 99 of the 100 poured");
        // The asserted property (header L42-49): the pot is never short of currency.
        assertGe(_coverage(owners), 0, "currencyRaised exceeds the escrow that positions were debited for");
    }

    /// The consequence, in transaction order an honest bidder would follow: after the last pour
    /// the bidder takes the residual escrow home (it is theirs: `positionOf` shows it live), and
    /// from then on `mintPack` — hence every `claim` — reverts on the vault pull.
    function test_singleSeat_claimShrink_bricksClaims() public {
        _stakeFor(aa, 1 << 60);
        _bid(aa, P, ESCROW);
        for (uint256 r = 1; r <= 99; ++r) {
            _roundAndClaim();
        }
        // Round 100: the sync inside `withdrawBid` pours the phantom wei, then the withdrawal.
        vm.roll(block.number + K);
        vm.prank(aa);
        uint256 out = auction.withdrawBid();
        emit log_named_uint("withdrawn residual escrow", out);
        emit log_named_uint("INDEX left in the contract", cur.balanceOf(address(auction)));
        emit log_named_uint("INDEX the next pack must pull", auction.currencyRaised() - auction.currencyMinted());

        (bool okPack,) = _try(abi.encodeCall(GenerousAuction.mintPack, ()));
        (bool okClaim,) = _try(abi.encodeCall(GenerousAuction.claim, (aa)));
        emit log_named_uint("mintPack ok", okPack ? 1 : 0);
        emit log_named_uint("claim ok", okClaim ? 1 : 0);
        assertTrue(okClaim, "claim must not revert after an honest withdrawal");
    }

    /// The other ordering: if the last pour is packed BEFORE the withdrawal (any claim does it),
    /// the pack takes the bidder's residual escrow and the bidder's own `withdrawBid` reverts.
    function test_singleSeat_claimShrink_bricksWithdraw() public {
        _stakeFor(aa, 1 << 60);
        _bid(aa, P, ESCROW);
        for (uint256 r = 1; r <= 100; ++r) {
            _roundAndClaim();
        }
        uint256 live = _live(aa);
        emit log_named_uint("residual live escrow the view promises", live);
        emit log_named_uint("INDEX the contract holds", cur.balanceOf(address(auction)));
        vm.prank(aa);
        (bool ok,) = _try(abi.encodeCall(GenerousAuction.withdrawBid, ()));
        assertTrue(ok, "withdrawBid must not revert on escrow the view reports as live");
    }

    /// How often the model actually pours the phantom wei with ordinary stakes. The shrink
    /// itself is deterministic; whether the death segment lands on it depends on the ceil
    /// residues of `acc`, which is a coin flip for a non-power-of-two stake. Characterisation.
    function test_stakeSweep_phantomPourFrequency() public {
        uint256[8] memory stakesToTry =
            [uint256(1e18), 3e18, 7e18 + 1, 1e18 + 12345, 2e18, 5e17, 9_999_999_999_999, 1 << 40];
        uint256 phantom;
        for (uint256 i; i < stakesToTry.length; ++i) {
            setUp();
            _stakeFor(aa, stakesToTry[i]);
            _bid(aa, P, ESCROW);
            uint256 claimed;
            for (uint256 r = 1; r <= 100; ++r) {
                claimed += _roundAndClaim();
            }
            address[] memory owners = new address[](1);
            owners[0] = aa;
            int256 cov = _coverage(owners);
            emit log_named_uint("stake", stakesToTry[i]);
            emit log_named_uint("  claimed", claimed);
            emit log_named_uint("  tokensBooked", auction.tokensBooked());
            emit log_named_int("  coverage (wei)", cov);
            if (cov < 0) ++phantom;
        }
        emit log_named_uint("stakes out of 8 that end in a currency deficit", phantom);
    }
}

/// Realistic prices and short lifetimes: a top-of-book bidder whose escrow fills in two pours and
/// who claims in between. With two pours the phantom lands whenever the ceil residue of one
/// index step exceeds 1/2 — a coin flip — and the only currency gains against the ~price-wei
/// loss are two pour floors and two harvest ceils. Monte Carlo over random stake / escrow /
/// grid price in [1.01, 1.30]. Characterisation: how often a single honest lifecycle leaves
/// the pot short.
contract Review8AccountingClaimCapShrinkMonteCarloTest is Review8AccountingBase {
    address internal aa = address(0xA1);

    function _lifecycle(uint256 seed) internal returns (bool shrunk, int256 cov) {
        return _lifecycle(seed, 1, 30);
    }

    /// One honest lifecycle: bid, one pour, claim, second pour (the position dies), claim.
    /// Price is `FLOOR + k * SPACING` with k uniform in [kLo, kHi]; stake and escrow random.
    function _lifecycle(uint256 seed, uint256 kLo, uint256 kHi) internal returns (bool shrunk, int256 cov) {
        uint256 h = uint256(keccak256(abi.encode("r8", seed)));
        uint256 price = FLOOR + (kLo + (h % (kHi - kLo + 1))) * SPACING;
        uint256 stake = 1e17 + ((h >> 32) % 5e18);
        uint128 escrow = uint128(1e18 + ((h >> 96) % 10e18));
        uint256 cap = uint256(escrow) * 1e18 / price;
        // Emission per round a bit over half the cap, so the position dies on pour two.
        uint128 emission = uint128(cap / 2 + 1 + ((h >> 160) % 1000));
        _deploy(emission, 0);
        _stakeFor(aa, stake);
        _bid(aa, price, escrow);

        vm.roll(block.number + K);
        auction.claim(aa);
        (, uint128 amt,,,,,) = auction.positions(aa);
        (,, uint256 capTokens,,,,) = auction.ticks(price);
        shrunk = uint256(amt) * 1e18 / price < capTokens;

        vm.roll(block.number + K);
        auction.claim(aa);
        address[] memory owners = new address[](1);
        owners[0] = aa;
        cov = _coverage(owners);
    }

    function test_monteCarlo_twoPourLifecycle_realisticPrices() public {
        uint256 runs = 48;
        uint256 shrinks;
        uint256 deficits;
        int256 worst;
        int256 sumCov;
        for (uint256 seed = 1; seed <= runs; ++seed) {
            (bool shrunk, int256 cov) = _lifecycle(seed);
            if (shrunk) ++shrinks;
            sumCov += cov;
            if (cov < 0) ++deficits;
            if (cov < worst) worst = cov;
        }
        emit log_named_uint("runs", runs);
        emit log_named_uint("lifecycles where the mid-life claim shrank the real cap below the seat", shrinks);
        emit log_named_uint("lifecycles ending with the pot SHORT of currency (coverage < 0)", deficits);
        emit log_named_int("worst deficit, wei", worst);
        emit log_named_int("mean coverage per lifecycle, wei", sumCov / int256(runs));
    }

    /// The same lifecycle at the price levels a later sale runs at: NAV only ratchets up, so a
    /// successor deployed after a few sales bids at 2..50 INDEX/MONO. The loss per shrink is
    /// `price` wei of currency; the offsetting floors/ceils are still under 3 wei in total.
    function test_monteCarlo_twoPourLifecycle_higherPriceLevels() public {
        uint256 runs = 48;
        uint256 shrinks;
        uint256 deficits;
        int256 worst;
        int256 sumCov;
        uint256 firstBad;
        for (uint256 seed = 1; seed <= runs; ++seed) {
            (bool shrunk, int256 cov) = _lifecycle(seed, 100, 4900); // 2.00 .. 50.00
            if (shrunk) ++shrinks;
            sumCov += cov;
            if (cov < 0) {
                ++deficits;
                if (firstBad == 0) firstBad = seed;
                uint256 h = uint256(keccak256(abi.encode("r8", seed)));
                emit log_named_uint("  deficit seed", seed);
                emit log_named_uint("    price", FLOOR + (100 + (h % 4801)) * SPACING);
                emit log_named_uint("    stake", 1e17 + ((h >> 32) % 5e18));
                emit log_named_uint("    escrow", 1e18 + ((h >> 96) % 10e18));
                emit log_named_int("    coverage", cov);
            }
            if (cov < worst) worst = cov;
        }
        emit log_named_uint("runs", runs);
        emit log_named_uint("lifecycles where the mid-life claim shrank the real cap below the seat", shrinks);
        emit log_named_uint("lifecycles ending with the pot SHORT of currency (coverage < 0)", deficits);
        emit log_named_int("worst deficit, wei", worst);
        emit log_named_int("mean coverage per lifecycle, wei", sumCov / int256(runs));
        assertEq(deficits, 0, "an honest two-pour lifecycle must never leave the pot short");
    }
}

/// The Monte Carlo's first hit, pinned: an ordinary stake, an ordinary escrow, a price a later
/// sale would run at, two pours and one claim in between. After the position dies the pot is 9
/// wei short; the bidder's residual escrow (`positionOf` says live) cannot be withdrawn, and
/// because `withdrawBid` is all-or-nothing and `submitBid` at any other price is `BidExists`
/// while escrow is live, the bidder is locked at a dead tick until a stranger donates 9 wei.
contract Review8AccountingClaimCapShrinkPinnedTest is Review8AccountingBase {
    address internal aa = address(0xA1);
    uint256 internal constant PRICE = 10_230_000_000_000_000_000; // 10.23
    uint256 internal constant STAKE = 2_996_293_409_371_317_805;
    uint128 internal constant ESCROW = 10_668_271_852_980_794_193;

    function setUp() public {
        // Monte Carlo seed 30, reproduced exactly (the emission's last term comes off the seed).
        uint256 h = uint256(keccak256(abi.encode("r8", uint256(30))));
        assertEq(FLOOR + (100 + (h % 4801)) * SPACING, PRICE);
        assertEq(1e17 + ((h >> 32) % 5e18), STAKE);
        assertEq(1e18 + ((h >> 96) % 10e18), ESCROW);
        uint256 cap = uint256(ESCROW) * 1e18 / PRICE;
        uint128 emission = uint128(cap / 2 + 1 + ((h >> 160) % 1000));
        emit log_named_uint("emission per round", emission);
        _deploy(emission, 0);
        _stakeFor(aa, STAKE);
        _bid(aa, PRICE, ESCROW);
    }

    function test_pinned_price10_ordinaryStake_deficitAndLockout() public {
        vm.roll(block.number + K);
        uint256 got1 = auction.claim(aa);
        (, uint128 amt,,,,,) = auction.positions(aa);
        (,, uint256 capTokens,,,,) = auction.ticks(PRICE);
        emit log_named_uint("first claim, token-wei", got1);
        emit log_named_uint("real remaining cap after the claim", uint256(amt) * 1e18 / PRICE);
        emit log_named_uint("seat/tick remaining cap after the claim", capTokens);
        // The claim re-seated: the seat never exceeds the real capacity (a phantom wei would be
        // booked and charged for); the unseat floor may leave it a wei UNDER, which is harmless.
        uint256 realCap = uint256(amt) * 1e18 / PRICE;
        assertLe(capTokens, realCap, "no phantom capacity: the claim re-seated");
        assertGe(capTokens + 1, realCap, "seat within a wei of the real capacity");

        vm.roll(block.number + K);
        uint256 got2 = auction.claim(aa);
        emit log_named_uint("second claim, token-wei", got2);
        emit log_named_uint("tokensBooked", auction.tokensBooked());
        emit log_named_uint("claimed in total", got1 + got2);
        emit log_named_uint("tokensUnclaimed left (phantom)", auction.tokensUnclaimed());

        address[] memory owners = new address[](1);
        owners[0] = aa;
        int256 cov = _coverage(owners);
        uint256 live = _live(aa);
        emit log_named_int("coverage, wei", cov);
        emit log_named_uint("residual live escrow", live);
        emit log_named_uint("INDEX the contract holds", cur.balanceOf(address(auction)));

        vm.prank(aa);
        (bool okW,) = _try(abi.encodeCall(GenerousAuction.withdrawBid, ()));
        emit log_named_uint("withdrawBid ok", okW ? 1 : 0);

        // Locked at the dead tick: a bid at any other price is refused while escrow is live.
        cur.mint(aa, 1e18);
        vm.startPrank(aa);
        cur.approve(address(auction), 1e18);
        (bool okB, bytes memory ret) =
            _try(abi.encodeCall(GenerousAuction.submitBid, (PRICE + SPACING, 1e18, aa, FLOOR)));
        vm.stopPrank();
        emit log_named_uint("submitBid at another price ok", okB ? 1 : 0);
        emit log_named_bytes("  revert", ret);

        // With the re-seat in `_claim` there is no deficit, so no donation is needed and both
        // the withdrawal and a move to another price go through on their own.
        assertGe(cov, 0, "pot short of currency after one honest claim");
        assertTrue(okW, "an honest bidder must be able to withdraw live escrow");
        assertTrue(okB || _live(aa) == 0, "a bidder with no live escrow may move to another price");
    }
}
