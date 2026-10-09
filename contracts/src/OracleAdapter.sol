// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";

/// @title OracleAdapter (Chainlink)
/// @notice Validated Chainlink prices for stock tokens and the stablecoin. Swappable behind IOracleAdapter.
///         Checks: positive answer, staleness vs per-feed limit, optional price band (stablecoin peg),
///         round-over-round deviation circuit breaker, Robinhood `oraclePaused()` flag, and an optional
///         L2 sequencer uptime feed (none is published for Robinhood Chain yet -> disabled by default).
contract OracleAdapter is AccessControl, IOracleAdapter {
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_STALENESS_CAP = 4 days;

    struct Feed {
        address aggregator;
        uint32 maxStaleness;
        uint16 maxRoundDeviationBps; // 0 = disabled
        uint8 feedDecimals;
        uint8 tokenDecimals;
        bool checkTokenPause;
        uint128 minPrice; // 18 decimals, 0 = no floor
        uint128 maxPrice; // 18 decimals, 0 = no cap
    }

    mapping(address token => Feed) public feeds;
    address public sequencerUptimeFeed;
    uint32 public sequencerGracePeriod = 1 hours;

    event FeedSet(address indexed token, address indexed aggregator, uint32 maxStaleness, uint16 maxRoundDeviationBps);
    event FeedRemoved(address indexed token);
    event PriceBandSet(address indexed token, uint128 minPrice, uint128 maxPrice);
    event SequencerFeedSet(address indexed feed, uint32 gracePeriod);

    error InvalidFeed();
    error InvalidParam();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------ admin (Timelock)

    function setFeed(
        address token,
        address aggregator,
        uint32 maxStaleness,
        uint16 maxRoundDeviationBps,
        bool checkTokenPause
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || aggregator == address(0)) revert InvalidFeed();
        if (maxStaleness == 0 || maxStaleness > MAX_STALENESS_CAP || maxRoundDeviationBps > BPS) revert InvalidParam();
        Feed storage f = feeds[token];
        f.aggregator = aggregator;
        f.maxStaleness = maxStaleness;
        f.maxRoundDeviationBps = maxRoundDeviationBps;
        f.feedDecimals = IAggregatorV3(aggregator).decimals();
        f.tokenDecimals = IERC20Metadata(token).decimals();
        f.checkTokenPause = checkTokenPause;
        if (f.feedDecimals > 18 || f.tokenDecimals > 30) revert InvalidFeed();
        emit FeedSet(token, aggregator, maxStaleness, maxRoundDeviationBps);
    }

    function setPriceBand(address token, uint128 minPrice, uint128 maxPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeds[token].aggregator == address(0)) revert InvalidFeed();
        if (maxPrice != 0 && minPrice > maxPrice) revert InvalidParam();
        feeds[token].minPrice = minPrice;
        feeds[token].maxPrice = maxPrice;
        emit PriceBandSet(token, minPrice, maxPrice);
    }

    function removeFeed(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete feeds[token];
        emit FeedRemoved(token);
    }

    function setSequencerUptimeFeed(address feed, uint32 gracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (gracePeriod > 1 days) revert InvalidParam();
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    // ------------------------------------------------------------------ views

    function isSupported(address token) external view returns (bool) {
        return feeds[token].aggregator != address(0);
    }

    function sequencerUp() public view returns (bool) {
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return true;
        // slither-disable-next-line unused-return
        try IAggregatorV3(feed).latestRoundData() returns (uint80, int256 status, uint256 startedAt, uint256, uint80) {
            // 0 = up. startedAt == 0 means the round is invalid.
            return status == 0 && startedAt != 0 && block.timestamp - startedAt > sequencerGracePeriod;
        } catch {
            return false;
        }
    }

    function getPrice(address token) public view returns (uint256 price, bool ok) {
        Feed memory f = feeds[token];
        if (f.aggregator == address(0)) return (0, false);

        uint80 roundId = 0;
        int256 answer = 0;
        uint256 updatedAt = 0;
        bool complete = false;
        try IAggregatorV3(f.aggregator).latestRoundData() returns (
            uint80 r, int256 a, uint256 startedAt, uint256 u, uint80 answeredInRound
        ) {
            (roundId, answer, updatedAt) = (r, a, u);
            // Round-completeness fields (legacy, but cheap to honour).
            complete = startedAt != 0 && answeredInRound >= r;
        } catch {
            return (0, false);
        }
        if (answer <= 0) return (0, false);

        price = uint256(answer) * 10 ** (18 - f.feedDecimals);
        ok = complete && updatedAt != 0 && updatedAt <= block.timestamp
            && block.timestamp - updatedAt <= f.maxStaleness;

        if (ok && f.minPrice != 0 && price < f.minPrice) ok = false;
        if (ok && f.maxPrice != 0 && price > f.maxPrice) ok = false;
        if (ok && f.checkTokenPause) ok = !_tokenOraclePaused(token);
        if (ok && f.maxRoundDeviationBps != 0) ok = _withinRoundDeviation(f, roundId, answer);
        if (ok) ok = sequencerUp();
    }

    function convert(address token, uint256 amount, address quoteToken) external view returns (uint256 out, bool ok) {
        (uint256 pIn, bool okIn) = getPrice(token);
        (uint256 pOut, bool okOut) = getPrice(quoteToken);
        // slither-disable-next-line incorrect-equality
        if (pIn == 0 || pOut == 0) return (0, false);
        ok = okIn && okOut;
        Feed storage fi = feeds[token];
        Feed storage fo = feeds[quoteToken];
        // out = amount * pIn / pOut, rescaled from tokenDecimals(in) to tokenDecimals(out)
        out = Math.mulDiv(amount, pIn * 10 ** fo.tokenDecimals, pOut * 10 ** fi.tokenDecimals);
    }

    // ------------------------------------------------------------------ internal

    function _tokenOraclePaused(address token) internal view returns (bool) {
        try IStockToken(token).oraclePaused() returns (bool p) {
            return p;
        } catch {
            return false;
        }
    }

    function _withinRoundDeviation(Feed memory f, uint80 roundId, int256 answer) internal view returns (bool) {
        if (uint64(roundId) <= 1) return true; // first round of a phase: nothing to compare
        // slither-disable-next-line unused-return
        try IAggregatorV3(f.aggregator).getRoundData(roundId - 1) returns (
            uint80, int256 prev, uint256, uint256, uint80
        ) {
            if (prev <= 0) return true;
            uint256 p = uint256(prev);
            uint256 a = uint256(answer);
            uint256 diff = a > p ? a - p : p - a;
            return diff * BPS <= p * f.maxRoundDeviationBps;
        } catch {
            return true;
        }
    }
}
