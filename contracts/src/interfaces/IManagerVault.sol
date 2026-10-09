// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IManagerVault is IERC4626 {
    function manager() external view returns (address);
    function factory() external view returns (address);
    function heldTokens() external view returns (address[] memory);
    function navFresh() external view returns (uint256 nav, bool fresh);
    function sharePrice() external view returns (uint256 price, bool fresh);
    function executeSwap(
        address adapter,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata data
    ) external returns (uint256 amountOut);
    function redeemInKind(uint256 shares, address receiver, address owner)
        external
        returns (address[] memory tokens, uint256[] memory amounts);
}
