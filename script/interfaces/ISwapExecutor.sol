// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ISwapExecutor {

    function swap(
        address router,
        bytes calldata data,
        address token_in,
        address token_out
    ) external;

}
