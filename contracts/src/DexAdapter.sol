// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexAdapter} from "./interfaces/IDexAdapter.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";

/// @title DexAdapter (Uniswap v3 implementation of IDexAdapter)
/// @notice DexAdapter that routes single-hop swaps through Uniswap v3 SwapRouter02 on Robinhood Chain.
///         Only canonical factory pools of an allowed fee tier can be used, so a manager cannot point the
///         vault at an arbitrary contract. Price protection (oracle-derived minimum out) is enforced
///         upstream by TradeExecutor and re-checked by the vault via balance deltas.
contract DexAdapter is IDexAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ISwapRouter02 public immutable router;
    IUniswapV3Factory public immutable uniFactory;
    mapping(uint24 fee => bool) public allowedFee;

    event FeeTierSet(uint24 indexed fee, bool allowed);
    event Swapped(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint24 fee
    );

    error Expired();
    error FeeTierNotAllowed(uint24 fee);
    error PoolMissing();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error ZeroAddress();

    constructor(address router_, address uniFactory_, address admin) {
        if (router_ == address(0) || uniFactory_ == address(0)) revert ZeroAddress();
        router = ISwapRouter02(router_);
        uniFactory = IUniswapV3Factory(uniFactory_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        allowedFee[500] = true;
        allowedFee[3000] = true;
        allowedFee[10_000] = true;
        emit FeeTierSet(500, true);
        emit FeeTierSet(3000, true);
        emit FeeTierSet(10_000, true);
    }

    function setFeeTier(uint24 fee, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowedFee[fee] = allowed;
        emit FeeTierSet(fee, allowed);
    }

    /// @param data abi.encode(uint24 feeTier)
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline,
        bytes calldata data
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        uint24 fee = abi.decode(data, (uint24));
        if (!allowedFee[fee]) revert FeeTierNotAllowed(fee);
        if (uniFactory.getPool(tokenIn, tokenOut, fee) == address(0)) revert PoolMissing();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);
        amountOut = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).forceApprove(address(router), 0);
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, fee);
    }
}
