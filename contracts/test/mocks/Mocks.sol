// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDexAdapter} from "../../src/interfaces/IDexAdapter.sol";
import {IOracleAdapter} from "../../src/interfaces/IOracleAdapter.sol";

/// @dev Test-only ERC-20 (also stands in for the future project token). Never deployed by scripts.
contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockStockToken is MockERC20 {
    bool public oraclePaused;

    constructor(string memory n, string memory s) MockERC20(n, s, 18) {}

    function setOraclePaused(bool p) external {
        oraclePaused = p;
    }
}

contract MockAggregator {
    uint8 public decimals;
    string public description;
    uint80 public roundId = 100;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    mapping(uint80 => int256) public history;
    bool public reverts;
    bool public roundReverts;

    constructor(uint8 d, int256 a, string memory desc) {
        decimals = d;
        answer = a;
        description = desc;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
        history[roundId] = a;
    }

    function set(int256 a) external {
        roundId++;
        answer = a;
        updatedAt = block.timestamp;
        history[roundId] = a;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setStartedAt(uint256 t) external {
        startedAt = t;
    }

    function setRoundId(uint80 r) external {
        roundId = r;
        history[r] = answer;
    }

    function setReverts(bool r) external {
        reverts = r;
    }

    function setRoundReverts(bool r) external {
        roundReverts = r;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverts, "agg down");
        return (roundId, answer, startedAt, updatedAt, roundId);
    }

    function getRoundData(uint80 r) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!roundReverts, "no round");
        return (r, history[r], startedAt, updatedAt, r);
    }
}

/// @dev Executes swaps at the oracle price minus `lossBps`, paying out of its own inventory.
contract MockDexAdapter is IDexAdapter {
    IOracleAdapter public oracle;
    uint256 public lossBps;
    uint256 public pullExtra; // tries to pull more than amountIn (should be impossible)

    constructor(address oracle_) {
        oracle = IOracleAdapter(oracle_);
    }

    function setLossBps(uint256 l) external {
        lossBps = l;
    }

    function setPullExtra(uint256 x) external {
        pullExtra = x;
    }

    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256,
        bytes calldata
    ) external returns (uint256 out) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn + pullExtra);
        (uint256 fair,) = oracle.convert(tokenIn, amountIn, tokenOut);
        out = fair * (10_000 - lossBps) / 10_000;
        IERC20(tokenOut).transfer(recipient, out);
        minAmountOut; // the vault enforces the bound itself
    }
}

/// @dev Minimal Uniswap SwapRouter02 / Factory stand-ins for DexAdapter unit tests.
contract MockUniFactory {
    mapping(bytes32 => address) public pools;

    function setPool(address a, address b, uint24 fee, address pool) external {
        pools[keccak256(abi.encode(a, b, fee))] = pool;
        pools[keccak256(abi.encode(b, a, fee))] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[keccak256(abi.encode(a, b, fee))];
    }
}

contract MockSwapRouter {
    uint256 public rateWad = 1e18; // out = in * rate
    uint256 public underpay; // pay less than minimum (adapter must catch)

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function setRate(uint256 r) external {
        rateWad = r;
    }

    function setUnderpay(uint256 u) external {
        underpay = u;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = p.amountIn * rateWad / 1e18;
        if (underpay == 0) require(out >= p.amountOutMinimum, "Too little received");
        out -= underpay;
        IERC20(p.tokenOut).transfer(p.recipient, out);
    }
}

/// @dev Compliance hook that can be toggled per account.
contract MockCompliance {
    mapping(address => bool) public blocked;

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function isAllowed(address account, bytes32) external view returns (bool) {
        return !blocked[account];
    }
}
