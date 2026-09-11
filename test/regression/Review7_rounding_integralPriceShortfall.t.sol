// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 7, rounding lens: the supply-exhaust step of `_pourTick` (L864,
/// `acc += ceilDiv(left, S)`) books ALL of `left` into `tokensUnclaimed` and charges
/// `floor(left * price / WAD)` into `currencyRaised` (L884-886), while the n survivors each
/// crystallise `floor(s_i * dA / 2^128)` (L1208) — a sum of per-position floors that runs up to
/// `n - 1` token-wei BEHIND the booking. The header (L42-45) says the per-position CEIL charge
/// (L1210) keeps `currencyRaised` covered. It does not: at any whole-number price
/// (`price % 1e18 == 0` — the floor tick 1.00 is one) `ceil(eaten * price / WAD) == eaten *
/// price / WAD` exactly, so the ceil gains nothing and `currencyRaised` exceeds the escrow
/// actually deducted. That gap is invisible while other bidders' live escrow sits in the
/// contract; the moment the escrow leaves, `_mintPack` cannot pull `assets` and every `claim`
/// reverts.
contract Review7IntegralPriceShortfallTest is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;

    address internal aa = address(0xA1);
    address internal bb = address(0xA2);
    address internal cc = address(0xA3);

    function _deploy(uint128 emission) internal {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));
        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: address(0xF1),
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: HALF,
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: emission,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    function _stakeFor(address who, uint256 amt) internal {
        mono.transfer(who, amt);
        vm.startPrank(who);
        mono.approve(address(auction), amt);
        auction.stake(amt);
        vm.stopPrank();
    }

    function _bid(address who, uint256 price, uint128 amount) internal {
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        auction.submitBid(price, amount, who, FLOOR);
        vm.stopPrank();
    }

    function _sumLive() internal view returns (uint256 s) {
        (uint256 l1,) = auction.positionOf(aa);
        (uint256 l2,) = auction.positionOf(bb);
        (uint256 l3,) = auction.positionOf(cc);
        return l1 + l2 + l3;
    }

    /// `balance - sum(live)` is the escrow the contract holds beyond what positions still own,
    /// i.e. `sum(charged) - currencyMinted`. Subtracting the unpacked delta gives
    /// `sum(charged) - currencyRaised`: positive = surplus (stuck), negative = shortfall.
    function _coverage() internal view returns (int256) {
        uint256 bal = cur.balanceOf(address(auction));
        uint256 unpacked = auction.currencyRaised() - auction.currencyMinted();
        return int256(bal) - int256(_sumLive()) - int256(unpacked);
    }

    /// ONE round at the floor tick 1.00 with three honest bidders of irregular stake. After all
    /// three withdraw, the escrow the contract holds is short of what `currencyRaised` booked,
    /// and the next claim — which packs first — reverts on the vault pull.
    function test_oneRound_atFloor_bricksEveryClaim() public {
        _deploy(95e18);
        _stakeFor(aa, 1e18 + 1);
        _stakeFor(bb, 2e18 + 3);
        _stakeFor(cc, 4e18 + 7);
        _bid(aa, FLOOR, 1000e18);
        _bid(bb, FLOOR, 1000e18);
        _bid(cc, FLOOR, 1000e18);

        vm.roll(block.number + K);
        auction.sync(64);
        assertEq(auction.tokensSold(), 95e18, "the whole round was sold");
        // Three seats: the pot books two token-wei less than it poured, and charges for that.
        assertEq(auction.tokensBooked(), 95e18 - 2, "booked a lower bound of what the seats crystallise");
        assertEq(auction.currencyRaised(), 95e18 - 2, "and charged at 1.00 for the booking only");

        uint256 sumOwed;
        {
            (, uint256 o1) = auction.positionOf(aa);
            (, uint256 o2) = auction.positionOf(bb);
            (, uint256 o3) = auction.positionOf(cc);
            sumOwed = o1 + o2 + o3;
        }
        emit log_named_uint("booked (tokensUnclaimed)", auction.tokensUnclaimed());
        emit log_named_uint("sum crystallised by positions", sumOwed);
        emit log_named_int("coverage: sum(charged) - currencyRaised, wei", _coverage());

        // Everybody takes their unspent escrow home. Each withdrawal is honest and succeeds.
        vm.prank(aa);
        auction.withdrawBid();
        vm.prank(bb);
        auction.withdrawBid();
        vm.prank(cc);
        auction.withdrawBid();

        uint256 held = cur.balanceOf(address(auction));
        uint256 owedToVault = auction.currencyRaised() - auction.currencyMinted();
        emit log_named_uint("currency held after withdrawals", held);
        emit log_named_uint("currency the next pack must pull", owedToVault);

        // The header's claim: "charging up keeps `currencyRaised` covered by escrow actually
        // spent. The shortfall is dust, never insolvency."
        assertGe(held, owedToVault, "escrow deducted from positions covers what currencyRaised booked");

        // And the consequence: 95 MONO of winnings are unclaimable — by anyone.
        (bool ok,) = address(auction).call(abi.encodeCall(GenerousAuction.claim, (aa)));
        assertTrue(ok, "claim after withdrawals must not revert");
    }

    /// Same book, the consequence alone: after the three withdrawals the pack cannot pull its
    /// delta, so `claim` — for ANY owner — reverts, and 95 MONO of winnings stay stuck until
    /// someone donates the missing wei.
    function test_oneRound_atFloor_claimReverts() public {
        _deploy(95e18);
        _stakeFor(aa, 1e18 + 1);
        _stakeFor(bb, 2e18 + 3);
        _stakeFor(cc, 4e18 + 7);
        _bid(aa, FLOOR, 1000e18);
        _bid(bb, FLOOR, 1000e18);
        _bid(cc, FLOOR, 1000e18);
        vm.roll(block.number + K);
        auction.sync(64);
        vm.prank(aa);
        auction.withdrawBid();
        vm.prank(bb);
        auction.withdrawBid();
        vm.prank(cc);
        auction.withdrawBid();

        (bool okA,) = address(auction).call(abi.encodeCall(GenerousAuction.claim, (aa)));
        (bool okB,) = address(auction).call(abi.encodeCall(GenerousAuction.claim, (bb)));
        (bool okPack,) = address(auction).call(abi.encodeCall(GenerousAuction.mintPack, ()));
        emit log_named_uint("claim(aa) ok", okA ? 1 : 0);
        emit log_named_uint("claim(bb) ok", okB ? 1 : 0);
        emit log_named_uint("mintPack ok", okPack ? 1 : 0);

        // Donating the 2 missing wei from anywhere un-bricks it — the only remedy.
        cur.mint(address(this), 2);
        cur.transfer(address(auction), 2);
        (bool okAfter,) = address(auction).call(abi.encodeCall(GenerousAuction.claim, (aa)));
        emit log_named_uint("claim(aa) ok after a 2-wei donation", okAfter ? 1 : 0);

        assertTrue(okA, "claim after withdrawals must not revert");
    }
}
