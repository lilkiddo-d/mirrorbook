// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IProjectTokenHooks {
    function projectToken() external view returns (address);
    function isVerified(address manager) external view returns (bool);
    function totalStaked() external view returns (uint256);
    function notifyRewardAmount(uint256 amount) external;
}
