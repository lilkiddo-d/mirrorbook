// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IManagerVault} from "./interfaces/IManagerVault.sol";

/// @title PerformanceTracker
/// @notice Verifiable track record: at most one oracle-priced share-price snapshot per vault per UTC day,
///         stored in a fixed-size ring buffer. Anyone (keepers, the TradeExecutor) can record; nobody can
///         edit or delete. Return, max drawdown, volatility and a Sharpe-like ratio are computed on-chain.
contract PerformanceTracker {
    using SafeCast for uint256;

    uint256 public constant RING = 400; // > 365 so a full year always fits
    uint256 public constant MAX_BATCH = 50;
    uint256 internal constant WAD = 1e18;
    /// @dev sqrt(365) * 1e9
    uint256 internal constant SQRT_365_E9 = 19_104_973_174;
    int256 internal constant SHARPE_CAP = 100e18;

    struct Snapshot {
        uint32 day;
        uint224 price; // normalized share price, 1e18 = launch
    }

    struct Track {
        uint16 head; // next write index
        uint16 count;
        uint32 lastDay;
    }

    struct Stats {
        uint256 points;
        uint32 fromDay;
        uint32 toDay;
        int256 totalReturn; // 1e18 = +100%
        uint256 maxDrawdown; // 1e18 = 100%
        uint256 volatility; // per-period stdev, 1e18
        int256 sharpe; // mean/stdev * sqrt(365), 1e18
    }

    IVaultFactory public immutable factory;
    mapping(address vault => Track) public tracks;
    mapping(address vault => Snapshot[RING]) internal _snaps;

    event SnapshotRecorded(address indexed vault, uint32 indexed day, uint256 price);

    error UnknownVault();
    error BatchTooLarge();

    constructor(address factory_) {
        factory = IVaultFactory(factory_);
    }

    /// @return recorded false if today's snapshot exists or the price is not trustworthy right now
    function record(address vault) public returns (bool recorded) {
        if (!factory.isVault(vault)) revert UnknownVault();
        uint32 today = uint32(block.timestamp / 1 days);
        Track memory t = tracks[vault];
        // Day-index comparison (one snapshot per UTC day), not a balance check.
        // slither-disable-next-line incorrect-equality
        if (t.count != 0 && t.lastDay == today) return false;
        (uint256 price, bool fresh) = IManagerVault(vault).sharePrice();
        if (!fresh || price == 0) return false;

        _snaps[vault][t.head] = Snapshot(today, price.toUint224());
        t.head = t.head + 1 >= RING ? 0 : t.head + 1;
        if (t.count < RING) t.count++;
        t.lastDay = today;
        tracks[vault] = t;
        emit SnapshotRecorded(vault, today, price);
        return true;
    }

    function recordMany(address[] calldata vaults) external returns (uint256 n) {
        if (vaults.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < vaults.length; ++i) {
            if (record(vaults[i])) n++;
        }
    }

    /// @notice Latest `n` snapshots in chronological order.
    function history(address vault, uint256 n) public view returns (Snapshot[] memory out) {
        Track memory t = tracks[vault];
        if (n > t.count) n = t.count;
        out = new Snapshot[](n);
        uint256 idx = uint256(t.head) + RING - n; // oldest requested entry (may exceed RING once)
        if (idx >= RING) idx -= RING;
        for (uint256 i; i < n; ++i) {
            out[i] = _snaps[vault][idx];
            idx = idx + 1 >= RING ? 0 : idx + 1;
        }
    }

    /// @notice Risk/return statistics over the trailing `windowDays` days.
    function stats(address vault, uint256 windowDays) external view returns (Stats memory s) {
        Snapshot[] memory all = history(vault, tracks[vault].count);
        uint256 today = block.timestamp / 1 days;
        uint256 minDay = today > windowDays ? today - windowDays : 0;

        uint256 start = all.length;
        for (uint256 i; i < all.length; ++i) {
            if (all[i].day >= minDay) {
                start = i;
                break;
            }
        }
        uint256 n = all.length - start;
        s.points = n;
        // slither-disable-next-line incorrect-equality
        if (n == 0) return s;
        s.fromDay = all[start].day;
        s.toDay = all[all.length - 1].day;
        if (n < 2) return s;

        s.totalReturn = int256(uint256(all[all.length - 1].price) * WAD / all[start].price) - int256(WAD);
        (s.maxDrawdown, s.volatility, s.sharpe) = _risk(all, start);
    }

    function _risk(Snapshot[] memory all, uint256 start)
        internal
        pure
        returns (uint256 maxDrawdown, uint256 volatility, int256 sharpe)
    {
        uint256 m = all.length - start - 1; // number of returns
        uint256 peak = all[start].price;
        int256 sum = 0;
        int256[] memory rets = new int256[](m);
        for (uint256 i; i < m; ++i) {
            uint256 p = all[start + i + 1].price;
            if (p > peak) peak = p;
            uint256 dd = (peak - p) * WAD / peak;
            if (dd > maxDrawdown) maxDrawdown = dd;
            rets[i] = int256(p * WAD / all[start + i].price) - int256(WAD);
            sum += rets[i];
        }
        volatility = _stdev(rets, sum / int256(m));
        // slither-disable-next-line incorrect-equality
        if (volatility == 0) {
            sharpe = sum > 0 ? SHARPE_CAP : int256(0);
        } else {
            // mean / stdev * sqrt(365), with mean = sum / m folded into the denominator
            sharpe = sum * int256(WAD) * int256(SQRT_365_E9) / (int256(volatility) * int256(m) * 1e9);
            if (sharpe > SHARPE_CAP) sharpe = SHARPE_CAP;
            else if (sharpe < -SHARPE_CAP) sharpe = -SHARPE_CAP;
        }
    }

    function _stdev(int256[] memory rets, int256 mean) internal pure returns (uint256) {
        uint256 varSum = 0;
        for (uint256 i; i < rets.length; ++i) {
            int256 d = rets[i] - mean;
            varSum += uint256(d * d) / WAD;
        }
        return Math.sqrt(varSum * WAD / rets.length);
    }
}
